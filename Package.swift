// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenComputerUse",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "OCUCore",
            targets: ["OCUCore"]
        ),
        .executable(
            name: "ocu",
            targets: ["ocu"]
        ),
        .executable(
            name: "OpenComputerUseApp",
            targets: ["OpenComputerUseApp"]
        )
    ],
    targets: [
        .target(
            name: "OCUCore",
            path: "Sources/OCUCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Vision"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon")
            ]
        ),
        .executableTarget(
            name: "ocu",
            dependencies: ["OCUCore"],
            path: "Sources/ocu"
        ),
        .executableTarget(
            name: "OpenComputerUseApp",
            dependencies: ["OCUCore"],
            path: "Sources/OpenComputerUseApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "OCUCoreTests",
            dependencies: ["OCUCore"],
            path: "Tests/OCUCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
