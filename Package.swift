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
        .executableTarget(name: "Tendedero", dependencies: ["NotesCore"], path: "Sources/Tendedero"),
        // The notebook's pages on disk, Markdown and git: everything that is not drawing.
        .target(name: "NotesCore", path: "Sources/NotesCore"),
        .testTarget(name: "NotesCoreTests", dependencies: ["NotesCore"], path: "Tests/NotesCoreTests"),
        .target(name: "TendederoSaver", path: "Sources/TendederoSaver"),
    ]
)
