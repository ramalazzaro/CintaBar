// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CintaBar",
    platforms: [.macOS(.v14)],
    targets: [
        // Wire protocols only: no Bluetooth and no UI, so everything in it can be unit tested.
        .target(name: "TreadmillKit"),
        .executableTarget(
            name: "CintaBar",
            dependencies: ["TreadmillKit"],
            // The app is UI plus Core Bluetooth callbacks delivered on the main queue.
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "TreadmillKitTests", dependencies: ["TreadmillKit"]),
    ],
    swiftLanguageModes: [.v6]
)
