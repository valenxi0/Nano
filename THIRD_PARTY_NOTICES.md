# Third-party notices

Nano is MIT licensed (see [LICENSE](LICENSE)). It bundles the following
third-party software. Each component keeps its own license, and the full texts
are kept next to the code they cover.

## Bundled code

| Component | Version | License | Where | License text |
| --- | --- | --- | --- | --- |
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) | v1.9.2 (prebuilt `whisper.xcframework`) | MIT, © The ggml authors | `Nano/Packages/NanoSpeechRuntimes/Binaries` | [whisper.cpp-LICENSE](Nano/Packages/NanoSpeechRuntimes/Licenses/whisper.cpp-LICENSE) |
| [llama.cpp](https://github.com/ggml-org/llama.cpp) | b10775 (prebuilt `llama.xcframework`) | MIT, © The ggml authors | `Nano/Packages/NanoSpeechRuntimes/Binaries` | [llama.cpp-LICENSE](Nano/Packages/NanoSpeechRuntimes/Licenses/llama.cpp-LICENSE) |
| [FluidAudio](https://github.com/FluidInference/FluidAudio) | vendored source | Apache-2.0 | `Nano/Packages/FluidAudio` | [LICENSE](Nano/Packages/FluidAudio/LICENSE), plus its own notices in [ThirdPartyLicenses](Nano/Packages/FluidAudio/ThirdPartyLicenses) |
| [Lucide Animated](https://github.com/pqoqubbw/icons) `atom` icon, drawn from [Lucide](https://lucide.dev) | paths copied into `ConnectedModuleViews.swift` | MIT (Lucide Animated); Lucide itself is ISC | `Nano/Views/ConnectedModuleViews.swift` | [Lucide Animated license](https://github.com/pqoqubbw/icons/blob/main/LICENSE), [Lucide license](https://lucide.dev/license) |

## Bundled model

| Model | License | Where |
| --- | --- | --- |
| [Silero VAD](https://github.com/snakers4/silero-vad) v6.2.1, Core ML conversion by [FluidInference](https://huggingface.co/FluidInference/silero-vad-coreml) | MIT, © Silero Team | `Nano/Resources/Models/silero-vad-unified-256ms-v6.2.1.mlmodelc` |

## Speech models downloaded at runtime

These are not in the repository or the app. Nano downloads them only when you
pick them in Settings › Voice, and keeps each model's license files with the
weights.

| Model | Source | License |
| --- | --- | --- |
| Parakeet TDT 0.6B v3 | [nvidia/parakeet-tdt-0.6b-v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), Core ML by FluidInference | CC BY 4.0, attribution to NVIDIA |
| Vocabulary booster (Parakeet CTC 110M) | [nvidia/parakeet-tdt_ctc-110m](https://huggingface.co/nvidia/parakeet-tdt_ctc-110m), Core ML by FluidInference | CC BY 4.0, attribution to NVIDIA |
| S1-mini by Superwhisper | [superwhisper/s1-mini](https://huggingface.co/superwhisper/s1-mini) | Apache 2.0 with a naming clause: the model keeps the name "S1-mini" by "Superwhisper" |
| Cohere Transcribe 03-2026 | [CohereLabs/cohere-transcribe-03-2026](https://huggingface.co/CohereLabs/cohere-transcribe-03-2026), Core ML by FluidInference | Apache 2.0 |
| Whisper Large v3 Turbo, Base (English), Tiny (English) | [openai/whisper](https://github.com/openai/whisper), ggml conversion from [whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp) | MIT |

## Trademarks

Nano shows the logos and names of the coding agents it works with (Claude,
Codex, Cursor, Gemini, Grok, Devin, Kimi, Qwen, Cline, Goose, Kilo, OpenCode,
Pi) in `Nano/Resources/AgentIcons`, and rendered animations of Apple
accessories (AirPods Pro, AirPods Max) in `Nano/Resources/DeviceAnimations`. They are
there only to show which tool or device an event came from. These names, logos
and product designs are trademarks of their owners. Nano is not affiliated with
or endorsed by any of them.

When you add or update a bundled component, add or update its row here and its
license text in the same change.
