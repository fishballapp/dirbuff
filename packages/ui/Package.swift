// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "DirBuffUI",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(
      name: "DirBuffUI",
      targets: ["DirBuffUI"]
    ),
    .executable(
      name: "render-previews",
      targets: ["render-previews"]
    ),
  ],
  dependencies: [
    .package(path: "../core"),
    .package(path: "../kit"),
  ],
  targets: [
    .target(
      name: "DirBuffUI",
      dependencies: [
        .product(name: "DirBuffCore", package: "core"),
        .product(name: "DirBuffKit", package: "kit"),
      ],
      resources: [.copy("Resources/Fonts")]
    ),
    .executableTarget(
      name: "render-previews",
      dependencies: [
        "DirBuffUI",
        .product(name: "DirBuffCore", package: "core"),
        .product(name: "DirBuffKit", package: "kit"),
      ]
    ),
    .testTarget(
      name: "DirBuffUITests",
      dependencies: [
        "DirBuffUI",
        .product(name: "DirBuffCore", package: "core"),
        .product(name: "DirBuffKit", package: "kit"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
