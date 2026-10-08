// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tendedero",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tendedero", targets: ["Tendedero"]),
        // Packaged as Tendedero.saver by scripts/build-saver.sh.
        .library(name: "TendederoSaver", type: .dynamic, targets: ["TendederoSaver"]),
    ],
    targets: [
        .executableTarget(name: "Tendedero", path: "Sources/Tendedero"),
        .target(name: "TendederoSaver", path: "Sources/TendederoSaver"),
    ]
)
