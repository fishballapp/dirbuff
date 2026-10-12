// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "DirBuffKit",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "DirBuffKit",
      targets: ["DirBuffKit"]
    )
  ],
  dependencies: [
    .package(path: "../core"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
  ],
  targets: [
    .target(
      name: "DirBuffKit",
      dependencies: [
        .product(name: "DirBuffCore", package: "core"),
        .product(name: "GRDB", package: "GRDB.swift"),
      ]
    ),
    .testTarget(
      name: "DirBuffKitTests",
      dependencies: ["DirBuffKit", .product(name: "DirBuffCore", package: "core")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
