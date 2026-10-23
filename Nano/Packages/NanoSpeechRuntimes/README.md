# Vendored inference runtimes

Prebuilt binaries from the ggml project, used by Voice Dictation. Both are
dynamic frameworks (two-level namespace), so their private copies of `ggml`
do not collide. Only the `macos-arm64_x86_64` slice is kept; the upstream
zips also ship iOS, tvOS and visionOS slices that Nano does not build for.

| Framework | Upstream release | Asset | SHA-256 of the downloaded zip |
| --- | --- | --- | --- |
| `whisper.xcframework` | [whisper.cpp v1.9.2](https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.2) | `whisper-v1.9.2-xcframework.zip` | `af74fed13ea7f2d5ca2a39d9f58ec177713fafd7cab63aef4e27b79f3ceca80b` |
| `llama.xcframework` | [llama.cpp b10775](https://github.com/ggml-org/llama.cpp/releases/tag/b10775) | `llama-b10775-xcframework.zip` | `20101212902cbaa01830986d97ce3002087ea2878ed19c13141deb872187c653` |

Both projects are MIT licensed; their license texts, which must ship with any
copy of these binaries, are in [`Licenses/`](Licenses). Metal is enabled in
these builds.

To update: download the new asset, verify its hash against the release page,
unzip, keep `macos-arm64_x86_64` only, rewrite `Info.plist` so
`AvailableLibraries` lists just that slice, update this table, and refresh the
matching file in `Licenses/` from the same tag.

Parakeet runs through the FluidAudio Swift package (Apache 2.0), pinned in
`project.pbxproj`; it is not vendored here.
