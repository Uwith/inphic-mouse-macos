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
    targets: [
        .target(name: "HIDProbeCore"),
        .executableTarget(name: "hid-probe", dependencies: ["HIDProbeCore"]),
        .executableTarget(name: "ProbeSelfTest", dependencies: ["HIDProbeCore"]),
    ]
)
