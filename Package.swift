// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TypeDBSwift",
    platforms: [
        .macOS(.v13)
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
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", "Sources/CTypeDBDriver/lib"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
                // Add project-relative rpath for development
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "Sources/CTypeDBDriver/lib"]),
            ]
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
