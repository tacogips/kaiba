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
    .library(name: "KaibaClient", targets: ["KaibaClient"]),
    .executable(name: "kaiba", targets: ["AppCLI"]),
    .executable(name: "KaibaApp", targets: ["KaibaApp"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/tacogips/anydoc-swift.git",
      revision: "0aa4756d0ce3f97cc94f1de9efe26879808097c8"
    ),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3")
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
        .product(
          name: "AnydocKit",
          package: "anydoc-swift",
          condition: .when(platforms: [.macOS, .iOS])
        ),
        .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
      ]
    ),
    .target(name: "KaibaClient"),
    .target(name: "AppGraphQL", dependencies: ["AppCore", "KaibaClient"]),
    .target(name: "KaibaCLIKit", dependencies: ["KaibaClient"]),
    .target(name: "AppServer", dependencies: ["AppCore", "AppGraphQL"]),
    .executableTarget(
      name: "AppCLI",
      dependencies: ["AppCore", "AppGraphQL", "AppServer", "KaibaClient", "KaibaCLIKit"]
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
      dependencies: ["AppGraphQL", "AppCore", "KaibaClient"]
    ),
    .testTarget(
      name: "AppServerTests",
      dependencies: ["AppServer", "AppGraphQL", "AppCore", "KaibaClient"]
    ),
    .testTarget(name: "KaibaClientTests", dependencies: ["KaibaClient"]),
    .testTarget(name: "KaibaCLIKitTests", dependencies: ["KaibaCLIKit", "KaibaClient"])
  ],
  swiftLanguageModes: [.v6]
)
