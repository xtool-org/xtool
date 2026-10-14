// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DemoWatch",
    platforms: [.watchOS(.v10)],
    products: [.library(name: "DemoWatch", targets: ["DemoWatch"])],
    targets: [.target(name: "DemoWatch")]
)
