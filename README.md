# Hex Has Moved

I rewrote Hex in Rust. **[Try the new beta](https://hex.kitlangton.com)** and tell me what you think.

The new source lives at **[anomalyco/hex](https://github.com/anomalyco/hex)**.
This repository preserves the original Swift app, its history, and its releases.

## Legacy Swift App

Press-and-hold a hotkey to transcribe your voice and paste the result wherever you're typing.

---

## 🔀 This is a fork — `kkrausse/hex`, branch `streaming`

Upstream is [kitlangton/Hex](https://github.com/kitlangton/Hex) (git remote `upstream`).
This fork adds **live streaming dictation**: text pasted incrementally *while you
speak*, using FluidAudio's Parakeet Unified streaming model. Upstream is
batch-only — record, release, transcribe once, paste once.

**Status:** live dictation works. With a Parakeet Streaming model selected, words
are pasted into the focused app about one word behind your voice. See
[`docs/streaming-next.md`](docs/streaming-next.md) for how it works and what remains.

Auto-update is disabled on purpose. Left enabled, this build would update itself
back to an upstream release and silently discard the fork.

### Build and run

This fork adds a `Package.swift` that builds the app as a plain SPM executable,
alongside the untouched `Hex.xcodeproj`. It requires Swift 6.1 or newer.
Xcode 16.2 includes Swift 6.0.3, which is too old for the pinned Composable
Architecture dependency.

If `swift --version` reports an older version, install the standalone toolchain
with [Swiftly](https://github.com/swiftlang/swiftly). This is much smaller than
installing a new Xcode release:

```bash
brew install swiftly
swiftly init
. "$HOME/.swiftly/env.sh"
swiftly install 6.3.3
swiftly use 6.3.3
swift --version
```

The repository's `.swift-version` selects Swift 6.3.3 for Swiftly users. It
does not replace the installed macOS SDK.

```bash
swift build              # ~30s incremental, a few minutes cold
./.build/debug/HexApp    # runs in the foreground
```

It's a **menu-bar app with no dock icon**, so nothing visibly opens — look for the
hexagon at the top right of your screen. Settings live in that menu.

```bash
pkill -f "debug/HexApp"                        # stop it
pkill -f "debug/HexApp"; swift build && ./.build/debug/HexApp   # rebuild + relaunch
```

Because this is an unsigned dev binary, macOS re-prompts for Microphone,
Accessibility, and Input Monitoring whenever the executable changes. A stable
signing identity would avoid that.

> `swift run HexApp` also works, but swallows the app's stdout logging — prefer
> launching the binary directly.

### Dictating through a server

Live dictation can run against your own dictation server instead of the on-device
model — useful when another machine has the faster GPU. Settings → **Live
Dictation Server**: turn on *Dictate through a server* and enter the server's
address (`https://host:9876`). Off by default.

- The server speaks "streaming dictation protocol v1" (`docs/protocol.md` in the
  `dictation-server` repo): `WSS /v1/stream`, 16 kHz mono Float32 in, cumulative
  partials out. `curl https://host:9876/v1/status` tells you whether it is up.
- Works with Super Fast Mode on or off, like on-device streaming. No model has to
  be downloaded on the Mac, but the model selected under Transcription Model is the fallback:
  if the server is unreachable or busy, the recording is transcribed with it and
  pasted once.
- One recording at a time per server, five minutes per recording. If the server
  drops out after text has already been pasted, dictation stops there — nothing
  is retracted and the rest is not replayed.

#### Build troubleshooting

- Sauce is pinned to revision `9c0de6c233f29d892e86dda68c2dd791aa10670c` in
  both package manifests. Do not switch it back to `master`: its current
  `Package.swift` has an invalid trailing comma and cannot be resolved.
- If SwiftPM stays at `[1/41919] Fetching fluidaudio` for more than a few
  minutes, cancel it. GitHub is available, but SwiftPM's full Git fetch can
  stall. Downloading the exact source archive succeeds quickly:

  ```bash
  mkdir -p .build/local-dependencies
  curl --fail --location --output .build/local-dependencies/FluidAudio.zip \
    https://github.com/FluidInference/FluidAudio/archive/19600a485baa4998812e4654b70d2bab8f2c9949.zip
  ditto -x -k .build/local-dependencies/FluidAudio.zip .build/local-dependencies
  ln -s FluidAudio-19600a485baa4998812e4654b70d2bab8f2c9949 .build/local-dependencies/FluidAudio
  ```

  Then temporarily replace FluidAudio's URL dependency in `Package.swift` with:

  ```swift
  .package(path: ".build/local-dependencies/FluidAudio"),
  ```

- Cancelling a build can leave `swift-build` running and lock `.build`. Find
  the PID with `pgrep -fl swift-build`, stop the stale process with `kill <PID>`,
  then retry `swift build`.

### Tests

```bash
./HexCore/run-tests.sh
```

Use this rather than `swift test`. On a Command Line Tools-only machine, Swift
Testing is installed but off the default search paths, and a plain `swift test`
fails three ways in a row; the script bakes the needed rpaths in at link time.

### Notes

- **First transcription stalls ~20s** while CoreML compiles the encoder. Cached
  in memory afterward.
- **The streaming model is currently slower than the batch one.** Expected — it's
  still going through an interim whole-file path, where the streaming encoder
  re-encodes overlapping windows and does strictly more work than the offline
  encoder for no benefit. This inverts once the live path lands.
- Models are shared with any other FluidAudio app on the machine
  (`~/Library/Application Support/FluidAudio/Models/`), since the SPM build isn't
  sandboxed.

Agent-facing notes live in [`CLAUDE.md`](CLAUDE.md).

---

*Everything below is upstream's README. **The download links are upstream's
builds, not this fork** — to run the fork, build it as above.*

**[Download Hex for macOS](https://hex-updates.s3.us-east-1.amazonaws.com/hex-latest.dmg)**

> **Note:** Hex is currently only available for **Apple Silicon** Macs.

Or download via homebrew:
```bash
brew install --cask kitlangton-hex
```

The Swift version supports [Parakeet TDT v3](https://github.com/FluidInference/FluidAudio)
through [FluidAudio](https://github.com/FluidInference/FluidAudio) and
[WhisperKit](https://github.com/argmaxinc/WhisperKit) for on-device transcription.
It uses the [Swift Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture).

## Instructions

Once you open Hex, you'll need to grant it microphone and accessibility permissions—so it can record your voice and paste the transcribed text into any application, respectively.

Once you've configured a global hotkey, there are **two recording modes**:

1. **Press-and-hold** the hotkey to begin recording, say whatever you want, and then release the hotkey to start the transcription process. 
2. **Double-tap** the hotkey to *lock recording*, say whatever you want, and then **tap** the hotkey once more to start the transcription process.

## Contributing

For the Rust beta, new features, and current development, use
**[anomalyco/hex](https://github.com/anomalyco/hex)**.
Issues specific to the legacy Swift app can still be reported
[here](https://github.com/kitlangton/Hex/issues). Please discuss substantial legacy
changes before opening a pull request.

### Changelog workflow

- **For AI agents:** Run `bun run changeset:add-ai <type> "summary"` (e.g., `bun run changeset:add-ai patch "Fix clipboard timing"`) to create a changeset non-interactively.
- **For humans:** Run `bunx changeset` when your PR needs release notes. Pick `patch`, `minor`, or `major` and write a short summary—this creates a `.changeset/*.md` fragment.
- Check what will ship with `bunx changeset status --verbose`.
- `npm run sync-changelog` (or `bun run tools/scripts/sync-changelog.ts`) mirrors the root `CHANGELOG.md` into `Hex/Resources/changelog.md` so the in-app sheet always matches GitHub releases.
- The release tool consumes the pending fragments, bumps `package.json` + `Info.plist`, regenerates `CHANGELOG.md`, and feeds the resulting section to GitHub + Sparkle automatically. Releases fail fast if no changesets are queued, so you can't forget.
- If you truly need to ship without pending Changesets (for example, re-running a failed publish), the release script will now prompt you to confirm and choose a `patch`/`minor`/`major` bump interactively before continuing.

## License

This project is licensed under the MIT License. See `LICENSE` for details.
