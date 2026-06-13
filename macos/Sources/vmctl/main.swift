@preconcurrency import AppKit
import Darwin
import Foundation
@preconcurrency import Virtualization

enum VMToolError: LocalizedError {
    case usage(String)
    case unsupported(String)
    case notFound(String)
    case invalidState(String)
    case virtualization(String)

    var errorDescription: String? {
        switch self {
        case .usage(let message),
             .unsupported(let message),
             .notFound(let message),
             .invalidState(let message),
             .virtualization(let message):
            return message
        }
    }
}

enum GuestKind: String, Codable {
    case macos
    case windows
}

enum NetworkMode: String {
    case isolated
    case nat
    case bridged
}

struct VMConfig: Codable {
    var bundleVersion: Int = 1
    var name: String
    var guest: GuestKind
    var cpuCount: Int
    var memorySizeBytes: UInt64
    var diskSizeBytes: UInt64
    var createdAt: String
    var installed: Bool
    var restoreImagePath: String?
    var restoreBuildVersion: String?
    var restoreOSVersion: String?
    var installerMediaPath: String?
    var notes: [String]
}

struct VMPaths {
    let bundleURL: URL

    var configURL: URL { bundleURL.appendingPathComponent("config.json") }
    var diskURL: URL { bundleURL.appendingPathComponent("Disk.raw") }
    var auxiliaryStorageURL: URL { bundleURL.appendingPathComponent("AuxiliaryStorage") }
    var hardwareModelURL: URL { bundleURL.appendingPathComponent("MacHardwareModel.bin") }
    var machineIdentifierURL: URL { bundleURL.appendingPathComponent("MacMachineIdentifier.bin") }
    var efiVariableStoreURL: URL { bundleURL.appendingPathComponent("EFIVariables") }
    var sharedURL: URL { bundleURL.appendingPathComponent("Shared", isDirectory: true) }
    var snapshotsURL: URL { bundleURL.appendingPathComponent("Snapshots", isDirectory: true) }
    var runPIDURL: URL { bundleURL.appendingPathComponent("run.pid") }
}

struct VMStore {
    let rootURL: URL

    static func `default`() throws -> VMStore {
        if let override = ProcessInfo.processInfo.environment["AGENT_SANDBOX_VM_ROOT"], !override.isEmpty {
            return VMStore(rootURL: URL(fileURLWithPath: override).standardizedFileURL)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        return VMStore(rootURL: home.appendingPathComponent(".agent-sandbox/macos-vms", isDirectory: true))
    }

    func paths(for name: String) -> VMPaths {
        VMPaths(bundleURL: rootURL.appendingPathComponent("\(name).agentvm", isDirectory: true))
    }

    func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
}

struct Options {
    private var values: [String: [String]] = [:]
    private var flags: Set<String> = []

    init(_ args: [String]) throws {
        var index = 0
        while index < args.count {
            let arg = args[index]
            guard arg.hasPrefix("--") else {
                throw VMToolError.usage("Unexpected argument: \(arg)")
            }

            let key = String(arg.dropFirst(2))
            if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                values[key, default: []].append(args[index + 1])
                index += 2
            } else {
                flags.insert(key)
                index += 1
            }
        }
    }

    func string(_ key: String) -> String? {
        values[key]?.last
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else {
            throw VMToolError.usage("Missing required option --\(key)")
        }
        return value
    }

    func int(_ key: String, default defaultValue: Int) throws -> Int {
        guard let value = string(key) else { return defaultValue }
        guard let parsed = Int(value), parsed > 0 else {
            throw VMToolError.usage("--\(key) must be a positive integer")
        }
        return parsed
    }

    func bool(_ key: String) -> Bool {
        flags.contains(key)
    }
}

@main
struct VMCTL {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("vmctl: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run(_ args: [String]) throws {
        guard let command = args.first else {
            printUsage()
            return
        }

        let rest = Array(args.dropFirst())
        switch command {
        case "create":
            try create(Options(rest))
        case "install":
            try install(Options(rest))
        case "run":
            try runVM(Options(rest))
        case "stop":
            try stop(Options(rest))
        case "snapshot":
            try snapshot(rest)
        case "copy-out":
            try copyOut(Options(rest))
        case "list":
            try list(Options(rest))
        case "delete":
            try delete(Options(rest))
        case "path":
            try path(Options(rest))
        case "info":
            try info(Options(rest))
        case "help", "--help", "-h":
            printUsage()
        default:
            throw VMToolError.usage("Unknown command: \(command)")
        }
    }

    static func printUsage() {
        print("""
        vmctl - macOS Virtualization.framework helper for Agent Sandbox VM

        Commands:
          create --guest macos --ipsw <file>|--latest --name <name> [--cpus 4] [--memory 8] [--disk-size 80]
          create --guest windows --iso <arm64-media> --name <name> [--cpus 4] [--memory 4] [--disk-size 80]
          install --name <name>
          run --name <name> [--internet isolated|nat|bridged] [--bridge-interface en0] [--share <path>]
          stop --name <name>
          snapshot save --name <name> --label CleanProvisionedBase
          snapshot restore --name <name> --label CleanProvisionedBase
          copy-out --name <name> --from <shared-relative-path> --to <host-path>
          list
          delete --name <name>
          path --name <name> [--shared]
          info --name <name>

        Set AGENT_SANDBOX_VM_ROOT to override ~/.agent-sandbox/macos-vms.
        """)
    }
}

// MARK: - Commands

extension VMCTL {
    static func create(_ options: Options) throws {
        guard let guest = GuestKind(rawValue: try options.required("guest")) else {
            throw VMToolError.usage("--guest must be macos or windows")
        }
        let name = try validateName(options.required("name"))
        let cpuCount = try options.int("cpus", default: 4)
        let memoryGB = try options.int("memory", default: guest == .macos ? 8 : 4)
        let diskGB = try options.int("disk-size", default: 80)

        let store = try VMStore.default()
        try store.ensureRoot()
        let paths = store.paths(for: name)
        if FileManager.default.fileExists(atPath: paths.bundleURL.path) {
            throw VMToolError.invalidState("VM bundle already exists: \(paths.bundleURL.path)")
        }

        try FileManager.default.createDirectory(at: paths.bundleURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.sharedURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.snapshotsURL, withIntermediateDirectories: true)
        try createRawDisk(at: paths.diskURL, sizeBytes: UInt64(diskGB) * 1_073_741_824)

        var config = VMConfig(
            name: name,
            guest: guest,
            cpuCount: cpuCount,
            memorySizeBytes: UInt64(memoryGB) * 1_073_741_824,
            diskSizeBytes: UInt64(diskGB) * 1_073_741_824,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            installed: false,
            notes: []
        )

        switch guest {
        case .macos:
            try createMacMetadata(options: options, paths: paths, config: &config)
        case .windows:
            try createWindowsMetadata(options: options, paths: paths, config: &config)
        }

        try saveConfig(config, to: paths.configURL)
        print("Created \(guest.rawValue) VM bundle: \(paths.bundleURL.path)")
        print("Shared directory: \(paths.sharedURL.path)")
    }

    static func install(_ options: Options) throws {
        let name = try validateName(options.required("name"))
        let store = try VMStore.default()
        let paths = store.paths(for: name)
        var config = try loadConfig(from: paths.configURL)

        switch config.guest {
        case .macos:
            try installMacOS(paths: paths, config: &config)
            try saveConfig(config, to: paths.configURL)
        case .windows:
            throw VMToolError.unsupported("""
            Windows installation is experimental and cannot be automated like Hyper-V DISM install.
            Apple Virtualization.framework has no Windows installer or IPSW path. Use a prepared ARM64 Windows raw disk image, or boot/install manually with a hypervisor that supports Windows install media and vTPM.
            """)
        }
    }

    static func runVM(_ options: Options) throws {
        let name = try validateName(options.required("name"))
        guard let networkMode = NetworkMode(rawValue: options.string("internet") ?? "isolated") else {
            throw VMToolError.usage("--internet must be isolated, nat, or bridged")
        }
        let bridgeInterface = options.string("bridge-interface")
        let shareURL = options.string("share").map { URL(fileURLWithPath: $0).standardizedFileURL }

        let store = try VMStore.default()
        let paths = store.paths(for: name)
        let config = try loadConfig(from: paths.configURL)

        if config.guest == .macos && !config.installed {
            throw VMToolError.invalidState("VM '\(name)' has no OS installed — run `vmctl install --name \(name)` first.")
        }

        let vmConfig = try buildVirtualMachineConfiguration(
            paths: paths,
            config: config,
            networkMode: networkMode,
            bridgeInterface: bridgeInterface,
            shareURL: shareURL ?? paths.sharedURL
        )

        try validate(vmConfig)
        try "\(getpid())\n".write(to: paths.runPIDURL, atomically: true, encoding: .utf8)
        let app = RunApp(paths: paths, vmConfiguration: vmConfig, title: "\(config.name) (\(config.guest.rawValue))")
        withExtendedLifetime(app) {
            app.start()
        }
    }

    static func stop(_ options: Options) throws {
        let name = try validateName(options.required("name"))
        let store = try VMStore.default()
        let paths = store.paths(for: name)
        guard let pid = runningVMCTLPID(at: paths.runPIDURL) else {
            try? FileManager.default.removeItem(at: paths.runPIDURL)
            print("VM '\(name)' is not running.")
            return
        }

        if kill(pid, SIGTERM) == 0 {
            print("Requested stop for \(name) via vmctl process \(pid).")
        } else {
            throw VMToolError.invalidState("Failed to signal process \(pid). It may already be stopped.")
        }
    }

    static func snapshot(_ args: [String]) throws {
        guard let action = args.first else {
            throw VMToolError.usage("snapshot requires save or restore")
        }
        let options = try Options(Array(args.dropFirst()))
        let name = try validateName(options.required("name"))
        let label = try validateName(options.required("label"))
        let store = try VMStore.default()
        let paths = store.paths(for: name)
        let snapshotURL = paths.snapshotsURL.appendingPathComponent(label, isDirectory: true)

        switch action {
        case "save":
            try saveSnapshot(paths: paths, snapshotURL: snapshotURL)
            print("Saved snapshot '\(label)' for \(name).")
        case "restore":
            try restoreSnapshot(paths: paths, snapshotURL: snapshotURL)
            print("Restored snapshot '\(label)' for \(name).")
        default:
            throw VMToolError.usage("snapshot requires save or restore")
        }
    }

    static func copyOut(_ options: Options) throws {
        let name = try validateName(options.required("name"))
        let from = try options.required("from")
        let to = URL(fileURLWithPath: try options.required("to")).standardizedFileURL
        let store = try VMStore.default()
        let paths = store.paths(for: name)
        let source = paths.sharedURL.appendingPathComponent(from)

        guard FileManager.default.fileExists(atPath: source.path) else {
            throw VMToolError.notFound("Shared path does not exist: \(source.path)")
        }

        try FileManager.default.createDirectory(at: to, withIntermediateDirectories: true)
        if isDirectory(source) {
            // Copy the directory's contents into the destination (matching the
            // Hyper-V Copy-Artifacts behavior) rather than nesting the source
            // directory itself under --to.
            let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for child in children {
                try copyReplacing(child, into: to)
            }
        } else {
            try copyReplacing(source, into: to)
        }
        print("Copied from shared VM directory to \(to.path)")
    }

    static func list(_ options: Options) throws {
        let store = try VMStore.default()
        let bundles = (try? FileManager.default.contentsOfDirectory(at: store.rootURL, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "agentvm" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        guard !bundles.isEmpty else {
            print("No VMs found under \(store.rootURL.path)")
            return
        }

        print("NAME\tGUEST\tINSTALLED\tSTATE")
        for bundle in bundles {
            let paths = VMPaths(bundleURL: bundle)
            let name = bundle.deletingPathExtension().lastPathComponent
            guard let config = try? loadConfig(from: paths.configURL) else {
                print("\(name)\t?\t?\t(unreadable config)")
                continue
            }
            let state = runningVMCTLPID(at: paths.runPIDURL) != nil ? "running" : "stopped"
            print("\(name)\t\(config.guest.rawValue)\t\(config.installed)\t\(state)")
        }
    }

    static func delete(_ options: Options) throws {
        let name = try validateName(options.required("name"))
        let store = try VMStore.default()
        let paths = store.paths(for: name)
        guard FileManager.default.fileExists(atPath: paths.bundleURL.path) else {
            throw VMToolError.notFound("VM bundle not found: \(paths.bundleURL.path)")
        }
        if runningVMCTLPID(at: paths.runPIDURL) != nil {
            throw VMToolError.invalidState("VM '\(name)' appears to be running. Stop it before deleting.")
        }
        try FileManager.default.removeItem(at: paths.bundleURL)
        print("Deleted VM bundle: \(paths.bundleURL.path)")
    }

    static func path(_ options: Options) throws {
        let name = try validateName(options.required("name"))
        let store = try VMStore.default()
        let paths = store.paths(for: name)
        print((options.bool("shared") ? paths.sharedURL : paths.bundleURL).path)
    }

    static func info(_ options: Options) throws {
        let name = try validateName(options.required("name"))
        let store = try VMStore.default()
        let paths = store.paths(for: name)
        let config = try loadConfig(from: paths.configURL)
        let data = try JSONEncoder.pretty.encode(config)
        print(String(decoding: data, as: UTF8.self))
    }
}

// MARK: - VM Creation

extension VMCTL {
    static func createMacMetadata(options: Options, paths: VMPaths, config: inout VMConfig) throws {
        #if arch(arm64)
        let restoreURL: URL
        if options.bool("latest") {
            restoreURL = try fetchLatestRestoreImage(cacheRoot: paths.bundleURL.deletingLastPathComponent().appendingPathComponent("RestoreImages", isDirectory: true))
        } else {
            restoreURL = URL(fileURLWithPath: try options.required("ipsw")).standardizedFileURL
        }

        guard FileManager.default.fileExists(atPath: restoreURL.path) else {
            throw VMToolError.notFound("macOS IPSW not found: \(restoreURL.path)")
        }

        let image = try loadRestoreImage(from: restoreURL)
        guard image.isSupported else {
            throw VMToolError.unsupported("Restore image is not supported by this host: \(restoreURL.path)")
        }
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw VMToolError.unsupported("Restore image does not contain a host-supported macOS configuration")
        }

        let hardwareModel = requirements.hardwareModel
        guard hardwareModel.isSupported else {
            throw VMToolError.unsupported("Restore image hardware model is not supported on this host")
        }

        try hardwareModel.dataRepresentation.write(to: paths.hardwareModelURL)
        let machineIdentifier = VZMacMachineIdentifier()
        try machineIdentifier.dataRepresentation.write(to: paths.machineIdentifierURL)
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: paths.auxiliaryStorageURL,
            hardwareModel: hardwareModel,
            options: [.allowOverwrite]
        )

        config.restoreImagePath = restoreURL.path
        config.restoreBuildVersion = image.buildVersion
        config.restoreOSVersion = "\(image.operatingSystemVersion.majorVersion).\(image.operatingSystemVersion.minorVersion).\(image.operatingSystemVersion.patchVersion)"
        config.cpuCount = max(config.cpuCount, requirements.minimumSupportedCPUCount)
        config.memorySizeBytes = max(config.memorySizeBytes, requirements.minimumSupportedMemorySize)
        #else
        throw VMToolError.unsupported("macOS guest virtualization from IPSW requires Apple Silicon")
        #endif
    }

    static func createWindowsMetadata(options: Options, paths: VMPaths, config: inout VMConfig) throws {
        let installer = URL(fileURLWithPath: try options.required("iso")).standardizedFileURL
        guard FileManager.default.fileExists(atPath: installer.path) else {
            throw VMToolError.notFound("Windows ARM64 media not found: \(installer.path)")
        }

        _ = try VZEFIVariableStore(
            creatingVariableStoreAt: paths.efiVariableStoreURL,
            options: [.allowOverwrite]
        )
        config.installerMediaPath = installer.path
        config.notes.append("Windows support is experimental. Virtualization.framework does not provide Windows IPSW, Windows installer automation, PowerShell Direct, vTPM, or guest tools.")
        config.notes.append("Use an ARM64 Windows raw boot disk for practical runs; ISO media is recorded for reference but is not automatically installed.")
    }
}

// MARK: - Virtualization Configuration

func buildVirtualMachineConfiguration(
    paths: VMPaths,
    config stored: VMConfig,
    networkMode: NetworkMode,
    bridgeInterface: String?,
    shareURL: URL
) throws -> VZVirtualMachineConfiguration {
    switch stored.guest {
    case .macos:
        return try buildMacConfiguration(paths: paths, stored: stored, networkMode: networkMode, bridgeInterface: bridgeInterface, shareURL: shareURL)
    case .windows:
        return try buildGenericEFIConfiguration(paths: paths, stored: stored, networkMode: networkMode, bridgeInterface: bridgeInterface)
    }
}

func buildMacConfiguration(
    paths: VMPaths,
    stored: VMConfig,
    networkMode: NetworkMode,
    bridgeInterface: String?,
    shareURL: URL
) throws -> VZVirtualMachineConfiguration {
    #if arch(arm64)
    let configuration = VZVirtualMachineConfiguration()
    configuration.cpuCount = stored.cpuCount
    configuration.memorySize = stored.memorySizeBytes
    configuration.bootLoader = VZMacOSBootLoader()

    let hardwareData = try Data(contentsOf: paths.hardwareModelURL)
    let identifierData = try Data(contentsOf: paths.machineIdentifierURL)
    guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData),
          let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: identifierData) else {
        throw VMToolError.invalidState("Stored macOS hardware metadata is invalid")
    }

    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = hardwareModel
    platform.machineIdentifier = machineIdentifier
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: paths.auxiliaryStorageURL)
    configuration.platform = platform

    configuration.storageDevices = [try virtioBlockDevice(url: paths.diskURL, readOnly: false)]
    configuration.networkDevices = try networkDevices(mode: networkMode, bridgeInterface: bridgeInterface)
    configuration.graphicsDevices = [macGraphics()]
    configuration.keyboards = [VZMacKeyboardConfiguration()]
    configuration.pointingDevices = [VZMacTrackpadConfiguration()]

    if FileManager.default.fileExists(atPath: shareURL.path) {
        let sharedDirectory = VZSharedDirectory(url: shareURL, readOnly: false)
        let share = VZSingleDirectoryShare(directory: sharedDirectory)
        let fileSystem = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        fileSystem.share = share
        configuration.directorySharingDevices = [fileSystem]
    }

    return configuration
    #else
    throw VMToolError.unsupported("macOS guest virtualization from IPSW requires Apple Silicon")
    #endif
}

func buildGenericEFIConfiguration(
    paths: VMPaths,
    stored: VMConfig,
    networkMode: NetworkMode,
    bridgeInterface: String?
) throws -> VZVirtualMachineConfiguration {
    let configuration = VZVirtualMachineConfiguration()
    configuration.cpuCount = stored.cpuCount
    configuration.memorySize = stored.memorySizeBytes
    configuration.platform = VZGenericPlatformConfiguration()

    let bootLoader = VZEFIBootLoader()
    bootLoader.variableStore = VZEFIVariableStore(url: paths.efiVariableStoreURL)
    configuration.bootLoader = bootLoader

    var storageDevices: [VZStorageDeviceConfiguration] = [
        try nvmeDevice(url: paths.diskURL, readOnly: false)
    ]

    if let installerPath = stored.installerMediaPath {
        let installerURL = URL(fileURLWithPath: installerPath).standardizedFileURL
        if installerURL.pathExtension.lowercased() == "raw" || installerURL.pathExtension.lowercased() == "img" {
            storageDevices.append(try usbMassStorageDevice(url: installerURL, readOnly: true))
        }
    }
    configuration.storageDevices = storageDevices

    configuration.networkDevices = try networkDevices(mode: networkMode, bridgeInterface: bridgeInterface)
    configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    configuration.graphicsDevices = [virtioGraphics()]
    configuration.keyboards = [VZUSBKeyboardConfiguration()]
    configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
    if #available(macOS 15.0, *) {
        configuration.usbControllers = [VZXHCIControllerConfiguration()]
    }

    return configuration
}

func virtioBlockDevice(url: URL, readOnly: Bool) throws -> VZVirtioBlockDeviceConfiguration {
    let attachment = try VZDiskImageStorageDeviceAttachment(
        url: url,
        readOnly: readOnly,
        cachingMode: .automatic,
        synchronizationMode: .fsync
    )
    return VZVirtioBlockDeviceConfiguration(attachment: attachment)
}

func nvmeDevice(url: URL, readOnly: Bool) throws -> VZNVMExpressControllerDeviceConfiguration {
    let attachment = try VZDiskImageStorageDeviceAttachment(
        url: url,
        readOnly: readOnly,
        cachingMode: .automatic,
        synchronizationMode: .fsync
    )
    return VZNVMExpressControllerDeviceConfiguration(attachment: attachment)
}

func usbMassStorageDevice(url: URL, readOnly: Bool) throws -> VZUSBMassStorageDeviceConfiguration {
    let attachment = try VZDiskImageStorageDeviceAttachment(
        url: url,
        readOnly: readOnly,
        cachingMode: .automatic,
        synchronizationMode: .fsync
    )
    return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
}

func networkDevices(mode: NetworkMode, bridgeInterface: String?) throws -> [VZNetworkDeviceConfiguration] {
    switch mode {
    case .isolated:
        return []
    case .nat:
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZNATNetworkDeviceAttachment()
        return [device]
    case .bridged:
        let interfaces = VZBridgedNetworkInterface.networkInterfaces
        let selected: VZBridgedNetworkInterface?
        if let bridgeInterface {
            selected = interfaces.first { $0.identifier == bridgeInterface }
        } else {
            selected = interfaces.first
        }
        guard let selected else {
            throw VMToolError.notFound("No bridged network interface found")
        }
        let device = VZVirtioNetworkDeviceConfiguration()
        device.attachment = VZBridgedNetworkDeviceAttachment(interface: selected)
        return [device]
    }
}

func macGraphics() -> VZMacGraphicsDeviceConfiguration {
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [
        VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 80)
    ]
    return graphics
}

func virtioGraphics() -> VZVirtioGraphicsDeviceConfiguration {
    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [
        VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1080)
    ]
    return graphics
}

func validate(_ configuration: VZVirtualMachineConfiguration) throws {
    try configuration.validate()
}

// MARK: - macOS Restore/Install

extension VMCTL {
    static func installMacOS(paths: VMPaths, config: inout VMConfig) throws {
        #if arch(arm64)
        guard let restoreImagePath = config.restoreImagePath else {
            throw VMToolError.invalidState("Missing restore image path in VM config")
        }

        let vmConfig = try buildMacConfiguration(
            paths: paths,
            stored: config,
            networkMode: .nat,
            bridgeInterface: nil,
            shareURL: paths.sharedURL
        )
        try validate(vmConfig)

        let queue = DispatchQueue(label: "agent-sandbox.vm.install")
        let virtualMachine = VZVirtualMachine(configuration: vmConfig, queue: queue)
        let restoreURL = URL(fileURLWithPath: restoreImagePath).standardizedFileURL
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var error: Error?
        }
        let box = Box()

        print("Installing macOS from \(restoreURL.path)")
        queue.async {
            let installer = VZMacOSInstaller(virtualMachine: virtualMachine, restoringFromImageAt: restoreURL)
            var lastPercent = -1
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .seconds(5))
            timer.setEventHandler {
                let percent = Int(installer.progress.fractionCompleted * 100)
                if percent != lastPercent {
                    lastPercent = percent
                    print("Install progress: \(percent)%")
                }
            }
            timer.resume()

            installer.install { result in
                timer.cancel()
                if case .failure(let error) = result {
                    box.error = error
                }
                semaphore.signal()
            }
        }

        semaphore.wait()
        if let error = box.error {
            throw error
        }

        config.installed = true
        print("macOS installation completed.")
        #else
        throw VMToolError.unsupported("macOS guest virtualization from IPSW requires Apple Silicon")
        #endif
    }
}

#if arch(arm64)
func loadRestoreImage(from url: URL) throws -> VZMacOSRestoreImage {
    let semaphore = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable {
        var image: VZMacOSRestoreImage?
        var error: Error?
    }
    let box = Box()

    VZMacOSRestoreImage.load(from: url) { result in
        switch result {
        case .success(let image):
            box.image = image
        case .failure(let error):
            box.error = error
        }
        semaphore.signal()
    }
    semaphore.wait()

    if let error = box.error { throw error }
    guard let image = box.image else {
        throw VMToolError.virtualization("Failed to load restore image")
    }
    return image
}

func fetchLatestRestoreImage(cacheRoot: URL) throws -> URL {
    let semaphore = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable {
        var image: VZMacOSRestoreImage?
        var error: Error?
    }
    let box = Box()

    VZMacOSRestoreImage.fetchLatestSupported { result in
        switch result {
        case .success(let image):
            box.image = image
        case .failure(let error):
            box.error = error
        }
        semaphore.signal()
    }
    semaphore.wait()

    if let error = box.error { throw error }
    guard let image = box.image else {
        throw VMToolError.virtualization("Could not fetch latest supported restore image metadata")
    }

    try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
    let filename = image.url.lastPathComponent.isEmpty ? "latest-supported.ipsw" : image.url.lastPathComponent
    let destination = cacheRoot.appendingPathComponent(filename)
    if FileManager.default.fileExists(atPath: destination.path) {
        return destination
    }

    print("Downloading latest supported macOS restore image to \(destination.path)")
    let partial = destination.appendingPathExtension("partial")
    if FileManager.default.fileExists(atPath: partial.path) {
        try FileManager.default.removeItem(at: partial)
    }

    let downloadSemaphore = DispatchSemaphore(value: 0)
    final class DownloadBox: @unchecked Sendable {
        var location: URL?
        var error: Error?
    }
    let downloadBox = DownloadBox()
    let task = URLSession.shared.downloadTask(with: image.url) { location, _, error in
        downloadBox.location = location
        downloadBox.error = error
        downloadSemaphore.signal()
    }

    let progressQueue = DispatchQueue(label: "agent-sandbox.vm.download")
    let timer = DispatchSource.makeTimerSource(queue: progressQueue)
    timer.schedule(deadline: .now() + 5, repeating: .seconds(5))
    var lastPercent = -1
    timer.setEventHandler {
        let percent = Int(task.progress.fractionCompleted * 100)
        if percent != lastPercent {
            lastPercent = percent
            print("Download progress: \(percent)%")
        }
    }
    timer.resume()
    task.resume()
    downloadSemaphore.wait()
    timer.cancel()

    if let error = downloadBox.error { throw error }
    guard let location = downloadBox.location else {
        throw VMToolError.virtualization("Restore image download did not produce a file")
    }
    // Stage through a .partial path so an aborted download never leaves a
    // truncated file at the cached destination.
    try FileManager.default.moveItem(at: location, to: partial)
    try FileManager.default.moveItem(at: partial, to: destination)
    return destination
}
#endif

// MARK: - GUI Runner

final class RunApp: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate {
    private let paths: VMPaths
    private let vmConfiguration: VZVirtualMachineConfiguration
    private let title: String
    private var virtualMachine: VZVirtualMachine?
    private var window: NSWindow?
    private var termSource: DispatchSourceSignal?
    private var intSource: DispatchSourceSignal?
    private var stopRequested = false

    init(paths: VMPaths, vmConfiguration: VZVirtualMachineConfiguration, title: String) {
        self.paths = paths
        self.vmConfiguration = vmConfiguration
        self.title = title
    }

    func start() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.capturesSystemKeys = true
        if #available(macOS 14.0, *) {
            view.automaticallyReconfiguresDisplay = true
        }

        let vm = VZVirtualMachine(configuration: vmConfiguration)
        vm.delegate = self
        virtualMachine = vm
        view.virtualMachine = vm

        let window = NSWindow(
            contentRect: view.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.delegate = self
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        installSignalHandlers()
        NSApplication.shared.activate(ignoringOtherApps: true)

        vm.start { result in
            if case .failure(let error) = result {
                FileHandle.standardError.write(Data("Failed to start VM: \(error.localizedDescription)\n".utf8))
                NSApplication.shared.terminate(nil)
            } else {
                print("VM started. Close the window or run vmctl stop --name <name> to request shutdown.")
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestStop()
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // First close requests a graceful guest shutdown; the window stays open
        // until the guest actually stops (guestDidStop terminates the app). A
        // second close while a stop is already pending escalates to a force stop.
        if stopRequested {
            forceStopIfNeeded()
        } else {
            print("Window close requested; asking guest to shut down. Close again to force.")
            requestStop()
        }
        return false
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        cleanupAndTerminate()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("VM stopped with error: \(error.localizedDescription)\n".utf8))
        cleanupAndTerminate()
    }

    private func installSignalHandlers() {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource?.setEventHandler { [weak self] in self?.requestStop() }
        termSource?.resume()

        intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource?.setEventHandler { [weak self] in self?.requestStop() }
        intSource?.resume()
    }

    private func requestStop() {
        stopRequested = true
        guard let vm = virtualMachine else {
            cleanupAndTerminate()
            return
        }

        if vm.canRequestStop {
            do {
                try vm.requestStop()
            } catch {
                FileHandle.standardError.write(Data("Guest shutdown request failed: \(error.localizedDescription)\n".utf8))
                forceStopIfNeeded()
                return
            }
            print("Requested guest shutdown.")
        } else {
            forceStopIfNeeded()
        }
    }

    private func forceStopIfNeeded() {
        guard let vm = virtualMachine else {
            cleanupAndTerminate()
            return
        }
        if vm.state == .stopped {
            cleanupAndTerminate()
            return
        }
        if vm.canStop {
            vm.stop { [weak self] error in
                if let error {
                    FileHandle.standardError.write(Data("Force stop failed: \(error.localizedDescription)\n".utf8))
                }
                self?.cleanupAndTerminate()
            }
        } else {
            cleanupAndTerminate()
        }
    }

    private func cleanupAndTerminate() {
        try? FileManager.default.removeItem(at: paths.runPIDURL)
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Process Helpers

/// Returns the PID recorded in the pidfile only if it belongs to a live `vmctl`
/// process. A dead PID, a recycled PID owned by some unrelated process, or a
/// missing pidfile all yield nil so callers don't signal or block on stale state.
func runningVMCTLPID(at pidURL: URL) -> Int32? {
    guard let pidText = try? String(contentsOf: pidURL, encoding: .utf8),
          let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)),
          kill(pid, 0) == 0 else {
        return nil
    }

    var buffer = [UInt8](repeating: 0, count: 4096)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let path = String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    let executable = URL(fileURLWithPath: path).lastPathComponent
    return executable == "vmctl" ? pid : nil
}

// MARK: - Snapshot Helpers

func saveSnapshot(paths: VMPaths, snapshotURL: URL) throws {
    if runningVMCTLPID(at: paths.runPIDURL) != nil {
        throw VMToolError.invalidState("VM appears to be running. Stop it before saving a disk snapshot.")
    }

    if FileManager.default.fileExists(atPath: snapshotURL.path) {
        try FileManager.default.removeItem(at: snapshotURL)
    }
    try FileManager.default.createDirectory(at: snapshotURL, withIntermediateDirectories: true)
    for item in snapshotItems(paths: paths) where FileManager.default.fileExists(atPath: item.path) {
        try FileManager.default.copyItem(at: item, to: snapshotURL.appendingPathComponent(item.lastPathComponent))
    }
}

func restoreSnapshot(paths: VMPaths, snapshotURL: URL) throws {
    guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
        throw VMToolError.notFound("Snapshot not found: \(snapshotURL.path)")
    }
    if runningVMCTLPID(at: paths.runPIDURL) != nil {
        throw VMToolError.invalidState("VM appears to be running. Stop it before restoring a disk snapshot.")
    }

    for item in snapshotItems(paths: paths) {
        let source = snapshotURL.appendingPathComponent(item.lastPathComponent)
        guard FileManager.default.fileExists(atPath: source.path) else { continue }
        if FileManager.default.fileExists(atPath: item.path) {
            try FileManager.default.removeItem(at: item)
        }
        try FileManager.default.copyItem(at: source, to: item)
    }
}

func snapshotItems(paths: VMPaths) -> [URL] {
    [
        paths.configURL,
        paths.diskURL,
        paths.auxiliaryStorageURL,
        paths.hardwareModelURL,
        paths.machineIdentifierURL,
        paths.efiVariableStoreURL
    ]
}

// MARK: - File Helpers

func createRawDisk(at url: URL, sizeBytes: UInt64) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: sizeBytes)
}

func loadConfig(from url: URL) throws -> VMConfig {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw VMToolError.notFound("VM config not found: \(url.path)")
    }
    return try JSONDecoder().decode(VMConfig.self, from: Data(contentsOf: url))
}

func saveConfig(_ config: VMConfig, to url: URL) throws {
    try JSONEncoder.pretty.encode(config).write(to: url, options: [.atomic])
}

func validateName(_ name: String) throws -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard !name.isEmpty, name.rangeOfCharacter(from: allowed.inverted) == nil else {
        throw VMToolError.usage("Name may contain only letters, digits, dash, underscore, and dot")
    }
    return name
}

func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    return isDir.boolValue
}

/// Copies `source` into `directory` under its own name, replacing any existing
/// item at the destination.
func copyReplacing(_ source: URL, into directory: URL) throws {
    let dest = directory.appendingPathComponent(source.lastPathComponent)
    if FileManager.default.fileExists(atPath: dest.path) {
        try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.copyItem(at: source, to: dest)
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
