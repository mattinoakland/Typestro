// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Typestro",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Typestro", targets: ["Typestro"]),
    ],
    targets: [
        // Pure logic: text handling, prompts, the Claude client. No UI, so it can be tested.
        .target(name: "TypestroCore"),
        // The menu-bar app: watches keys, reads and edits the focused text field, draws overlays.
        .executableTarget(name: "Typestro", dependencies: ["TypestroCore"]),
        // Command-line check of the prompts against sample sentences.
        .executableTarget(name: "typestro-probe", dependencies: ["TypestroCore"], path: "Sources/TypestroProbe"),
        .testTarget(name: "TypestroCoreTests", dependencies: ["TypestroCore"]),
    ]
)
