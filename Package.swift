// swift-tools-version: 6.0
import PackageDescription

// Fork addition: builds the Hex app as a plain SPM executable so it can be built
// and run with Command Line Tools alone, no Xcode required.
//
// This sits ALONGSIDE Hex.xcodeproj rather than replacing it — the same sources
// build both ways. Keeping the xcodeproj intact is what keeps `git pull upstream`
// cheap, and it stays the path for producing a signed, sandboxed release build.
//
// Differences in the SPM executable vs the Xcode app bundle:
//   - No Info.plist, so no usage-description strings on TCC prompts, and the dock
//     icon must be suppressed programmatically rather than via LSUIElement.
//   - No asset catalog. The only lookup, NSImage(named: "HexIcon") in HexApp.swift,
//     already falls back to an SF Symbol.
//   - Not sandboxed. FluidAudio models therefore cache to the normal
//     ~/Library/Application Support/FluidAudio/Models rather than a container —
//     which is where dictate-wrapper already put them.
//   - No Sparkle. It needs a bundle for its XPC installer, and this fork disables
//     auto-update anyway; SparkleShim stands in for the three call sites.
let package = Package(
    name: "Hex",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HexApp", targets: ["HexApp"]),
    ],
    dependencies: [
        .package(path: "HexCore"),
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.26.0"),
        .package(url: "https://github.com/Clipy/Sauce", branch: "master"),
        .package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.14.1"),
        .package(url: "https://github.com/pointfreeco/swift-sharing", from: "2.9.1"),
        .package(url: "https://github.com/pointfreeco/swift-case-paths", from: "1.8.0"),
        .package(url: "https://github.com/pointfreeco/swift-identified-collections", from: "1.1.1"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        .package(url: "https://github.com/krzysztofzablocki/Inject", from: "1.6.0"),
        .package(url: "https://github.com/EmergeTools/Pow", revision: "1b4b1dda28c50b95f0872927ee2226fe8b58950e"),
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.5"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", exact: "0.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "HexApp",
            dependencies: [
                .product(name: "HexCore", package: "HexCore"),
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
                .product(name: "Sauce", package: "Sauce"),
                .product(name: "Dependencies", package: "swift-dependencies"),
                .product(name: "DependenciesMacros", package: "swift-dependencies"),
                .product(name: "Sharing", package: "swift-sharing"),
                .product(name: "CasePaths", package: "swift-case-paths"),
                .product(name: "IdentifiedCollections", package: "swift-identified-collections"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "Inject", package: "Inject"),
                .product(name: "Pow", package: "Pow"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Hex",
            exclude: [
                "Info.plist",
                "Hex.entitlements",
                "Assets.xcassets",
                "AppIcon.icon",
                "Preview Content",
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                // Marks this as the SPM executable build. Used to skip #Preview
                // blocks, which need Xcode's PreviewsMacros plugin. The Xcode
                // build never sets it, so previews still work there.
                .define("SPM_BUILD"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
