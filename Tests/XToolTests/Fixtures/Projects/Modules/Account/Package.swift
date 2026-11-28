// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Account",
    products: [.library(name: "Account", type: .dynamic, targets: ["Account"])],
    targets: [.target(name: "Account")]
)
