// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "swift-markdown",
  platforms: [
    .iOS(.v17)
  ],
  products: [
    .library(
      name: "JerrickMarkdown",
      targets: ["JerrickMarkdown"]
    )
  ],
  dependencies: [
    .package(
      url: "https://github.com/gonzalezreal/swiftui-math",
      from: "0.1.0"
    )
  ],
  targets: [
    .target(
      name: "JerrickMarkdown",
      dependencies: [
        .product(name: "SwiftUIMath", package: "swiftui-math")
      ],
      path: "Sources/JerrickMarkdown",
      resources: [
        .process("Resources")
      ]
    )
  ],
  swiftLanguageModes: [.v5]
)
