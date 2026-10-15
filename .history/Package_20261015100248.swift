// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "midiq-bcdriver",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "bcprobe",
            path: "Sources/bcprobe",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ]
)
