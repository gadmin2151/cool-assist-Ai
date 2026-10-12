// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MeetSecretar",
  platforms: [.macOS(.v15)],
  products: [.executable(name: "MeetSecretar", targets: ["MeetSecretar"])],
  targets: [
    .target(name: "MeetingCore"),
    .executableTarget(name: "MeetSecretar", dependencies: ["MeetingCore"]),
    .executableTarget(
      name: "MeetingCoreChecks", dependencies: ["MeetingCore"], path: "Tests/MeetingCoreTests"),
  ],
  swiftLanguageModes: [.v5]
)
