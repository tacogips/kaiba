// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "kaiba",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "AppCore", targets: ["AppCore"]),
    .library(name: "AppGraphQL", targets: ["AppGraphQL"]),
    .executable(name: "kaiba", targets: ["AppCLI"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/tacogips/anydoc-swift.git",
      revision: "9ee68e37c9520558c166fb8832965b480ffe41f7"
    )
  ],
  targets: [
    .systemLibrary(
      name: "CKaibaSQLite3",
      providers: [
        .apt(["libsqlite3-dev"]),
        .brew(["sqlite"])
      ]
    ),
    .target(
      name: "AppCore",
      dependencies: [
        "CKaibaSQLite3",
        .product(name: "AnydocKit", package: "anydoc-swift")
      ]
    ),
    .target(name: "AppGraphQL", dependencies: ["AppCore"]),
    .target(name: "AppServer", dependencies: ["AppCore", "AppGraphQL"]),
    .executableTarget(
      name: "AppCLI",
      dependencies: ["AppCore", "AppGraphQL", "AppServer"]
    ),
    .testTarget(
      name: "AppCoreTests",
      dependencies: ["AppCore"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "AppGraphQLTests",
      dependencies: ["AppGraphQL", "AppCore"]
    )
  ],
  swiftLanguageModes: [.v6]
)
