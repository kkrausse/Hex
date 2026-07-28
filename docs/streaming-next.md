# Live streaming dictation — how it works, and what is left

Status doc for picking this back up. Everything under "Working" is built and
verified end to end on a real machine; everything under "Remaining" is not.

## The goal

Text pastes into the focused app *incrementally, while you are still speaking* —
the behaviour `../dictate-wrapper` already has. Upstream Hex is batch-only:
record, release, transcribe once, paste once.

**This now works.** Select the Parakeet Unified streaming model, hold the hotkey,
and words appear in the focused document about one word behind your voice.

## The path an utterance takes

```
SuperFastCaptureController.process()      16 kHz mono Float32, post-conversion
  → RecordingClient.observeSamples()      one AsyncStream for the app's lifetime
  → StreamingDictationLive.consumeSamples drains it forever; drops when no session
  → StreamingParakeetClient.append()      FluidAudio encoder + RNN-T decoder
  → partial callback (cumulative text)    yielded into the session's own stream
  → StreamingTranscriptPipeline           cumulative → safe delta → whole words
  → IncrementalTextInserter               clipboard + synthetic Cmd+V
```

`StreamingDictationLive` exists to own the **ordering**. Partials arrive on a
callback, so they are funnelled through one `AsyncStream` consumed by one task.
Text inserted out of order cannot be taken back, so this is the one guarantee the
whole design is built around.

### Things that are load-bearing and non-obvious

- **The partial callback is silenced before `finish()`.** FluidAudio's `finish()`
  decodes the final windows, fires the partial callback for their emissions, and
  *then* returns a string already containing that same text. Leaving the callback
  installed inserts the tail twice, microseconds apart — and two pastes that close
  together race on the single clipboard slot, so the target app services both
  after the second write. The symptom was a duplicated last word (`great.great.`).
- **The end-of-utterance marker.** `finishRecording()` yields an empty `[Float]`
  from inside `processingQueue`, ordered strictly after the last sample buffer.
  `finish()` waits for it before flushing. Decoding runs inline on the way in, so
  without this the flush can beat the last second of speech through the decoder.
  The 5 s timeout only exists so a stale capture session cannot wedge the stop path.
- **`observeSamples()` is one stream for the whole app run.** An `AsyncStream`
  terminates permanently when the task iterating it is cancelled, so a
  per-recording consumer would kill the tap for every *later* recording. Consume
  it once, never cancel it, and let the client drop buffers when no session is
  open.
- **`ensureLoaded` deduplicates concurrent loads.** Actor isolation is not enough:
  `loadModels` suspends, and a suspended actor lets the next caller in, who finds
  `loadedModel` still unset and starts a second ~650 MB load. Three callers race
  here in normal use (settings UI, launch prewarm, first recording) — the first
  run of this code compiled the encoder four times concurrently.
- **120 ms floor between pastes.** Deltas normally arrive one encoder window apart
  (~560 ms) and never wait, but when the decoder catches up on several windows at
  once it emits them back to back, and the clipboard is a single slot.
- **`StreamingParakeetClient.shared`.** `TranscriptionClientLive` downloads and
  loads the model; `StreamingDictationLive` opens sessions against it. Separate
  instances would mean two downloads and two resident copies.
- **`finishSession` does not trim.** FluidAudio already trims every partial *and*
  the final identically. Trimming again could make the final stop being an
  extension of the last partial, which the append-only cursor reads as divergence
  — and then the flushed tail is silently dropped.

### Decisions made deliberately

- **Cancel means "stop", not "undo".** ESC releases the mic and drops the
  held-back partial word, but text already inserted stays where it is — it is in
  someone else's document and Hex has no claim on it. A history entry is still
  written so the text is recoverable from Hex. The audio is not: the cancel path
  deletes it.
- **Streaming requires super fast mode.** The sample tap only exists on the
  capture-engine path. With it off, a streaming model silently takes the batch
  path. Logged, not surfaced.
- **Streaming always uses the clipboard transport**, ignoring `useClipboardPaste`.
  The AppleScript typing fallback is far too slow per word. Unicode CGEvent
  injection (`keyboardSetUnicodeString`) is the real answer if this matters.
- **The transform stack is shared.** `TranscriptTransformStack` is applied to the
  whole transcript by the batch path and per released word by the streaming path,
  so the two cannot drift.

## Remaining

1. **Settings UI.** Latency-tier picker, streaming on/off toggle, live-transcript
   display in the indicator. Still deliberately out of scope.
2. **Unicode injection instead of the clipboard.** Would remove the paste race,
   the 120 ms floor, and the clipboard churn entirely.
3. **A stable signing identity.** The unsigned dev binary makes macOS re-prompt
   for Microphone / Accessibility / Input Monitoring on every rebuild.

## Deliberately not doing

- **Multi-word remappings spanning a delta boundary** (`"new line"` → `\n`) will
  not fire. Needs lookahead; `StreamingTextTransformerTests` documents it.
- **Retroactively correcting pasted text** on divergence. The cursor reports it
  and inserts nothing; that is correct behaviour, not a gap.
- **Parity for a removal directly before punctuation.** `WordRemovalApplier`
  tidies whitespace *around* what it deleted, which needs both sides at once;
  streaming only ever sees one span. Same lookahead problem.
  `TranscriptTransformStackTests` pins the divergence.

## Useful facts, so they are not re-derived

- Upstream already pins **FluidAudio 0.15.5**, and the streaming API is public at
  that version. No dependency change was ever needed.
- FluidAudio builds its transcript by appending **sentencepiece pieces**
  (`StreamingUnifiedAsrManager.processWindow`), so a delta can end mid-word. That
  is why `StreamingTextTransformer` releases on whitespace, not on delta arrival.
  It also means the transcript never *starts* with a space —
  `currentTranscript()` trims — so no leading space is ever pasted.
- Because the SPM build is **not sandboxed**, models resolve to the shared
  `~/Library/Application Support/FluidAudio/Models/` — the same cache
  dictate-wrapper populated, so nothing re-downloads.
- **Hex's own logs go to the unified log, not stdout.** Only FluidAudio prints to
  the terminal. To watch a session:
  `log show --last 5m --info --predicate 'subsystem == "com.kitlangton.Hex"' --style compact`
