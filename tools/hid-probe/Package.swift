// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hid-probe",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "hid-probe", targets: ["hid-probe"]),
        .executable(name: "probe-selftest", targets: ["ProbeSelfTest"]),
        .library(name: "HIDProbeCore", targets: ["HIDProbeCore"]),
    ],
    dependencies: [
        .package(name: "InphicMouse", path: "../.."),
    ],
    targets: [
        .target(name: "HIDProbeCore", dependencies: [
            .product(name: "InphicMouseProtocol", package: "InphicMouse"),
        ]),
        .executableTarget(name: "hid-probe", dependencies: [
            "HIDProbeCore",
            .product(name: "InphicMouseProtocol", package: "InphicMouse"),
        ]),
        .executableTarget(name: "ProbeSelfTest", dependencies: [
            "HIDProbeCore",
            .product(name: "InphicMouseProtocol", package: "InphicMouse"),
        ]),
    ]
)
