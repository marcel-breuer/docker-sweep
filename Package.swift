// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "DockerSweep",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "DockerSweepCore", targets: ["DockerSweepCore"]),
    .executable(name: "DockerSweep", targets: ["DockerSweep"]),
  ],
  targets: [
    .target(
      name: "DockerSweepCore",
      swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
    .executableTarget(
      name: "DockerSweep",
      dependencies: ["DockerSweepCore"],
      swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
    .testTarget(
      name: "DockerSweepCoreTests",
      dependencies: ["DockerSweepCore"],
      swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
    ),
  ]
)
