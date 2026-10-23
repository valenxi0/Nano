// swift-tools-version: 6.0
//
// Vendored copy of FluidAudio 0.15.6 (Apache 2.0), used for Parakeet speech
// recognition in Voice Dictation. See README.md next to this file for the
// upstream revision, what was removed, and how to update.
import Foundation
import PackageDescription

let package = Package(
    name: "FluidAudio",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "FluidAudio",
            targets: ["FluidAudio"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "FluidAudio",
            dependencies: [
                "FastClusterWrapper",
                "MachTaskSelfWrapper",
                "NemoTextProcessing",
            ],
            path: "Sources/FluidAudio",
            exclude: ["ASR/Parakeet/Unified/benchmark.md"],
            resources: [
                .process("TTS/LuxTts/G2p/Resources")
            ]
        ),
        // Upstream fetches this from text-processing-rs v0.3.0; it is checked
        // in here (macOS slice only) so a build needs no network access.
        .binaryTarget(
            name: "NemoTextProcessing",
            path: "Binaries/NemoTextProcessing.xcframework"
        ),
        .target(
            name: "FastClusterWrapper",
            path: "Sources/FastClusterWrapper",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MachTaskSelfWrapper",
            path: "Sources/MachTaskSelfWrapper",
            publicHeadersPath: "include"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
