// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CashFlow",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // An xtool project should contain exactly one library product,
        // representing the main app.
        .library(
            name: "CashFlow",
            targets: ["CashFlow"]
        ),
        // Extensión de widget (ver xtool.yml).
        .library(
            name: "CashFlowWidget",
            targets: ["CashFlowWidget"]
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
        // Widget: solo lee un JSON que la app deja en el App Group.
        .target(
            name: "CashFlowWidget",
            // xtool enlaza la extensión con entrada _NSExtensionMain; sin esto el linker descarta el @main del WidgetBundle.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-u", "-Xlinker", "_main", "-Xlinker", "-headerpad_max_install_names"])]
        ),
        .testTarget(
            name: "CashFlowCoreTests",
            dependencies: ["CashFlowCore"]
        ),
        // Herramienta de línea de comandos para cargar datos en una copia de la base. Solo corre en Linux/macOS.
        .executableTarget(
            name: "CashFlowSeed",
            dependencies: ["CashFlowCore"],
            path: "Tools/Seed"
        ),
    ]
)
