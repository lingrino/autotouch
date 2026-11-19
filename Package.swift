// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "autotouch",
    platforms: [.macOS("27.2")],   // same minimum as the maintainer's other Mac apps
    products: [
        .executable(name: "Autotouch", targets: ["Autotouch"]),
    ],
    targets: [
        // Pure logic: the swipe recognizer. No AppKit; unit-tested.
        .target(name: "AutotouchCore"),
        // The agent: MultitouchSupport bindings, actions, LaunchAgent registration.
        .executableTarget(
            name: "Autotouch",
            dependencies: ["AutotouchCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(name: "AutotouchCoreTests", dependencies: ["AutotouchCore"]),
    ]
)
