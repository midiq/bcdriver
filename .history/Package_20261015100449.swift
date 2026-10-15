// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "midiq-bcdriver",
    platforms: [.macOS(.v13)],
    targets: [
        // IOUSBLib UUID constants are function-like macros that Swift cannot import.
        .target(
            name: "CIOUSBShim",
            path: "Sources/CIOUSBShim"
        ),
        .executableTarget(
            name: "bcprobe",
            dependencies: ["CIOUSBShim"],
            path: "Sources/bcprobe",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
