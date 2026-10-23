# FluidAudio (vendored)

Upstream: https://github.com/FluidInference/FluidAudio
Version: **0.15.6**, tag commit `4dbf4f9f9a5ff3a53ade848d7ba4e3df13db859b`
License: Apache 2.0 (`LICENSE`, plus `ThirdPartyLicenses/`)

Nano uses the Parakeet TDT ASR path (`AsrModels`, `AsrManager`), the Cohere
Transcribe pipeline (`CoherePipeline`), CTC keyword spotting and vocabulary
rescoring (`CtcModels.loadDirect`, `CtcKeywordSpotter`, `VocabularyRescorer`)
and inverse text normalization (`TextNormalizer`), all through public API,
with `ModelHub.offlineMode = true` so the library never downloads anything
itself. Every model is read from Nano's own verified model directory.

## Why vendored rather than a remote package dependency

The upstream package declares its `NemoTextProcessing` binary target as a
remote zip. SwiftPM authenticates every artifact download against the login
keychain, which raises a modal Keychain prompt on machines that store a
GitHub credential. A local copy builds offline with no prompt, and pins the
exact source revision alongside the pinned runtime frameworks in
`Nano/Frameworks`.

## What was changed

- `Package.swift`: iOS platform, the CLI executable and the test target were
  removed; `NemoTextProcessing` now points at `Binaries/` instead of the URL.
- `Binaries/NemoTextProcessing.xcframework`: from
  `text-processing-rs` v0.3.0, zip SHA-256
  `76d0ee9a32b1ee2193231299180ca9bc4fc7e98794e771b3d55d66498352d85f`
  (matches the checksum upstream pins). iOS slices removed; `Info.plist`
  lists the macOS slice only.
- `Sources/FluidAudioCLI`, `Tests/`, docs and the podspec were not copied.

Sources under `Sources/` are byte-identical to the tag.

## Updating

Check out the new tag, copy `Sources/FluidAudio`, `Sources/FastClusterWrapper`,
`Sources/MachTaskSelfWrapper`, `LICENSE`, `ThirdPartyLicenses/` over this
directory, re-apply the `Package.swift` edits above, refresh the binary
artifact if its URL/checksum changed, and update the version here.
