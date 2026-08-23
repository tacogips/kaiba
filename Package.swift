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
    .executable(name: "kaiba", targets: ["AppCLI"]),
    .executable(name: "KaibaApp", targets: ["KaibaApp"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/tacogips/anydoc-swift.git",
      revision: "d957c08372786b7062553e83fe9c29880fdee7a4"
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
    .executableTarget(
      name: "KaibaApp",
      dependencies: ["AppCore", "AppServer"]
    ),
    .testTarget(
      name: "AppCoreTests",
      dependencies: ["AppCore"],
      resources: [.copy("Fixtures")]
    ),
    .testTarget(
      name: "AppGraphQLTests",
      dependencies: ["AppGraphQL", "AppCore"]
    ),
    .testTarget(
      name: "AppServerTests",
      dependencies: ["AppServer", "AppGraphQL", "AppCore"]
    )
  ],
  swiftLanguageModes: [.v6]
)
