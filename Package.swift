// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "MSMServer",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "App", targets: ["App"]),
    .executable(name: "Run", targets: ["Run"])
  ],
  dependencies: [
    // Vapor core
    .package(url: "https://github.com/vapor/vapor.git", from: "4.116.0"),
    // Fluent ORM
    .package(url: "https://github.com/vapor/fluent.git", from: "4.13.0"),
    // Postgres driver
    .package(url: "https://github.com/vapor/fluent-postgres-driver.git", from: "2.9.0"),
    // HMAC-SHA256 for Stripe webhook signature verification (cross-platform)
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    // RS256 JWT signing for FCM HTTP v1 access-token exchange
    .package(url: "https://github.com/vapor/jwt-kit.git", from: "5.0.0"),
  ],
  targets: [
    .target(
      name: "App",
      dependencies: [
        .product(name: "Vapor", package: "vapor"),
        .product(name: "Fluent", package: "fluent"),
        .product(name: "FluentPostgresDriver", package: "fluent-postgres-driver"),
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "JWTKit", package: "jwt-kit"),
      ],
      path: "Sources/App"
    ),
    .executableTarget(
      name: "Run",
      dependencies: ["App"],
      path: "Sources/Run"
    ),
    // ✅ Add this test target
    .testTarget(
      name: "MSMServerTests",
      dependencies: [
        "App",
        .product(name: "XCTVapor", package: "vapor")
      ],
      path: "Tests"
    )
  ]
)
