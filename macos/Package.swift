// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentSandboxVM",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "vmctl", targets: ["vmctl"])
    ],
    targets: [
        .executableTarget(
            name: "vmctl",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Virtualization")
            ]
        )
    ]
)
