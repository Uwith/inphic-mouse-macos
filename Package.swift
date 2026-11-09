// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "InphicMouse",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "InphicMouseProtocol", targets: ["InphicMouseProtocol"]),
        .executable(name: "protocol-selftest", targets: ["ProtocolSelfTest"]),
    ],
    targets: [
        .target(name: "InphicMouseProtocol"),
        .executableTarget(name: "ProtocolSelfTest", dependencies: ["InphicMouseProtocol"]),
    ]
)
