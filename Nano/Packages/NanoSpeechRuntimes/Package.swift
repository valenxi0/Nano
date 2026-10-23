// swift-tools-version: 6.0
//
// Thin Swift wrappers over the vendored whisper.cpp and llama.cpp frameworks.
//
// Each runtime lives in its own module on purpose: both frameworks ship a
// private copy of ggml, and the two ggml headers differ, so Clang refuses to
// import `whisper` and `llama` into the same Swift module. Keeping them apart
// (and importing them with `internal import`) means the app only ever sees
// Swift types.
import PackageDescription

let package = Package(
    name: "NanoSpeechRuntimes",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "WhisperRuntime", targets: ["WhisperRuntime"]),
        .library(name: "LlamaRuntime", targets: ["LlamaRuntime"]),
    ],
    targets: [
        .binaryTarget(name: "whisper", path: "Binaries/whisper.xcframework"),
        .binaryTarget(name: "llama", path: "Binaries/llama.xcframework"),
        .target(
            name: "WhisperRuntime",
            dependencies: ["whisper"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "LlamaRuntime",
            dependencies: ["llama"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
