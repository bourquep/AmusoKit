// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "AmusoKit",
  platforms: [
    .iOS(.v18),
    .macOS(.v15)
  ],
  products: [
    .library(name: "AmusoKit", targets: ["AmusoKit"])
  ],
  targets: [
    .target(
      name: "AmusoKit",
      swiftSettings: [
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("MemberImportVisibility")
      ]
    ),
    .testTarget(
      name: "AmusoKitTests",
      dependencies: ["AmusoKit"],
      resources: [.copy("Fixtures")],
      swiftSettings: [
        .defaultIsolation(MainActor.self),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("MemberImportVisibility")
      ]
    )
  ],
  swiftLanguageModes: [.v6]
)
