//
//  TranscriptionFeature.swift
//  Hex
//
//  Created by Kit Langton on 1/24/25.
//

import ComposableArchitecture
import CoreGraphics
import Foundation
import HexCore
import Inject
import SwiftUI
import WhisperKit

private let transcriptionFeatureLogger = HexLog.transcription

@Reducer
struct TranscriptionFeature {
  @ObservableState
  struct State: Equatable {
    var isRecording: Bool = false
    var isTranscribing: Bool = false
    var isPrewarming: Bool = false
    /// True between opening a live streaming session and closing it. When false
    /// the recording takes the batch path, whatever model is selected.
    var isStreamingSession: Bool = false
    var error: String?
    var recordingStartTime: Date?
    var meter: Meter = .init(averagePower: 0, peakPower: 0)
    var sourceAppBundleID: String?
    var sourceAppName: String?
    @Shared(.hexSettings) var hexSettings: HexSettings
    @Shared(.isRemappingScratchpadFocused) var isRemappingScratchpadFocused: Bool = false
    @Shared(.modelBootstrapState) var modelBootstrapState: ModelBootstrapState
    @Shared(.transcriptionHistory) var transcriptionHistory: TranscriptionHistory
  }

  enum Action {
    case task
    case audioLevelUpdated(Meter)

    // Hotkey actions
    case hotKeyPressed
    case hotKeyReleased

    // Recording flow
    case startRecording
    case stopRecording

    // Cancel/discard flow
    case cancel   // Explicit cancellation with sound
    case discard  // Silent discard (too short/accidental)

    // Transcription result flow
    case transcriptionResult(String, URL, TimeInterval)
    case transcriptionError(Error, URL?)

    // Streaming flow
    /// The live session could not be opened; this recording falls back to batch.
    case streamingSessionUnavailable
    /// A streaming session ended. The text is already in the user's document.
    case streamingResult(String, URL?, TimeInterval)

    // Model availability
    case modelMissing
  }

  enum CancelID {
    case metering
    case recordingStart
    case recordingCleanup
    case transcription
    case sampleForwarding
  }

  @Dependency(\.transcription) var transcription
  @Dependency(\.streamingDictation) var streamingDictation
  @Dependency(\.recording) var recording
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.keyEventMonitor) var keyEventMonitor
  @Dependency(\.soundEffects) var soundEffect
  @Dependency(\.sleepManagement) var sleepManagement
  @Dependency(\.date.now) var now
  @Dependency(\.transcriptPersistence) var transcriptPersistence

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      // MARK: - Lifecycle / Setup

      case .task:
        // Starts concurrent effects:
        // 1) Observing audio meter
        // 2) Monitoring hot key events
        // 3) Priming the recorder for instant startup
        // 4) Draining the capture tap into the streaming decoder
        // 5) Compiling the streaming encoder before it is first needed
        return .merge(
          startMeteringEffect(),
          startHotKeyMonitoringEffect(),
          warmUpRecorderEffect(),
          startSampleForwardingEffect(),
          prewarmStreamingModelEffect(model: state.hexSettings.selectedModel)
        )

      // MARK: - Metering

      case let .audioLevelUpdated(meter):
        state.meter = meter
        return .none

      // MARK: - HotKey Flow

      case .hotKeyPressed:
        // If we're transcribing, send a cancel first. Otherwise start recording immediately.
        // We'll decide later (on release) whether to keep or discard the recording.
        return handleHotKeyPressed(isTranscribing: state.isTranscribing)

      case .hotKeyReleased:
        // If we're currently recording, then stop. Otherwise, just cancel
        // the delayed "startRecording" effect if we never actually started.
        return handleHotKeyReleased(isRecording: state.isRecording)

      // MARK: - Recording Flow

      case .startRecording:
        return handleStartRecording(&state)

      case .stopRecording:
        return handleStopRecording(&state)

      // MARK: - Transcription Results

      case let .transcriptionResult(result, audioURL, duration):
        return handleTranscriptionResult(&state, result: result, audioURL: audioURL, duration: duration)

      case let .transcriptionError(error, audioURL):
        return handleTranscriptionError(&state, error: error, audioURL: audioURL)

      // MARK: - Streaming Results

      case .streamingSessionUnavailable:
        state.isStreamingSession = false
        return .none

      case let .streamingResult(text, audioURL, duration):
        return handleStreamingResult(&state, text: text, audioURL: audioURL, duration: duration)

      case .modelMissing:
        return .none

      // MARK: - Cancel/Discard Flow

      case .cancel:
        // Only cancel if we're in the middle of recording, transcribing, or post-processing
        guard state.isRecording || state.isTranscribing else {
          return .none
        }
        return handleCancel(&state)

      case .discard:
        // Silent discard for quick/accidental recordings
        guard state.isRecording else {
          return .none
        }
        return handleDiscard(&state)
      }
    }
  }
}

// MARK: - Effects: Metering & HotKey

private extension TranscriptionFeature {
  /// Effect to begin observing the audio meter.
  func startMeteringEffect() -> Effect<Action> {
    .run { send in
      for await meter in await recording.observeAudioLevel() {
        await send(.audioLevelUpdated(meter))
      }
    }
    .cancellable(id: CancelID.metering, cancelInFlight: true)
  }

  /// Effect to start monitoring hotkey events through the `keyEventMonitor`.
  func startHotKeyMonitoringEffect() -> Effect<Action> {
    .run { send in
      var hotKeyProcessor: HotKeyProcessor = .init(hotkey: HotKey(key: nil, modifiers: [.option]))
      @Shared(.isSettingHotKey) var isSettingHotKey: Bool
      @Shared(.hexSettings) var hexSettings: HexSettings

      // Handle incoming input events (keyboard and mouse)
      let token = keyEventMonitor.handleInputEvent { inputEvent in
        // Skip if the user is currently setting a hotkey
        if isSettingHotKey {
          return false
        }

        // Always keep hotKeyProcessor in sync with current user hotkey preference
        hotKeyProcessor.hotkey = hexSettings.hotkey
        let useDoubleTapOnly = hexSettings.doubleTapLockEnabled && hexSettings.useDoubleTapOnly
        hotKeyProcessor.doubleTapLockEnabled = hexSettings.doubleTapLockEnabled
        hotKeyProcessor.useDoubleTapOnly = useDoubleTapOnly
        hotKeyProcessor.minimumKeyTime = hexSettings.minimumKeyTime

        switch inputEvent {
        case .keyboard(let keyEvent):
          // If Escape is pressed with no modifiers while idle, let's treat that as `cancel`.
          if keyEvent.key == .escape, keyEvent.modifiers.isEmpty,
             hotKeyProcessor.state == .idle
          {
            Task { await send(.cancel) }
            return false
          }

		  // Process the key event
		  switch hotKeyProcessor.process(keyEvent: keyEvent) {
		  case .startRecording:
			Task { await send(.hotKeyPressed) }
            // If the hotkey is purely modifiers, return false to keep it from interfering with normal usage
            // But if useDoubleTapOnly is true, always intercept the key
            return useDoubleTapOnly || keyEvent.key != nil

          case .stopRecording:
            Task { await send(.hotKeyReleased) }
            return false // or `true` if you want to intercept

          case .cancel:
            Task { await send(.cancel) }
            return true

          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept - let the key chord reach other apps

          case .none:
            // If we detect repeated same chord, maybe intercept.
            if let pressedKey = keyEvent.key,
               pressedKey == hotKeyProcessor.hotkey.key,
               keyEvent.modifiers == hotKeyProcessor.hotkey.modifiers
            {
              return true
            }
            return false
          }

        case .mouseClick:
          // Process mouse click - for modifier-only hotkeys, this may cancel/discard
          switch hotKeyProcessor.processMouseClick() {
          case .cancel:
            Task { await send(.cancel) }
            return false // Don't intercept the click itself
          case .discard:
            Task { await send(.discard) }
            return false // Don't intercept the click itself
          case .startRecording, .stopRecording, .none:
            return false
          }
        }
      }

      defer { token.cancel() }

      await withTaskCancellationHandler {
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(60))
        }
      } onCancel: {
        token.cancel()
      }
    }
  }

  func warmUpRecorderEffect() -> Effect<Action> {
    .run { _ in
      await recording.warmUpRecorder()
    }
  }

  /// Hands the capture tap to the streaming decoder for the app's lifetime.
  ///
  /// Started once and never cancelled, like metering: the tap is a single
  /// `AsyncStream`, and cancelling a task suspended on it terminates the stream
  /// for good. Per-recording teardown is the session's job instead — buffers
  /// arriving with no session open are dropped by the client.
  func startSampleForwardingEffect() -> Effect<Action> {
    .run { _ in
      await streamingDictation.consumeSamples(recording.observeSamples())
    }
    .cancellable(id: CancelID.sampleForwarding, cancelInFlight: true)
  }

  /// Compiles the streaming encoder in the background at launch.
  ///
  /// The first load is a ~20 s CoreML compile. Doing it here means the user pays
  /// it while the app is idle rather than while holding the hotkey, where it
  /// would silently swallow the opening words of a recording.
  func prewarmStreamingModelEffect(model: String) -> Effect<Action> {
    guard StreamingModel.isStreaming(model) else { return .none }
    return .run { _ in
      await streamingDictation.prewarm(model)
    }
  }
}

// MARK: - HotKey Press/Release Handlers

private extension TranscriptionFeature {
  func handleHotKeyPressed(isTranscribing: Bool) -> Effect<Action> {
    // If already transcribing, cancel first. Otherwise start recording immediately.
    guard isTranscribing else { return .send(.startRecording) }
    return .concatenate(
      .send(.cancel),
      .send(.startRecording)
    )
  }

  func handleHotKeyReleased(isRecording: Bool) -> Effect<Action> {
    // Always stop recording when hotkey is released
    return isRecording ? .send(.stopRecording) : .none
  }
}

// MARK: - Recording Handlers

private extension TranscriptionFeature {
  func handleStartRecording(_ state: inout State) -> Effect<Action> {
    guard state.modelBootstrapState.isModelReady else {
      return .merge(
        .send(.modelMissing),
        .run { _ in soundEffect.play(.cancel) }
      )
    }
    state.isRecording = true
    let startTime = now
    state.recordingStartTime = startTime
    
    // Capture the active application
    if let activeApp = NSWorkspace.shared.frontmostApplication {
      state.sourceAppBundleID = activeApp.bundleIdentifier
      state.sourceAppName = activeApp.localizedName
    }
    transcriptionFeatureLogger.notice("Recording started at \(startTime.ISO8601Format())")

    // Live streaming needs the capture engine's sample tap, which only exists in
    // super fast mode. With it off the recording still happens — it just takes
    // the batch path at the end, exactly as it does for any non-streaming model.
    let model = state.hexSettings.selectedModel
    let wantsStreaming = StreamingModel.isStreaming(model) && state.hexSettings.superFastModeEnabled
    if StreamingModel.isStreaming(model), !state.hexSettings.superFastModeEnabled {
      transcriptionFeatureLogger.notice(
        "Streaming model selected but super fast mode is off; using the batch path for this recording"
      )
    }
    state.isStreamingSession = wantsStreaming
    let transformStack = streamingTransformStack(&state)
    let keepTranscriptOnClipboard = state.hexSettings.copyToClipboard

    // Prevent system sleep during recording
    return .merge(
      .cancel(id: CancelID.recordingCleanup),
      .run { [sleepManagement, preventSleep = state.hexSettings.preventSystemSleep] send in
        // Play sound immediately for instant feedback
        soundEffect.play(.startRecording)

        if preventSleep {
          await sleepManagement.preventSleep(reason: "Hex Voice Recording")
        }
        guard !Task.isCancelled else {
          if preventSleep {
            await sleepManagement.allowSleep()
          }
          return
        }
        // Opened before the recorder so no captured buffer predates the session.
        if wantsStreaming {
          do {
            try await streamingDictation.start(model, transformStack, keepTranscriptOnClipboard)
          } catch {
            transcriptionFeatureLogger.error(
              "Could not open a streaming session (\(error.localizedDescription)); falling back to the batch path"
            )
            await send(.streamingSessionUnavailable)
          }
        }
        await recording.startRecording()
      }
      .cancellable(id: CancelID.recordingStart, cancelInFlight: true)
    )
  }

  /// The transform stack streaming applies per released word.
  ///
  /// Deliberately the same type the batch path runs over the whole transcript in
  /// `handleTranscriptionResult`, so the two cannot drift.
  func streamingTransformStack(_ state: inout State) -> TranscriptTransformStack {
    guard !state.isRemappingScratchpadFocused else { return .identity }
    return TranscriptTransformStack(
      removalsEnabled: state.hexSettings.wordRemovalsEnabled,
      removals: state.hexSettings.wordRemovals,
      remappings: state.hexSettings.wordRemappings,
      lowercase: state.hexSettings.lowercaseTranscripts,
      removePunctuation: state.hexSettings.removePunctuation
    )
  }

  func handleStopRecording(_ state: inout State) -> Effect<Action> {
    state.isRecording = false
    
    let stopTime = now
    let startTime = state.recordingStartTime
    let duration = startTime.map { stopTime.timeIntervalSince($0) } ?? 0

    let decision = RecordingDecisionEngine.decide(
      .init(
        hotkey: state.hexSettings.hotkey,
        minimumKeyTime: state.hexSettings.minimumKeyTime,
        recordingStartTime: state.recordingStartTime,
        currentTime: stopTime
      )
    )

    let startStamp = startTime?.ISO8601Format() ?? "nil"
    let stopStamp = stopTime.ISO8601Format()
    let minimumKeyTime = state.hexSettings.minimumKeyTime
    let hotkeyHasKey = state.hexSettings.hotkey.key != nil
    transcriptionFeatureLogger.notice(
      "Recording stopped duration=\(String(format: "%.3f", duration))s start=\(startStamp) stop=\(stopStamp) decision=\(String(describing: decision)) minimumKeyTime=\(String(format: "%.2f", minimumKeyTime)) hotkeyHasKey=\(hotkeyHasKey)"
    )

    guard decision == .proceedToTranscription else {
      // If the user recorded for less than minimumKeyTime and the hotkey is modifier-only,
      // discard the audio to avoid accidental triggers.
      transcriptionFeatureLogger.notice("Discarding short recording per decision \(String(describing: decision))")
      return handleDiscard(&state)
    }

    let model = state.hexSettings.selectedModel
    guard !model.isEmpty else {
      // Defense-in-depth: handleStartRecording already blocks recording when the
      // bootstrap state says no model is ready, but settings can change while a
      // recording is in flight (or the in-memory bootstrap default can race a
      // cold launch). Never hand an empty model name to the transcriber: it
      // silently produces nothing (or junk like "[BLANK_AUDIO]").
      transcriptionFeatureLogger.error("Recording stopped with no transcription model selected; discarding audio")
      return .merge(
        handleDiscard(&state),
        .send(.modelMissing)
      )
    }

    // Otherwise, proceed to transcription
    state.isTranscribing = true
    state.error = nil
    let language = state.hexSettings.outputLanguage

    state.isPrewarming = true

    if state.isStreamingSession {
      state.isStreamingSession = false
      return .merge(
        .cancel(id: CancelID.recordingStart),
        .run { [sleepManagement] send in
          await sleepManagement.allowSleep()

          // Stop first: `finish` waits for the marker this emits, so every
          // sample captured is decoded before the decoder is flushed.
          let stopResult = await recording.stopRecording()
          var capturedURL: URL?
          switch stopResult {
          case let .captured(url):
            capturedURL = url
          case .ignored(.staleSession):
            transcriptionFeatureLogger.notice("Ignoring streaming stop superseded by a newer recording session")
            _ = await streamingDictation.cancel()
            return
          case .ignored(.noActiveRecording):
            transcriptionFeatureLogger.error("Streaming recording stopped without captured audio")
          case let .failed(error):
            // The text is already in the user's document either way, so this
            // only costs the history entry's audio.
            transcriptionFeatureLogger.error("Streaming recording stop failed: \(error.localizedDescription)")
          }
          soundEffect.play(.stopRecording)

          let result = await streamingDictation.finish()
          transcriptionFeatureLogger.notice(
            "Streaming session inserted \(result.insertedText.count) characters over \(String(format: "%.2f", duration))s"
          )
          await send(.streamingResult(result.insertedText, capturedURL, duration))
        }
        .cancellable(id: CancelID.transcription)
      )
    }

    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] send in
        // Allow system to sleep again
        await sleepManagement.allowSleep()

        var audioURL: URL?
        defer {
          if let audioURL {
            FileManager.default.removeItemIfExists(at: audioURL)
          }
        }
        do {
          let stopResult = await recording.stopRecording()
          let capturedURL: URL
          switch stopResult {
          case let .captured(url):
            capturedURL = url
          case .ignored(.staleSession):
            transcriptionFeatureLogger.notice("Ignoring transcription stop superseded by a newer recording session")
            return
          case .ignored(.noActiveRecording):
            transcriptionFeatureLogger.error("Recording stopped without captured audio")
            await send(.transcriptionError(RecordingFailure.noCapturedAudio, nil))
            return
          case let .failed(error):
            transcriptionFeatureLogger.error("Recording stop failed: \(error.localizedDescription)")
            await send(.transcriptionError(error, nil))
            return
          }
          audioURL = capturedURL
          guard !Task.isCancelled else { return }
          soundEffect.play(.stopRecording)

          // Create transcription options with the selected language
          // Note: cap concurrency to avoid audio I/O overloads on some Macs
          let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil, // Only auto-detect if no language specified
            chunkingStrategy: .vad,
          )

          let result = try await transcription.transcribe(capturedURL, model, decodeOptions) { _ in }

          transcriptionFeatureLogger.notice("Transcribed audio from \(capturedURL.lastPathComponent) to text length \(result.count)")
          audioURL = nil
          await send(.transcriptionResult(result, capturedURL, duration))
        } catch {
          transcriptionFeatureLogger.error("Transcription failed: \(error.localizedDescription)")
          await send(.transcriptionError(error, nil))
        }
      }
      .cancellable(id: CancelID.transcription)
    )
  }
}

// MARK: - Transcription Handlers

private extension TranscriptionFeature {
  func handleTranscriptionResult(
    _ state: inout State,
    result: String,
    audioURL: URL,
    duration: TimeInterval
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false

    // Check for force quit command (emergency escape hatch)
    if ForceQuitCommandDetector.matches(result) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    // If empty text, nothing else to do
    guard !result.isEmpty else {
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

    transcriptionFeatureLogger.info("Raw transcription: '\(result, privacy: .private)'")
    if state.isRemappingScratchpadFocused {
      transcriptionFeatureLogger.info("Scratchpad focused; skipping word modifications")
    }
    // The same stack the streaming path applies per word, so the two paths
    // cannot produce different text for the same speech.
    let remappings = state.hexSettings.wordRemappings
    let removals = state.hexSettings.wordRemovals
    let modifiedResult = streamingTransformStack(&state).apply(result) { stage in
      switch stage {
      case .removals:
        let enabledRemovalCount = removals.filter(\.isEnabled).count
        transcriptionFeatureLogger.info("Applied \(enabledRemovalCount) word removal(s)")
      case .remappings:
        transcriptionFeatureLogger.info("Applied \(remappings.count) word remapping(s)")
      case .formatting:
        transcriptionFeatureLogger.info("Applied paste formatting")
      }
    }

    guard !modifiedResult.isEmpty else {
      return .run { _ in
        FileManager.default.removeItemIfExists(at: audioURL)
      }
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { send in
      do {
        try await finalizeRecordingAndStoreTranscript(
          result: modifiedResult,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory
        )
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  /// Finishes a streaming session. The text is already in the user's document,
  /// so this only has history, sound, and cleanup left to do — no transforms
  /// (they were applied per word on the way out) and no paste.
  func handleStreamingResult(
    _ state: inout State,
    text: String,
    audioURL: URL?,
    duration: TimeInterval
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.isStreamingSession = false

    if ForceQuitCommandDetector.matches(text) {
      transcriptionFeatureLogger.fault("Force quit voice command recognized; terminating Hex.")
      return .run { _ in
        if let audioURL { FileManager.default.removeItemIfExists(at: audioURL) }
        await MainActor.run {
          NSApp.terminate(nil)
        }
      }
    }

    guard !text.isEmpty else {
      return .run { _ in
        if let audioURL { FileManager.default.removeItemIfExists(at: audioURL) }
      }
    }

    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .run { send in
      do {
        try await storeTranscript(
          result: text,
          duration: duration,
          sourceAppBundleID: sourceAppBundleID,
          sourceAppName: sourceAppName,
          audioURL: audioURL,
          transcriptionHistory: transcriptionHistory
        )
        soundEffect.play(.pasteTranscript)
      } catch {
        await send(.transcriptionError(error, audioURL))
      }
    }
    .cancellable(id: CancelID.transcription)
  }

  func handleTranscriptionError(
    _ state: inout State,
    error: Error,
    audioURL: URL?
  ) -> Effect<Action> {
    state.isTranscribing = false
    state.isPrewarming = false
    state.error = error.localizedDescription
    
    if let audioURL {
      FileManager.default.removeItemIfExists(at: audioURL)
    }

    return .none
  }

  /// Move file to permanent location, create a transcript record, paste text, and play sound.
  func finalizeRecordingAndStoreTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws {
    try await storeTranscript(
      result: result,
      duration: duration,
      sourceAppBundleID: sourceAppBundleID,
      sourceAppName: sourceAppName,
      audioURL: audioURL,
      transcriptionHistory: transcriptionHistory
    )
    await pasteboard.paste(result)
    soundEffect.play(.pasteTranscript)
  }

  /// Moves the audio to its permanent location and records the transcript.
  ///
  /// Split out from `finalizeRecordingAndStoreTranscript` for the streaming
  /// path, which has already put its text in the user's document one word at a
  /// time and must not paste it a second time.
  ///
  /// `audioURL` is nil when the recording produced no file — a streaming session
  /// can still have inserted text that deserves a history entry.
  func storeTranscript(
    result: String,
    duration: TimeInterval,
    sourceAppBundleID: String?,
    sourceAppName: String?,
    audioURL: URL?,
    transcriptionHistory: Shared<TranscriptionHistory>
  ) async throws {
    @Shared(.hexSettings) var hexSettings: HexSettings

    guard let audioURL else {
      transcriptionFeatureLogger.notice("Skipping the history entry: the recording produced no audio file")
      return
    }

    if hexSettings.saveTranscriptionHistory {
      let transcript = try await transcriptPersistence.save(
        result,
        audioURL,
        duration,
        sourceAppBundleID,
        sourceAppName
      )

      transcriptionHistory.withLock { history in
        history.history.insert(transcript, at: 0)

        if let maxEntries = hexSettings.maxHistoryEntries, maxEntries > 0 {
          while history.history.count > maxEntries {
            if let removedTranscript = history.history.popLast() {
              Task {
                 try? await transcriptPersistence.deleteAudio(removedTranscript)
              }
            }
          }
        }
      }
    } else {
      FileManager.default.removeItemIfExists(at: audioURL)
    }
  }
}

// MARK: - Cancel/Discard Handlers

private extension TranscriptionFeature {
  func handleCancel(_ state: inout State) -> Effect<Action> {
    let wasRecording = state.isRecording
    let wasStreaming = state.isStreamingSession
    state.isTranscribing = false
    state.isRecording = false
    state.isPrewarming = false
    state.isStreamingSession = false

    let duration = state.recordingStartTime.map { now.timeIntervalSince($0) } ?? 0
    let sourceAppBundleID = state.sourceAppBundleID
    let sourceAppName = state.sourceAppName
    let transcriptionHistory = state.$transcriptionHistory

    return .merge(
      .cancel(id: CancelID.transcription),
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
        guard wasRecording else {
          soundEffect.play(.cancel)
          return
        }
        // Stop the recording to release microphone access
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		}

        // Cancelling a streaming session cannot undo it: the words are already
        // in someone else's document, and Hex has no claim on that text. So
        // cancel means "stop now", not "undo" — the mic is released and the
        // held-back partial word is dropped, but what landed stays, and it
        // still gets a history entry so it is recoverable from Hex.
        if wasStreaming {
          let streamed = await streamingDictation.cancel()
          if !streamed.insertedText.isEmpty {
            transcriptionFeatureLogger.notice(
              "Cancelled a streaming session that had already inserted \(streamed.insertedText.count) characters; keeping them"
            )
            try? await storeTranscript(
              result: streamed.insertedText,
              duration: duration,
              sourceAppBundleID: sourceAppBundleID,
              sourceAppName: sourceAppName,
              // The audio was just deleted along with the cancelled recording.
              audioURL: nil,
              transcriptionHistory: transcriptionHistory
            )
          }
        }
		guard !Task.isCancelled else { return }
		soundEffect.play(.cancel)
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }

  func handleDiscard(_ state: inout State) -> Effect<Action> {
    let wasStreaming = state.isStreamingSession
    state.isRecording = false
    state.isPrewarming = false
    state.isStreamingSession = false

    // Silently discard - no sound effect
    return .merge(
      .cancel(id: CancelID.recordingStart),
      .run { [sleepManagement] _ in
        // Allow system to sleep again
        await sleepManagement.allowSleep()
		let result = await recording.stopRecording()
		if case let .captured(url) = result {
		  FileManager.default.removeItemIfExists(at: url)
		}
        // Discard fires for recordings too short to have produced any streamed
        // text — well under the decoder's first window. Tear the session down
        // anyway so the next recording starts from a clean decoder.
        if wasStreaming {
          let streamed = await streamingDictation.cancel()
          if !streamed.insertedText.isEmpty {
            transcriptionFeatureLogger.notice(
              "Discarded a streaming session that had inserted \(streamed.insertedText.count) characters; keeping them"
            )
          }
        }
		guard !Task.isCancelled else { return }
      }
      .cancellable(id: CancelID.recordingCleanup, cancelInFlight: true)
    )
  }
}

// MARK: - View

struct TranscriptionView: View {
  @Bindable var store: StoreOf<TranscriptionFeature>
  @ObserveInjection var inject

  var status: TranscriptionIndicatorView.Status {
    if store.isTranscribing {
      return .transcribing
    } else if store.isRecording {
      return .recording
    } else if store.isPrewarming {
      return .prewarming
    } else {
      return .hidden
    }
  }

  var body: some View {
    TranscriptionIndicatorView(
      status: status,
      meter: store.meter
    )
    .task {
      await store.send(.task).finish()
    }
    .enableInjection()
  }
}

// MARK: - Force Quit Command

private enum ForceQuitCommandDetector {
  static func matches(_ text: String) -> Bool {
    let normalized = normalize(text)
    return normalized == "force quit hex now" || normalized == "force quit hex"
  }

  private static func normalize(_ text: String) -> String {
    text
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
  }
}
