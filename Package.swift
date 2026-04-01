// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PCMContainer",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "PCMContainer",
            targets: ["PCMContainer"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Vaida12345/MultiArray.git", from: "1.0.29"),
        .package(url: "https://github.com/Vaida12345/FinderItem.git", from: "1.3.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "PCMContainer",
            dependencies: ["MultiArray", "FinderItem"]
        ),
        .testTarget(
            name: "PCMContainerTests",
            dependencies: ["PCMContainer"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
