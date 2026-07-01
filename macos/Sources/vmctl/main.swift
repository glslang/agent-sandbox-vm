@preconcurrency import AppKit
import Darwin
import Foundation
@preconcurrency import Virtualization

/// Error categories surfaced to the user; the associated string is printed as
/// the CLI's error message.
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

/// The kind of guest OS a bundle hosts, selecting the boot/platform path.
enum GuestKind: String, Codable {
    case macos
    case windows
}

/// Guest networking mode chosen at `run` time.
enum NetworkMode: String {
    case isolated
    case nat
    case bridged
}

/// Persisted per-VM metadata, stored as `config.json` inside the bundle.
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

/// Computed locations of the files that make up a single VM bundle.
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

/// The directory that holds all VM bundles, rooted at
/// `~/.agent-sandbox/macos-vms` or the `AGENT_SANDBOX_VM_ROOT` override.
struct VMStore {
    let rootURL: URL

    /// Returns the store root, honoring the `AGENT_SANDBOX_VM_ROOT` override.
    static func `default`() throws -> VMStore {
        if let override = ProcessInfo.processInfo.environment["AGENT_SANDBOX_VM_ROOT"], !override.isEmpty {
            return VMStore(rootURL: URL(fileURLWithPath: override).standardizedFileURL)
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        return VMStore(rootURL: home.appendingPathComponent(".agent-sandbox/macos-vms", isDirectory: true))
    }

    /// Resolves the bundle paths for the VM named `name`.
    func paths(for name: String) -> VMPaths {
        VMPaths(bundleURL: rootURL.appendingPathComponent("\(name).agentvm", isDirectory: true))
    }

    /// Creates the store root directory if it does not yet exist.
    func ensureRoot() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
}

/// A minimal `--key value` / `--flag` command-line parser shared by all
/// subcommands.
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

    /// The last value supplied for `--key`, or nil if absent.
    func string(_ key: String) -> String? {
        values[key]?.last
    }

    /// The value for `--key`, throwing a usage error if missing or empty.
    func required(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else {
            throw VMToolError.usage("Missing required option --\(key)")
        }
        return value
    }

    /// A positive integer value for `--key`, or `defaultValue` if absent.
    func int(_ key: String, default defaultValue: Int) throws -> Int {
        guard let value = string(key) else { return defaultValue }
        guard let parsed = Int(value), parsed > 0 else {
            throw VMToolError.usage("--\(key) must be a positive integer")
        }
        return parsed
    }

    /// Whether the boolean flag `--key` was present.
    func bool(_ key: String) -> Bool {
        flags.contains(key)
    }
}

/// Program entry point and subcommand dispatcher.
@main
struct VMCTL {
    /// Parses `CommandLine.arguments`, dispatches the subcommand, and maps any
    /// thrown error to a stderr message + non-zero exit.
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("vmctl: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    /// Routes `args` to the matching subcommand handler.
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

    /// Prints the command reference.
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
    /// `create`: provisions a new VM bundle (raw disk, platform metadata,
    /// `config.json`) for a macOS or Windows guest. Does not install an OS.
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
        // Roll back the partially-created bundle if any later step (disk
        // allocation, restore-image download, metadata) fails, so the command
        // can simply be re-run instead of tripping the "already exists" guard.
        do {
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
        } catch {
            try? FileManager.default.removeItem(at: paths.bundleURL)
            throw error
        }
        print("Created \(guest.rawValue) VM bundle: \(paths.bundleURL.path)")
        print("Shared directory: \(paths.sharedURL.path)")
    }

    /// `install`: restores macOS into the bundle's disk from its IPSW. Windows
    /// installation is unsupported and fails with an explanation.
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

    /// `run`: boots the VM in a window, holding the run lock for the session.
    /// Refuses if the guest OS is not installed or the VM is already running.
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

        // Claim the run lock before starting; if another instance already holds
        // it the VM is running, and we must not overwrite its pidfile.
        guard let runLock = RunLock.acquire(at: paths.runPIDURL) else {
            throw VMToolError.invalidState("VM '\(name)' is already running.")
        }

        // The `run` command executes on the process's main thread (synchronous
        // `@main`), and `RunApp` is main-actor isolated, so build and drive it on
        // the main actor.
        MainActor.assumeIsolated {
            let app = RunApp(
                paths: paths,
                vmConfiguration: vmConfig,
                title: "\(config.name) (\(config.guest.rawValue))",
                runLock: runLock
            )
            withExtendedLifetime(app) {
                app.start()
            }
        }
    }

    /// `stop`: requests shutdown of a running VM by signaling its `run` process.
    static func stop(_ options: Options) throws {
        let name = try validateName(options.required("name"))
        let store = try VMStore.default()
        let paths = store.paths(for: name)
        guard isVMRunning(pidURL: paths.runPIDURL) else {
            print("VM '\(name)' is not running.")
            return
        }
        guard let pid = recordedPID(at: paths.runPIDURL) else {
            throw VMToolError.invalidState("VM '\(name)' is running but its pidfile is unreadable.")
        }

        if kill(pid, SIGTERM) == 0 {
            print("Requested stop for \(name) via vmctl process \(pid).")
        } else {
            throw VMToolError.invalidState("Failed to signal process \(pid). It may already be stopped.")
        }
    }

    /// `snapshot save|restore`: copies the bundle's disk/metadata to or from a
    /// labeled snapshot directory. Refuses while the VM is running.
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

    /// `copy-out`: copies a file (or a directory's contents) from the bundle's
    /// shared directory to a host path. `--from` is constrained to the share.
    static func copyOut(_ options: Options) throws {
        let name = try validateName(options.required("name"))
        let from = try options.required("from")
        let to = URL(fileURLWithPath: try options.required("to")).standardizedFileURL
        let store = try VMStore.default()
        let paths = store.paths(for: name)
        let source = paths.sharedURL.appendingPathComponent(from).standardizedFileURL

        // Keep --from inside the shared directory; standardizing above collapses
        // any ".." so a traversal like "../../Disk.raw" is rejected here.
        let sharedRoot = paths.sharedURL.standardizedFileURL.path
        guard source.path == sharedRoot || source.path.hasPrefix(sharedRoot + "/") else {
            throw VMToolError.usage("--from must stay within the shared directory")
        }

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

    /// `list`: prints each bundle's name, guest kind, install state, and whether
    /// it is currently running.
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
            let state = isVMRunning(pidURL: paths.runPIDURL) ? "running" : "stopped"
            print("\(name)\t\(config.guest.rawValue)\t\(config.installed)\t\(state)")
        }
    }

    /// `delete`: removes a VM bundle from disk. Refuses while it is running.
    static func delete(_ options: Options) throws {
        let name = try validateName(options.required("name"))
        let store = try VMStore.default()
        let paths = store.paths(for: name)
        guard FileManager.default.fileExists(atPath: paths.bundleURL.path) else {
            throw VMToolError.notFound("VM bundle not found: \(paths.bundleURL.path)")
        }
        if isVMRunning(pidURL: paths.runPIDURL) {
            throw VMToolError.invalidState("VM '\(name)' appears to be running. Stop it before deleting.")
        }
        try FileManager.default.removeItem(at: paths.bundleURL)
        print("Deleted VM bundle: \(paths.bundleURL.path)")
    }

    /// `path`: prints the bundle directory, or its shared directory with `--shared`.
    static func path(_ options: Options) throws {
        let name = try validateName(options.required("name"))
        let store = try VMStore.default()
        let paths = store.paths(for: name)
        print((options.bool("shared") ? paths.sharedURL : paths.bundleURL).path)
    }

    /// `info`: prints the VM's `config.json` as pretty-printed JSON.
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
    /// Validates the macOS restore image and writes the hardware model, machine
    /// identifier, and auxiliary storage into the bundle, updating `config`.
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

    /// Records the Windows installer media path and creates the EFI variable
    /// store, noting the experimental limitations in `config`.
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

/// Builds the VZ configuration for a bundle, dispatching to the macOS
/// hardware-backed path or the generic EFI path by guest kind.
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

/// Builds a macOS guest configuration with the Mac platform, boot loader,
/// virtio block disk, devices, and an optional VirtioFS shared directory.
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

/// Builds a generic EFI guest configuration (used for Windows ARM64): EFI boot
/// loader, NVMe disk, optional USB installer media, and USB input devices.
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

/// A virtio block storage device backed by the disk image at `url`.
func virtioBlockDevice(url: URL, readOnly: Bool) throws -> VZVirtioBlockDeviceConfiguration {
    let attachment = try VZDiskImageStorageDeviceAttachment(
        url: url,
        readOnly: readOnly,
        cachingMode: .automatic,
        synchronizationMode: .fsync
    )
    return VZVirtioBlockDeviceConfiguration(attachment: attachment)
}

/// An NVMe storage device backed by the disk image at `url`.
func nvmeDevice(url: URL, readOnly: Bool) throws -> VZNVMExpressControllerDeviceConfiguration {
    let attachment = try VZDiskImageStorageDeviceAttachment(
        url: url,
        readOnly: readOnly,
        cachingMode: .automatic,
        synchronizationMode: .fsync
    )
    return VZNVMExpressControllerDeviceConfiguration(attachment: attachment)
}

/// A USB mass-storage device backed by the disk image at `url` (installer media).
func usbMassStorageDevice(url: URL, readOnly: Bool) throws -> VZUSBMassStorageDeviceConfiguration {
    let attachment = try VZDiskImageStorageDeviceAttachment(
        url: url,
        readOnly: readOnly,
        cachingMode: .automatic,
        synchronizationMode: .fsync
    )
    return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
}

/// Builds the network devices for the chosen mode (none/NAT/bridged), resolving
/// the bridged interface by identifier when one is given.
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

/// A 1080p Mac graphics device for macOS guests.
func macGraphics() -> VZMacGraphicsDeviceConfiguration {
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [
        VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1080, pixelsPerInch: 80)
    ]
    return graphics
}

/// A 1080p virtio graphics device for generic EFI guests.
func virtioGraphics() -> VZVirtioGraphicsDeviceConfiguration {
    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [
        VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1080)
    ]
    return graphics
}

/// Validates a VZ configuration, throwing if the host rejects it.
func validate(_ configuration: VZVirtualMachineConfiguration) throws {
    try configuration.validate()
}

// MARK: - macOS Restore/Install

extension VMCTL {
    /// Runs `VZMacOSInstaller` to restore macOS into the bundle's disk, printing
    /// progress, and marks the config installed on success.
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
/// Loads restore-image metadata from a local IPSW (synchronously).
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

/// Fetches metadata for the latest supported restore image and downloads it
/// (with progress) into `cacheRoot`, reusing a cached copy when present.
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
    try downloadFile(from: image.url, to: destination, attempts: 5)
    return destination
}

/// Downloads `url` to `destination`, staging through a `.partial` file so an
/// aborted transfer never leaves a truncated file at the cached destination.
/// Retries transient network failures, resuming from where it left off whenever
/// the server hands back resume data (these restore images are ~16 GB, so a mid
/// transfer drop should not force the whole download to start over).
func downloadFile(from url: URL, to destination: URL, attempts: Int) throws {
    let partial = destination.appendingPathExtension("partial")
    if FileManager.default.fileExists(atPath: partial.path) {
        try FileManager.default.removeItem(at: partial)
    }

    final class DownloadBox: @unchecked Sendable {
        var location: URL?
        var error: Error?
    }

    var resumeData: Data?
    var lastError: Error?

    for attempt in 1...attempts {
        let downloadSemaphore = DispatchSemaphore(value: 0)
        let downloadBox = DownloadBox()
        let completion: @Sendable (URL?, URLResponse?, Error?) -> Void = { location, _, error in
            downloadBox.location = location
            downloadBox.error = error
            downloadSemaphore.signal()
        }
        let task: URLSessionDownloadTask = resumeData.map {
            URLSession.shared.downloadTask(withResumeData: $0, completionHandler: completion)
        } ?? URLSession.shared.downloadTask(with: url, completionHandler: completion)

        let progressQueue = DispatchQueue(label: "agent-sandbox.vm.download")
        let timer = DispatchSource.makeTimerSource(queue: progressQueue)
        timer.schedule(deadline: .now() + 5, repeating: .seconds(5))
        // Report bytes received directly. task.progress.fractionCompleted often
        // stays at 0 for these downloads because the CDN does not give the
        // Progress object a usable total, so percentage alone looks "stuck"
        // even while ~16 GB streams in fine. countOfBytesReceived always moves.
        let gib = 1_073_741_824.0
        var lastReport = ""
        timer.setEventHandler {
            let received = task.countOfBytesReceived
            let expected = task.countOfBytesExpectedToReceive
            let report: String
            if expected > 0 {
                let percent = Int(Double(received) / Double(expected) * 100)
                report = String(format: "Download progress: %d%% (%.2f / %.2f GB)",
                                percent, Double(received) / gib, Double(expected) / gib)
            } else {
                report = String(format: "Download progress: %.2f GB", Double(received) / gib)
            }
            if report != lastReport {
                lastReport = report
                print(report)
            }
        }
        timer.resume()
        task.resume()
        downloadSemaphore.wait()
        timer.cancel()

        if let error = downloadBox.error {
            lastError = error
            // Keep resume data so the next attempt continues instead of restarting.
            resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if attempt < attempts {
                let backoff = min(30, attempt * 5)
                let resuming = resumeData != nil ? " (resuming)" : " (restarting)"
                FileHandle.standardError.write(Data(
                    "Download attempt \(attempt)/\(attempts) failed: \(error.localizedDescription). Retrying in \(backoff)s\(resuming)...\n".utf8))
                Thread.sleep(forTimeInterval: Double(backoff))
            }
            continue
        }
        guard let location = downloadBox.location else {
            lastError = VMToolError.virtualization("Restore image download did not produce a file")
            continue
        }
        try FileManager.default.moveItem(at: location, to: partial)
        try FileManager.default.moveItem(at: partial, to: destination)
        return
    }

    throw lastError ?? VMToolError.virtualization("Download failed after \(attempts) attempts")
}
#endif

// MARK: - GUI Runner

/// Hosts the running VM in an AppKit window, owns the run lock for the session,
/// and coordinates graceful shutdown (window close / signal → guest stop request
/// → forced stop) before terminating the process.
///
/// Main-actor isolated: it is the `NSApplicationDelegate`, drives the AppKit run
/// loop, and the VM is created on (and only used from) the main queue, so its
/// `VZVirtualMachineDelegate` callbacks also arrive on the main thread.
@MainActor
final class RunApp: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate {
    private let paths: VMPaths
    private let vmConfiguration: VZVirtualMachineConfiguration
    private let title: String
    private var virtualMachine: VZVirtualMachine?
    private var window: NSWindow?
    private var termSource: DispatchSourceSignal?
    private var intSource: DispatchSourceSignal?
    private var stopRequested = false
    private let runLock: RunLock

    init(paths: VMPaths, vmConfiguration: VZVirtualMachineConfiguration, title: String, runLock: RunLock) {
        self.paths = paths
        self.vmConfiguration = vmConfiguration
        self.title = title
        self.runLock = runLock
    }

    /// Configures and runs the AppKit application (blocks until termination).
    /// Invoked once from the `run` command on the main thread.
    func start() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = self
        app.run()
    }

    /// Builds the VM view/window, installs signal handlers, and starts the VM.
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

    /// Intercepts app termination to request a graceful guest shutdown first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestStop()
        return .terminateLater
    }

    /// Window close requests a guest shutdown; a second close forces it.
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

    /// Guest stopped cleanly — tear down and exit.
    /// `VZVirtualMachineDelegate` is non-isolated; this fires on the VM's main
    /// delegate queue, so hop onto the main actor to run the teardown.
    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { cleanupAndTerminate() }
    }

    /// Guest stopped with an error — report it, then tear down and exit.
    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("VM stopped with error: \(error.localizedDescription)\n".utf8))
        MainActor.assumeIsolated { cleanupAndTerminate() }
    }

    /// Routes SIGTERM/SIGINT into a graceful stop on the main queue.
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

    /// Asks the guest to shut down gracefully, falling back to a force stop.
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

    /// Forcibly stops the VM if it is still running, then tears down.
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

    /// Releases the run lock, removes the pidfile, and terminates the process.
    private func cleanupAndTerminate() {
        runLock.release()
        try? FileManager.default.removeItem(at: paths.runPIDURL)
        NSApplication.shared.reply(toApplicationShouldTerminate: true)
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Process Helpers

/// An exclusive advisory lock (`flock`) on a VM bundle's pidfile, held by the
/// `run` command for the lifetime of the process. Because the lock is tied to a
/// specific bundle file and is released automatically by the kernel when the
/// owning process exits — even on crash — liveness is determined by lock
/// ownership rather than the recorded PID. That makes it immune to PID reuse
/// (where a stale PID could match an unrelated `vmctl` running a different VM)
/// and to stale pidfiles left behind by a crash.
final class RunLock {
    private var fd: Int32

    private init(fd: Int32) {
        self.fd = fd
    }

    deinit {
        release()
    }

    /// Acquires the lock for `pidURL`, recording the current PID, or returns nil
    /// if another live process already holds it (the VM is already running).
    static func acquire(at pidURL: URL) -> RunLock? {
        let fd = open(pidURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        ftruncate(fd, 0)
        Array("\(getpid())\n".utf8).withUnsafeBytes { _ = pwrite(fd, $0.baseAddress, $0.count, 0) }
        return RunLock(fd: fd)
    }

    /// Releases the lock. Idempotent — safe to call more than once. The kernel
    /// also releases it automatically on process exit.
    func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }
}

/// Reports whether a `run` process currently holds the lock for `pidURL`.
/// If no one holds it, a leftover pidfile is treated as stale and removed.
func isVMRunning(pidURL: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: pidURL.path) else { return false }
    let fd = open(pidURL.path, O_RDWR)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
        // Nobody held the lock — the pidfile is stale.
        flock(fd, LOCK_UN)
        try? FileManager.default.removeItem(at: pidURL)
        return false
    }
    return true
}

/// Reads the PID recorded in the pidfile. Only meaningful while the VM is
/// running (the lock holder wrote and still owns it), so callers must gate this
/// behind `isVMRunning`.
func recordedPID(at pidURL: URL) -> Int32? {
    guard let text = try? String(contentsOf: pidURL, encoding: .utf8) else { return nil }
    return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: - Snapshot Helpers

/// Copies the bundle's disk and platform metadata into `snapshotURL`, replacing
/// any existing snapshot at that label. Refuses while the VM is running.
func saveSnapshot(paths: VMPaths, snapshotURL: URL) throws {
    if isVMRunning(pidURL: paths.runPIDURL) {
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

/// Restores the bundle's disk and platform metadata from `snapshotURL`,
/// overwriting current state. Refuses while the VM is running.
func restoreSnapshot(paths: VMPaths, snapshotURL: URL) throws {
    guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
        throw VMToolError.notFound("Snapshot not found: \(snapshotURL.path)")
    }
    if isVMRunning(pidURL: paths.runPIDURL) {
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

/// The set of bundle files captured by save/restore.
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

/// Creates a sparse raw disk image of `sizeBytes` at `url`.
func createRawDisk(at url: URL, sizeBytes: UInt64) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: sizeBytes)
}

/// Decodes a VM's `config.json`.
func loadConfig(from url: URL) throws -> VMConfig {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw VMToolError.notFound("VM config not found: \(url.path)")
    }
    return try JSONDecoder().decode(VMConfig.self, from: Data(contentsOf: url))
}

/// Writes a VM's `config.json` atomically.
func saveConfig(_ config: VMConfig, to url: URL) throws {
    try JSONEncoder.pretty.encode(config).write(to: url, options: [.atomic])
}

/// Validates a VM name (letters, digits, dash, underscore, dot) to keep it a
/// safe single path component, returning it unchanged on success.
func validateName(_ name: String) throws -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard !name.isEmpty, name.rangeOfCharacter(from: allowed.inverted) == nil else {
        throw VMToolError.usage("Name may contain only letters, digits, dash, underscore, and dot")
    }
    return name
}

/// Whether `url` refers to an existing directory.
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
    /// A JSON encoder with stable, human-readable output for config files.
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
