// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ComputerUseX",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "OCUCore",
            targets: ["OCUCore"]
        ),
        .executable(
            name: "cux",
            targets: ["cux"]
        ),
        .executable(
            name: "ComputerUseXApp",
            targets: ["ComputerUseXApp"]
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
            name: "cux",
            dependencies: ["OCUCore"],
            path: "Sources/cux"
        ),
        .executableTarget(
            name: "ComputerUseXApp",
            dependencies: ["OCUCore"],
            path: "Sources/ComputerUseXApp",
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
