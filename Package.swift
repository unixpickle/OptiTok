// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let soPlexPrefix = Context.environment["SOPLEX_PREFIX"] ?? "/opt/homebrew/opt/soplex"
let soPlexInclude = "\(soPlexPrefix)/include"
let soPlexLib = "\(soPlexPrefix)/lib"
let boostPrefix = Context.environment["BOOST_PREFIX"] ?? "/opt/homebrew/opt/boost"
let boostInclude = "\(boostPrefix)/include"
let gmpPrefix = Context.environment["GMP_PREFIX"] ?? "/opt/homebrew/opt/gmp"
let gmpInclude = "\(gmpPrefix)/include"
let gmpLib = "\(gmpPrefix)/lib"
let mpfrPrefix = Context.environment["MPFR_PREFIX"] ?? "/opt/homebrew/opt/mpfr"
let mpfrInclude = "\(mpfrPrefix)/include"
let mpfrLib = "\(mpfrPrefix)/lib"

let package = Package(
    name: "OptiTok",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "OptiTok",
            targets: ["OptiTok", "SoPlex"]),
        .library(
            name: "SoPlex",
            targets: ["SoPlex"]),
        .executable(
            name: "SolveLoop",
            targets: ["SolveLoop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.1"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "CSoPlex",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags([
                    "-I\(soPlexInclude)",
                    "-I\(boostInclude)",
                    "-I\(gmpInclude)",
                    "-I\(mpfrInclude)",
                ])
            ],
            cxxSettings: [
                .unsafeFlags([
                    "-std=c++17",
                    "-I\(soPlexInclude)",
                    "-I\(boostInclude)",
                    "-I\(gmpInclude)",
                    "-I\(mpfrInclude)",
                ])
            ],
            linkerSettings: [
                .linkedLibrary("soplex"),
                .linkedLibrary("gmp"),
                .linkedLibrary("mpfr"),
                .linkedLibrary("z"),
                .unsafeFlags([
                    "-L\(soPlexLib)", "-L\(gmpLib)", "-L\(mpfrLib)",
                    "-Xlinker", "-rpath", "-Xlinker", soPlexLib,
                    "-Xlinker", "-rpath", "-Xlinker", gmpLib,
                    "-Xlinker", "-rpath", "-Xlinker", mpfrLib,
                ])
            ]),
        .target(
            name: "SoPlex",
            dependencies: ["CSoPlex"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(soPlexInclude)"])
            ]),
        .target(
            name: "OptiTok",
            dependencies: ["SoPlex"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(soPlexInclude)"])
            ]),
        .executableTarget(
            name: "SolveLoop",
            dependencies: [
                "OptiTok",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(soPlexInclude)"])
            ]),
        .executableTarget(
            name: "InspectCuts",
            dependencies: [
                "OptiTok",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(soPlexInclude)"])
            ]),
        .testTarget(
            name: "OptiTokTests",
            dependencies: ["OptiTok", "SoPlex"],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-I\(soPlexInclude)"])
            ]
        ),
    ]
)
