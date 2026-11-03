// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CashFlow",
    platforms: [
        .iOS("26.0"),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "CashFlow",
            targets: ["CashFlow"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // Lógica y persistencia. Sin SwiftUI, para poder correr tests en Linux.
        .target(
            name: "CashFlowCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        // La app SwiftUI.
        .target(
            name: "CashFlow",
            dependencies: ["CashFlowCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-headerpad_max_install_names"])]
        ),
        .testTarget(
            name: "CashFlowCoreTests",
            dependencies: ["CashFlowCore"]
        ),
    ]
)
