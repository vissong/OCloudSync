// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "OCloudSync", platforms: [.macOS(.v13)],
  products: [.executable(name: "OCloudSync", targets: ["OCloudSync"]),
    .executable(name: "OCloudLivePhoto", targets: ["LivePhotoWorker"])],
  targets: [
    .target(name: "SyncCore"),
    .executableTarget(name: "LivePhotoWorker", dependencies: ["SyncCore"]),
    .executableTarget(
      name: "OCloudSync", dependencies: ["SyncCore"], resources: [.copy("Resources/bridge.js"), .copy("Resources/session.js")]),
    .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"]),
  ])
