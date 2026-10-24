https://github.com/user-attachments/assets/6c8c8702-e811-45f7-b42f-e2fe8030c3ae

<h1 align="center"><img src="docs/images/nano-icon.png" width="40" height="40" align="top" alt=""> Nano</h1>

<p align="center">
  The notch, put to work. A free, open source island for your Mac.
</p>

<p align="center">
  <a href="https://github.com/valenxi0/Nano/releases/latest">Download</a> ·
  <a href="https://trynano.app">Website</a> ·
  <a href="https://github.com/valenxi0/Nano/issues/new?template=bug_report.yml">Report a bug</a> ·
  <a href="https://ko-fi.com/valenxi">Support on Ko-fi</a>
</p>

---

Nano lives at the top of your screen, around the notch or floating below the
menu bar on Macs without one. Hover it for a dashboard. It also speaks up when
something happens: a volume change, AirPods connecting, a timer ending, or a
coding agent waiting on you.

Everything runs on your Mac. No account, no analytics, no ads.

## What it does

**The island and dashboard**
- Music controls for Apple Music and Spotify
- Calendar with today's events and meeting links
- Weather for a place you choose
- Focus timer with breaks
- Camera mirror (nothing is recorded)
- File tray: drop files on the island, drag them out later, or AirDrop them
- Volume, brightness, Bluetooth and charging cards that replace the macOS ones

**Add-ons you turn on when you want them**
- **Agents.** See what your coding agents are doing, how much of your usage
  limit is left, and approve or answer them from the island. Works with Claude
  Code, Codex, Cursor, Gemini CLI, Grok, Kimi, OpenCode, Pi, Devin, Cline,
  Qwen Code, Kilo and Goose.
- **Quill.** Voice dictation that runs on your Mac. Hold a shortcut, talk, and
  the text is typed where your cursor is. Pick from Parakeet, Whisper and other
  local models.
- **Sketch.** Talk while you mark up the screen, and send both to your agent.
- **Cue.** A to-do list for each project, with prompts and screenshots. It can
  sync with Reminders, Todoist and other apps.
- **Mixer.** Volume for each app.

**Look and feel**
- Notch or floating placement
- Solid Black, Liquid Glass or Hybrid appearance
- Choose and arrange the widgets on the dashboard

## Install

1. Download the latest `Nano-x.y.z.dmg` from
   [Releases](https://github.com/valenxi0/Nano/releases/latest).
2. Open it and drag Nano to Applications.
3. Open Nano. Setup walks you through what you want and the permissions each
   part needs.

Requires macOS 14.6 or later on an Apple silicon Mac.

Nano checks GitHub once a day for a new release and tells you on the island.
You can turn that off in Settings › Privacy & About. Updates keep your settings
and permissions.

## Permissions

Nano asks only when you turn on something that needs it.

| Permission | Used for |
| --- | --- |
| Accessibility | Quill typing text, and jumping to an agent's window |
| Microphone | Quill and Sketch |
| Screen Recording | Sketch |
| System audio | Mixer |
| Calendar | The Calendar widget |
| Reminders | Syncing Cue with Reminders |
| Location | Weather, if you use your current location |
| Automation | Music controls, and jumping to Cursor or T3 Code sessions |
| Bluetooth | Accessory cards |
| Camera | The camera mirror |
| Full Disk Access and Contacts | Showing your Mac's notifications on the island, with contact photos (optional) |

## Privacy

- Agent activity, cues, dictation and settings stay on your Mac.
- Usage checks go straight to each agent's provider with the sign-in it
  already has. Nano never copies your credentials.
- Weather sends only the location you saved.
- The update check asks GitHub for the latest release. Nothing about you is sent.
- Speech models are downloaded only when you pick one.

## Build from source

You need Xcode 26.6 or later.

```sh
git clone https://github.com/valenxi0/Nano.git
cd Nano
cp Config/Signing.local.xcconfig.example Config/Signing.local.xcconfig
# set DEVELOPMENT_TEAM in that file to your Apple team ID
open Nano.xcodeproj
```

Build and run the `Nano` scheme. To check that it compiles without signing:

```sh
xcodebuild -project Nano.xcodeproj -scheme Nano -configuration Debug \
  CODE_SIGNING_ALLOWED=NO PRODUCT_BUNDLE_IDENTIFIER=com.nanoapp.Nano.CompileOnly build
```

Sign with the same certificate every time you build. If the signature changes,
macOS forgets Nano's Accessibility permission and Quill can no longer type.
`tools/install-local-signed.sh` builds, signs and installs a copy that keeps
its permissions.

Weather needs a WeatherKit-enabled App ID, so it is off in builds signed with
a development certificate.

## Report a bug or ask for a feature

Use **Report a Bug** in Nano's menu bar menu or at the bottom of the Settings sidebar.
It opens a GitHub issue with your Nano and macOS versions filled in. You can
also [open an issue](https://github.com/valenxi0/Nano/issues/new/choose)
directly.

## Support Nano

Nano is free and stays free. If it's useful to you, a one-time tip on
[Ko-fi](https://ko-fi.com/valenxi) helps me keep building it. It's optional and
unlocks nothing.

## Credits

- Sketch's idea comes from [Scrawl](https://github.com/kitlangton/scrawl) by
  Kit Langton.
- The agent "working" orb is a SwiftUI port of
  [thinking-orbs](https://github.com/Jakubantalik/Libraries) by Jakub Antalik.
- Local speech runs on [FluidAudio](https://github.com/FluidInference/FluidAudio),
  [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and
  [llama.cpp](https://github.com/ggml-org/llama.cpp).

Full licenses are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[MIT](LICENSE) © valenxi
