// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftmailCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SwiftmailCore", targets: ["SwiftmailCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "SwiftmailCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            path: "Sources",
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]
        ),
        .testTarget(
            name: "SwiftmailCoreTests",
            dependencies: ["SwiftmailCore"],
            path: "Tests/SwiftmailCoreTests"
        ),
    ]
)
