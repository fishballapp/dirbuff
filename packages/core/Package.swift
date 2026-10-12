// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "DirBuffCore",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "DirBuffCore", targets: ["DirBuffCore"])
  ],
  targets: [
    .target(name: "DirBuffCore"),
    .testTarget(name: "DirBuffCoreTests", dependencies: ["DirBuffCore"]),
  ],
  swiftLanguageModes: [.v6]
)
