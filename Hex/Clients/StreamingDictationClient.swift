import ComposableArchitecture
import Dependencies
import DependenciesMacros
import Foundation
import HexCore

private let dictationLogger = HexLog.transcription

enum StreamingDictationError: LocalizedError {
	case modelNotReady(String)

	var errorDescription: String? {
		switch self {
		case let .modelNotReady(name):
			return "The streaming model \(name) is not loaded yet."
		}
	}
}

/// Which recognizer a live session runs against.
///
/// Everything downstream of the recognizer — the transcript pipeline, the
/// transforms, the inserter — is the same for both; only where the samples go
/// and where the cumulative partials come from differs.
enum StreamingDictationBackend: Equatable, Sendable {
	/// FluidAudio's on-device decoder, by `StreamingModel` raw value.
	case onDevice(modelName: String)
	/// A dictation server's stream endpoint. See `RemoteStreamingClient`.
	case remote(URL)

	var isRemote: Bool {
		if case .remote = self { return true }
		return false
	}
}

/// What a finished (or cancelled) streaming session actually put on screen.
struct StreamingDictationResult: Equatable, Sendable {
	/// The text this session inserted into the focused application, in order.
	/// This — not the recognizer's transcript — is what belongs in history, so
	/// the entry matches the document the user is looking at.
	var insertedText: String
	/// The recognizer's own final transcript, before Hex's transforms. Empty for
	/// a cancelled session, which never asks the recognizer to finish.
	var rawTranscript: String
	/// Set when the recognizer gave up before delivering a final transcript —
	/// only the remote backend can, since a server can vanish mid-sentence.
	/// `insertedText` is then whatever landed before that, possibly nothing, and
	/// the caller decides between transcribing the clip again and reporting it.
	var failure: String? = nil
}

/// Drives live dictation: recognizer session in, text in the user's document out.
///
/// Sits above `StreamingParakeetClient` (which owns the FluidAudio decoder) and
/// `IncrementalTextInserter` (the clipboard transport) or `PasteboardClient` (the
/// keystroke transport, when clipboard paste is off), and owns the
/// one thing neither can: the ordering guarantee. Partial transcripts arrive on
/// a callback, so they are funnelled through a single `AsyncStream` consumed by
/// a single task. Every insertion therefore happens in the order the recognizer
/// emitted it — which matters more here than anywhere else in the app, because
/// text inserted out of order cannot be taken back.
@DependencyClient
struct StreamingDictationClient {
	/// Loads the model if needed. Safe to call repeatedly; cheap once warm.
	var prewarm: @Sendable (String) async -> Void

	/// Opens a session. Throws if the model is not on disk or cannot be loaded,
	/// in which case the caller should fall back to the batch path — which knows
	/// how to download a missing model with a progress UI.
	///
	/// A remote session never throws here: it connects in the background so the
	/// microphone is not kept waiting, and reports an unreachable server through
	/// `StreamingDictationResult.failure` when the session is finished.
	var start: @Sendable (
		_ backend: StreamingDictationBackend,
		_ transform: TranscriptTransformStack,
		_ keepTranscriptOnClipboard: Bool
	) async throws -> Void

	/// Drives the decoder from the recorder's sample tap for the lifetime of the
	/// app. Buffers that arrive while no session is open are dropped, which is
	/// what makes one long-lived consumer safe — and necessary, since the tap is
	/// a single `AsyncStream` that cannot be re-iterated once abandoned.
	var consumeSamples: @Sendable (AsyncStream<[Float]>) async -> Void

	/// Flushes the decoder, inserts whatever is left, and closes the session.
	var finish: @Sendable () async -> StreamingDictationResult = { .init(insertedText: "", rawTranscript: "") }

	/// Closes the session without flushing. Text already inserted stays where it
	/// is — it is in someone else's document and cannot be retracted.
	var cancel: @Sendable () async -> StreamingDictationResult = { .init(insertedText: "", rawTranscript: "") }

	var isActive: @Sendable () async -> Bool = { false }
}

extension StreamingDictationClient: DependencyKey {
	static var liveValue: Self {
		let live = StreamingDictationLive()
		return Self(
			prewarm: { await live.prewarm(modelName: $0) },
			start: { try await live.start(backend: $0, transform: $1, keepTranscriptOnClipboard: $2) },
			consumeSamples: { await live.consumeSamples($0) },
			finish: { await live.finish() },
			cancel: { await live.cancel() },
			isActive: { await live.isActive }
		)
	}

	static var testValue: Self { Self() }
}

extension DependencyValues {
	var streamingDictation: StreamingDictationClient {
		get { self[StreamingDictationClient.self] }
		set { self[StreamingDictationClient.self] = newValue }
	}
}

actor StreamingDictationLive {
	private struct Session {
		let continuation: AsyncStream<Update>.Continuation
		let consumer: Task<String, Never>
		let keepTranscriptOnClipboard: Bool
		/// False when the fragments were typed through `PasteboardClient`, in which
		/// case the clipboard inserter was never opened and must not be closed.
		let usedClipboard: Bool
		let isRemote: Bool
	}

	private enum Update: Sendable {
		case partial(String)
		case final(String)
	}

	private let asr = StreamingParakeetClient.shared
	private let remote = RemoteStreamingClient()
	private let inserter = IncrementalTextInserter()
	@Dependency(\.pasteboard) private var pasteboard
	@Shared(.hexSettings) private var hexSettings: HexSettings
	private var session: Session?
	/// Set when the recorder's marker reaches the tap consumer. Latched rather
	/// than signalled, because the marker routinely arrives before anyone waits
	/// on it — `stopRecording()` emits it and the stop path asks afterwards.
	private var sawEndOfUtterance = false

	var isActive: Bool { session != nil }

	/// Compiles and loads the encoder ahead of the first recording.
	///
	/// Only ever loads what is already on disk: a download belongs to the model
	/// settings UI, which can show progress and ask, not to a silent background
	/// task on launch.
	func prewarm(modelName: String) async {
		guard StreamingModel.isStreaming(modelName),
		      await asr.isModelAvailable(modelName),
		      await !asr.isLoaded(modelName)
		else { return }
		do {
			let start = Date()
			try await asr.ensureLoaded(modelName: modelName, progress: { _ in })
			dictationLogger.notice(
				"Streaming model prewarmed in \(String(format: "%.2f", Date().timeIntervalSince(start)))s"
			)
		} catch {
			dictationLogger.error("Streaming model prewarm failed: \(error.localizedDescription)")
		}
	}


	func start(
		backend: StreamingDictationBackend,
		transform: TranscriptTransformStack,
		keepTranscriptOnClipboard: Bool
	) async throws {
		if session != nil {
			dictationLogger.notice("Starting a streaming session over an unfinished one; cancelling the old one")
			_ = await cancel()
		}

		// Never wait for a load here. A cold CoreML compile is seconds long, and
		// the caller opens the microphone only after this returns — so waiting
		// means the recording does not start at all while the user is already
		// talking. Failing fast costs this one recording its live insertion; it
		// still records and transcribes through the batch path.
		// The caller reacts to this by kicking off a prewarm, so the next
		// recording streams and the indicator can say why this one did not.
		if case let .onDevice(modelName) = backend {
			guard await asr.isLoaded(modelName) else {
				throw StreamingDictationError.modelNotReady(modelName)
			}
		}

		let (updates, continuation) = AsyncStream<Update>.makeStream(bufferingPolicy: .unbounded)
		switch backend {
		case let .onDevice(modelName):
			try await asr.startSession(modelName: modelName) { cumulative in
				continuation.yield(.partial(cumulative))
			}
		case let .remote(url):
			// Same rule as above, for the same reason: this does not wait for
			// the connection. Samples queue inside the client until the server
			// is ready, and a server that never is surfaces in `finish`.
			await remote.startSession(url: url) { cumulative in
				continuation.yield(.partial(cumulative))
			}
		}

		sawEndOfUtterance = false
		// Same switch the batch path makes in `PasteboardClient.paste`. With paste
		// off, each fragment goes through that client and is typed as keystrokes;
		// terminals treat a Cmd+V as a bracketed paste and render every fragment
		// as its own block, which typing avoids. The clipboard inserter exists
		// only because the batch client's per-call snapshot/restore is too heavy
		// per word, so it is bypassed entirely here.
		let useClipboardPaste = hexSettings.useClipboardPaste
		let insert: @Sendable (String) async -> Bool
		if useClipboardPaste {
			await inserter.begin()
			insert = { [inserter] in await inserter.insert($0) }
		} else {
			insert = { [pasteboard] in
				await pasteboard.paste($0)
				return true
			}
		}
		let consumer = Task {
			var pipeline = StreamingTranscriptPipeline(lowercaseFirstLetter: transform.lowercaseFirstLetter)
			for await update in updates {
				let outcome: StreamingTranscriptPipeline.Outcome
				switch update {
				case let .partial(text):
					outcome = pipeline.observe(text) { transform.apply($0) }
				case let .final(text):
					outcome = pipeline.finish(text) { transform.apply($0) }
				}
				if let diagnostic = outcome.divergenceDiagnostic {
					dictationLogger.error("Streaming transcript diverged, inserting nothing: \(diagnostic, privacy: .private)")
				}
				guard !outcome.isEmpty else { continue }
				let inserted = await insert(outcome.textToInsert)
				if !inserted {
					dictationLogger.error("Dropping a dictation delta that could not be inserted")
				}
			}
			return pipeline.insertedText
		}

		session = Session(
			continuation: continuation,
			consumer: consumer,
			keepTranscriptOnClipboard: keepTranscriptOnClipboard,
			usedClipboard: useClipboardPaste,
			isRemote: backend.isRemote
		)
		dictationLogger.notice("Streaming dictation session started backend=\(String(describing: backend), privacy: .public)")
	}

	func consumeSamples(_ samples: AsyncStream<[Float]>) async {
		for await buffer in samples {
			guard let session else { continue }
			guard !buffer.isEmpty else {
				sawEndOfUtterance = true
				continue
			}
			if session.isRemote {
				await remote.append(buffer)
				continue
			}
			do {
				try await asr.append(buffer)
			} catch {
				dictationLogger.error("Streaming append failed: \(error.localizedDescription)")
			}
		}
	}

	/// Waits for the recorder's end-of-utterance marker to come through the tap.
	///
	/// Decoding runs inline on the way in, so when the encoder is busy this loop
	/// is what keeps the last second of speech from being flushed away before it
	/// is decoded. The timeout only exists so a tap that never delivers the
	/// marker — a failed or stale capture session — cannot wedge the stop path.
	private func waitForEndOfUtterance(timeout: Duration = .seconds(5)) async {
		guard !sawEndOfUtterance else { return }
		let deadline = ContinuousClock.now + timeout
		while !sawEndOfUtterance, ContinuousClock.now < deadline {
			try? await Task.sleep(for: .milliseconds(5))
		}
		if !sawEndOfUtterance {
			dictationLogger.error("Timed out waiting for the capture tap to drain; flushing anyway")
		}
	}

	func finish() async -> StreamingDictationResult {
		guard let session else { return .init(insertedText: "", rawTranscript: "") }
		await waitForEndOfUtterance()
		self.session = nil

		var rawTranscript = ""
		var failure: String?
		do {
			rawTranscript = session.isRemote
				? try await remote.finishSession()
				: try await asr.finishSession()
		} catch {
			dictationLogger.error("Streaming finish failed: \(error.localizedDescription)")
			if session.isRemote { failure = error.localizedDescription }
		}

		// Ordering: the final transcript goes through the same stream as every
		// partial, so the consumer sees it strictly after them and the flushed
		// tail lands after the last word rather than racing it.
		//
		// A failed remote session has no final. Flushing an empty one would
		// release the held-back partial word, and "stop inserting" is the whole
		// contract once the server is gone — so the stream just ends.
		if failure == nil {
			session.continuation.yield(.final(rawTranscript))
		}
		session.continuation.finish()
		let insertedText = await session.consumer.value

		if session.usedClipboard {
			await inserter.end(leaving: session.keepTranscriptOnClipboard ? insertedText : nil)
		}
		dictationLogger.notice("Streaming dictation session finished, inserted \(insertedText.count) characters")
		return .init(insertedText: insertedText, rawTranscript: rawTranscript, failure: failure)
	}

	func cancel() async -> StreamingDictationResult {
		guard let session else { return .init(insertedText: "", rawTranscript: "") }
		self.session = nil

		// No `.final`: cancelling must not insert the held-back partial word.
		session.continuation.finish()
		let insertedText = await session.consumer.value
		if session.isRemote {
			await remote.cancelSession()
		} else {
			await asr.cancelSession()
		}
		if session.usedClipboard {
			await inserter.end(leaving: session.keepTranscriptOnClipboard ? insertedText : nil)
		}
		dictationLogger.notice("Streaming dictation session cancelled after \(insertedText.count) characters")
		return .init(insertedText: insertedText, rawTranscript: "")
	}
}
