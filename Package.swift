// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CereaChat",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "CereaChat", targets: ["CereaChat"]),
    ],
    targets: [
        .target(name: "CereaChat", path: "Sources/CereaChat"),
    ]
)
