// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "QuietCast",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "PodcastCore", targets: ["PodcastCore"]), .library(name: "ContentFiltering", targets: ["ContentFiltering"]), .executable(name: "quietcast-tools", targets: ["QuietCastTools"])],
    targets: [
        .target(name: "PodcastModels"),
        .target(name: "ContentFiltering", dependencies: ["PodcastModels"]),
        .target(name: "PodcastCore", dependencies: ["PodcastModels", "ContentFiltering"]),
        .executableTarget(name: "QuietCastTools", dependencies: ["PodcastCore"]),
        .testTarget(name: "PodcastCoreTests", dependencies: ["PodcastCore"], resources: [.copy("Fixtures")])
    ]
)
