// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "yap",
    platforms: [.macOS(.v13)], // Changed from "26" to macOS 13.0
    products: [
        .executable(name: "yap", targets: ["yap"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
        .package(url: "https://github.com/tuist/Noora.git", from: "0.40.1")
    ],
    targets: [
        .executableTarget(
            name: "yap",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Noora", package: "Noora")
            ]
        )
    ]
)
