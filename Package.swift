// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TypeDBSwift",
    platforms: [
        // The bundled TypeDB 3.11.5 C driver dylib is built for a macOS 15.5+
        // runtime, so that is the effective minimum for this package. (String
        // form because `.v15` requires swift-tools-version 6.0.)
        .macOS("15.5")
    ],
    products: [
        .library(
            name: "TypeDBSwift",
            targets: ["TypeDBSwift"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.36.0")
    ],
    targets: [
        // C library target providing the TypeDB driver C API
        .target(
            name: "CTypeDBDriver",
            path: "Sources/CTypeDBDriver",
            publicHeadersPath: "include"
        ),

        // Swift wrapper library
        .target(
            name: "TypeDBSwift",
            dependencies: [
                "CTypeDBDriver",
                .product(name: "SwiftProtobuf", package: "swift-protobuf")
            ],
            path: "Sources/TypeDBSwift"
        ),

        // Tests
        .testTarget(
            name: "TypeDBSwiftTests",
            dependencies: ["TypeDBSwift"],
            path: "Tests/TypeDBSwiftTests"
        ),
    ]
)
