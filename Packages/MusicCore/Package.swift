// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MusicCore", platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "MusicCore", targets: ["MusicCore"]), .executable(name: "MusicProbe", targets: ["MusicProbe"])],
    targets: [.target(name: "MusicCore"), .executableTarget(name: "MusicProbe", dependencies: ["MusicCore"]), .testTarget(name: "MusicCoreTests", dependencies: ["MusicCore"])],
    swiftLanguageModes: [.v5]
)
