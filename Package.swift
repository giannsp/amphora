// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Amphora",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AmphoraCore", targets: ["AmphoraCore"]),
        .executable(name: "amphora", targets: ["amphora"]),
    ],
    targets: [
        .target(name: "AmphoraCore"),
        .executableTarget(name: "amphora", dependencies: ["AmphoraCore"]),
        .testTarget(
            name: "AmphoraCoreTests",
            dependencies: ["AmphoraCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
