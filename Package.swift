// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ControlLite",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ControlLite",
            targets: ["ControlLite"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ControlLite",
            path: "Sources/ControlLite",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "ControlLiteTests",
            dependencies: ["ControlLite"],
            path: "Tests/ControlLiteTests"
        )
    ]
)
