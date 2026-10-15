// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "IPSWMirror",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IPSWMirrorCore", targets: ["IPSWMirrorCore"]),
        .executable(name: "ipsw-mirror", targets: ["ipsw-mirror"]),
    ],
    targets: [
        .target(name: "IPSWMirrorCore"),
        .executableTarget(name: "ipsw-mirror", dependencies: ["IPSWMirrorCore"]),
        .testTarget(
            name: "IPSWMirrorCoreTests",
            dependencies: ["IPSWMirrorCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
