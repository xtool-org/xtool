// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WatchProbe",
    platforms: [.watchOS(.v10)],
    products: [.library(name: "WatchProbe", targets: ["WatchProbe"])],
    targets: [.target(name: "WatchProbe")]
)
