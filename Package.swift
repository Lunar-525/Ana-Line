// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AnaLine", defaultLocalization: "zh-Hans", platforms: [.macOS(.v13)], products: [
    .library(name: "AnalogCore", targets: ["AnalogCore"]),
    .executable(name: "analog", targets: ["analog"]),
    .executable(name: "AnaLine", targets: ["AnalogGUI"])
], targets: [.target(name: "AnalogCore"), .target(name: "AnalogImaging", dependencies: ["AnalogCore"]), .executableTarget(name: "analog", dependencies: ["AnalogCore"]), .executableTarget(name: "AnalogGUI", dependencies: ["AnalogCore", "AnalogImaging"], resources: [.process("Resources")]), .testTarget(name: "AnalogCoreTests", dependencies: ["AnalogCore", "AnalogImaging"]), .testTarget(name: "AnalogGUITests", dependencies: ["AnalogGUI", "AnalogImaging", "AnalogCore"])])
