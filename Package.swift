// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iTrans",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "iTrans", targets: ["iTrans"])
    ],
    targets: [
        .executableTarget(
            name: "iTrans",
            path: "Sources/iTrans",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("ApplicationServices")
            ]
        )
    ]
)
