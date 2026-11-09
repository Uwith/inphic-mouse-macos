// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macro-tool",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macro-tool", targets: ["macro-tool"]),
    ],
    dependencies: [
        .package(name: "InphicMouse", path: "../.."),
        .package(name: "hid-probe", path: "../hid-probe"),
    ],
    targets: [
        .executableTarget(name: "macro-tool", dependencies: [
            .product(name: "InphicMouseProtocol", package: "InphicMouse"),
            .product(name: "HIDProbeCore", package: "hid-probe"),
        ]),
    ]
)
