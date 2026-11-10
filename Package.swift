// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "LidGlow",
  platforms: [.macOS("15.0")],
  products: [
    .executable(name: "LidGlow", targets: ["LidGlow"]),
    .executable(name: "LidGlowSignal", targets: ["LidGlowSignal"]),
  ],
  targets: [
    .target(name: "LidGlowCore"),
    .target(name: "LidGlowUI", dependencies: ["LidGlowCore"]),
    .executableTarget(name: "LidGlow", dependencies: ["LidGlowUI"]),
    .executableTarget(name: "LidGlowAppChecks", dependencies: ["LidGlowUI", "LidGlowCore"]),
    .executableTarget(name: "LidGlowSignal"),
    .executableTarget(
      name: "LidGlowChecks", dependencies: ["LidGlowCore"], path: "Tests/LidGlowCoreTests"),
  ],
  swiftLanguageVersions: [.v5]
)
