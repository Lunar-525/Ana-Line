// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AnaLine", defaultLocalization: "zh-Hans", platforms: [.macOS(.v13)], products: [
    .library(name: "AnalogCore", targets: ["AnalogCore"]),
    .executable(name: "analog", targets: ["analog"]),
    .executable(name: "AnaLine", targets: ["AnalogGUI"])
], targets: [.target(name: "CTapeDSP", publicHeadersPath: "include"), .target(name: "AnalogCore", dependencies: ["CTapeDSP"], resources: [.process("Resources")]), .target(name: "AnalogImaging", dependencies: ["AnalogCore"]), .executableTarget(name: "analog", dependencies: ["AnalogCore"]), .target(name: "CAtomicRing"), .executableTarget(name: "AnalogGUI", dependencies: ["AnalogCore", "AnalogImaging", "CAtomicRing"], resources: [.process("Resources")], swiftSettings: [.unsafeFlags(["-parse-as-library"])]), .testTarget(name: "AnalogCoreTests", dependencies: ["AnalogCore", "AnalogImaging"]), .testTarget(name: "AnalogGUITests", dependencies: ["AnalogGUI", "AnalogImaging", "AnalogCore"])], cxxLanguageStandard: .cxx17)
