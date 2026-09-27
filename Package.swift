// swift-tools-version: 6.0
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
            exclude: ["UI/Components", "UI/MenuBarView.swift", "UI/PopoverView.swift", "UI/Theme.swift"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "ControlLiteTests",
            dependencies: ["ControlLite"],
            path: "Tests/ControlLiteTests"
        )
    ]
)
