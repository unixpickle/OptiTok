// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let highsPrefix = Context.environment["HIGHS_PREFIX"] ?? "/opt/homebrew/opt/highs"
let highsInclude = "\(highsPrefix)/include"
let highsNestedInclude = "\(highsPrefix)/include/highs"
let highsLib = "\(highsPrefix)/lib"

let package = Package(
    name: "OptiTok",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "OptiTok",
            targets: ["OptiTok"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CHiGHS",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-I\(highsInclude)", "-I\(highsNestedInclude)"])
            ],
            cxxSettings: [
                .unsafeFlags(["-std=c++17"])
            ],
            linkerSettings: [
                .linkedLibrary("highs"),
                .unsafeFlags(["-L\(highsLib)", "-Xlinker", "-rpath", "-Xlinker", highsLib])
            ]),
        .target(
            name: "OptiTok",
            dependencies: ["CHiGHS"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(highsInclude)", "-Xcc", "-I\(highsNestedInclude)"])
            ]),
        .testTarget(
            name: "OptiTokTests",
            dependencies: ["OptiTok"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(highsInclude)", "-Xcc", "-I\(highsNestedInclude)"])
            ]
        ),
    ]
)
