# Getting to true streaming — next steps

Status note for picking this back up. Everything below the "Done" line is built
and verified; everything under "Remaining" is not started.

## The goal

Text pastes into the focused app *incrementally, while you are still speaking* —
the behaviour `../dictate-wrapper` already has. Upstream Hex is batch-only:
record, release, transcribe once, paste once.

## Done and verified

- **The app builds and runs without Xcode.** `Package.swift` builds it as a plain
  SPM executable alongside the untouched `Hex.xcodeproj`. See "Running it" in
  `CLAUDE.md`.
- **Model plumbing.** `StreamingModel` (HexCore) names the variant;
  `StreamingParakeetClient` handles download, load, availability, delete;
  `TranscriptionClient` routes streaming identifiers to it; `models.json` lists it
  so it shows in Settings. Verified at runtime — FluidAudio loads the cached
  Parakeet Unified encoder at the 1120 ms tier.
- **The audio tap.** `SuperFastCaptureController.process()` yields every
  16 kHz mono Float32 buffer to `samplesContinuation`, exposed as
  `RecordingClient.observeSamples() -> AsyncStream<[Float]>`. Emitted from the same
  post-conversion point that feeds the recording file, under the same
  `captureGeneration` guard. **This is wired but nothing consumes it yet.**
- **The session API.** `StreamingParakeetClient.startSession(modelName:onPartial:)`
  / `append(_:)` / `finishSession(padMilliseconds:)` / `cancelSession()`.
  **Built but never called.**
- **Text logic, unit tested in HexCore.**
  - `AppendOnlyTranscriptCursor` — cumulative transcript → safe deltas, with a
    divergence guard that inserts nothing rather than guessing.
  - `StreamingTextTransformer` — applies word remappings to a delta stream,
    releasing only through the last whitespace.

### Known rough edges

- **First use stalls ~20 s.** CoreML compile/load of the encoder. Cached in memory
  afterward. Not yet surfaced in the UI as anything other than a spinner.
- **The streaming model is currently *slower* than batch, and pastes only at the
  end.** Expected: `StreamingParakeetClient.transcribe(_:modelName:)` is an interim
  whole-file path. Run over a finished recording, the streaming encoder re-encodes
  overlapping windows and so does strictly more work than the offline TDT encoder.
  This goes away when the live path lands — the work then happens while you talk.

## Remaining

### 1. Consume the sample stream in `TranscriptionFeature`

The whole remaining job is one branch in `TranscriptionFeature`, added *beside*
the batch path rather than replacing it.

- In `handleStartRecording` (`Hex/Features/Transcription/TranscriptionFeature.swift:~280`):
  if `StreamingModel.isStreaming(state.hexSettings.selectedModel)`, after
  `recording.startRecording()`, call `startSession` and spawn a long-running
  effect that iterates `recording.observeSamples()` and calls `append(_:)` per
  buffer. Make it `.cancellable(id:)` — cancel and discard must tear it down.
- Partial callback → `AppendOnlyTranscriptCursor.observe(_:isFinal:)` →
  `StreamingTextTransformer.consume(_:transform:)` → paste the returned text.
  Pass the *existing* transform stack as the closure (word removals, remappings,
  `lowercaseTranscripts`, `removePunctuation`) so streaming and batch produce the
  same text; see `handleTranscriptionResult` for the current order.
- In `handleStopRecording`: `finishSession()`, run the final cumulative text
  through the cursor, `flush()` the transformer, paste whatever is left, then
  reuse the existing history/`transcriptionResult` path.
- Gate off the interim `transcribe` call so it does not run a second decode.

### 2. Incremental paste

`PasteboardClient.paste(text:)` does a full save/write/Cmd+V/wait/restore cycle
per call. That is fine once per recording and too heavy per word.

Port `ClipboardPreserver` from `../dictate-wrapper/Sources/DictateNemotron/ClipboardPreserver.swift`
(~116 lines): snapshot the clipboard once at session start, write + Cmd+V per
delta, restore once at the end. dictate-wrapper's `insertCommittedText` shows the
exact CGEvent sequence.

### 3. Decide what cancel means

ESC and the discard path currently throw the recording away. Once text has been
pasted into someone else's document that is no longer possible. Simplest honest
V1: stop the session, keep what was already pasted, skip the history entry. Needs
to be a deliberate decision, not a default.

### 4. Only then, settings

Latency-tier picker, a streaming on/off toggle, live-transcript display in the
indicator. All deliberately out of scope until the above works.

## Deliberately not doing

- **Multi-word remappings spanning a delta boundary** (`"new line"` → `\n`) will
  not fire. Needs lookahead; there is a test in `StreamingTextTransformerTests`
  documenting the behaviour so a future implementation has something to flip.
- **Retroactively correcting pasted text** on divergence. The cursor reports it
  and inserts nothing; that is the correct behaviour, not a gap.

## Useful facts, so they are not re-derived

- Upstream already pins **FluidAudio 0.15.5**, and the streaming API is public at
  that version. No dependency change was ever needed.
- FluidAudio builds its transcript by appending **sentencepiece pieces**
  (`StreamingUnifiedAsrManager.processWindow`), so a delta can end mid-word. That
  is why `StreamingTextTransformer` releases on whitespace, not on delta arrival.
- Because the SPM build is **not sandboxed**, models resolve to the shared
  `~/Library/Application Support/FluidAudio/Models/` — the same cache
  dictate-wrapper populated, so nothing re-downloads.
