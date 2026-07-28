import AVFoundation
import Foundation
import HexCore

#if canImport(FluidAudio)
import FluidAudio

/// Owns the FluidAudio streaming ASR manager: download, load, and cache checks.
///
/// Deliberately separate from `ParakeetClient`, which drives the batch
/// `AsrManager.transcribe(url:)` path. The two have incompatible shapes — batch
/// takes a finished file and returns one string, streaming holds decoder state
/// across audio callbacks — so they stay as sibling clients rather than one
/// client with a mode flag.
actor StreamingParakeetClient {
	/// One decoder for the whole app.
	///
	/// Two owners need the *same* loaded encoder: `TranscriptionClientLive`,
	/// which downloads and loads it for the model settings UI, and
	/// `StreamingDictationLive`, which opens live sessions against it. Separate
	/// instances would mean a second ~650 MB download and a second copy resident
	/// in memory, and a session opened against one would not see the other's
	/// loaded model.
	static let shared = StreamingParakeetClient()

	// Held concretely rather than as `any StreamingAsrManager`: the protocol's
	// loadModels() takes no progress handler, and this is a ~650 MB download that
	// must not look frozen. Widen back to the protocol when a second engine
	// family (Nemotron, EOU) is actually supported.
	private var manager: StreamingUnifiedAsrManager?
	private var loadedModel: StreamingModel?
	/// The load currently in flight, so concurrent callers share it instead of
	/// each starting their own. See `ensureLoaded`.
	private var loadTask: Task<Void, Error>?
	private let logger = HexLog.parakeet

	/// The loaded manager, or nil if `ensureLoaded` has not run for this model.
	func loadedManager(for model: StreamingModel) -> StreamingUnifiedAsrManager? {
		guard loadedModel == model else { return nil }
		return manager
	}

	/// Whether this variant is loaded in memory *right now* and can open a
	/// session without waiting. Distinct from `isModelAvailable`, which only says
	/// the bytes are on disk — the CoreML compile between the two takes seconds.
	func isLoaded(_ modelName: String) -> Bool {
		guard let model = StreamingModel(rawValue: modelName) else { return false }
		return loadedModel == model && manager != nil
	}

	/// Whether this variant's encoder is already on disk.
	///
	/// Checks the same specific file `StreamingUnifiedAsrManager.loadModels()`
	/// checks before deciding to download. Each latency tier bakes its
	/// `[left, chunk, right]` context into a distinct encoder bundle, so a
	/// folder-level check would wrongly report a different tier as this one.
	func isModelAvailable(_ modelName: String) async -> Bool {
		guard let model = StreamingModel(rawValue: modelName) else { return false }
		if loadedModel == model, manager != nil { return true }

		let encoderPath = Self.encoderPath(for: model)
		let available = FileManager.default.fileExists(atPath: encoderPath.path)
		if available {
			logger.notice("Found streaming encoder at \(encoderPath.path)")
		} else {
			logger.debug("No streaming encoder cached at \(encoderPath.path)")
		}
		return available
	}

	/// Downloads (if needed) and loads the model, reporting 0–100 progress.
	///
	/// Concurrent callers share one load. Actor isolation alone does not give
	/// that: `loadModels` suspends, and a suspended actor lets the next call in,
	/// which would find `loadedModel` still unset and start a second ~650 MB
	/// download and a second CoreML compile. The app has three callers that can
	/// legitimately race here — the settings UI, the launch prewarm, and the
	/// first recording — so this is the normal case, not an edge one.
	func ensureLoaded(
		modelName: String,
		progress: @escaping @Sendable (Progress) -> Void
	) async throws {
		guard let model = StreamingModel(rawValue: modelName) else {
			throw NSError(
				domain: "StreamingParakeet",
				code: -1,
				userInfo: [
					NSLocalizedDescriptionKey: "Unsupported streaming model: \(modelName)",
				]
			)
		}
		if loadedModel == model, manager != nil {
			reportComplete(to: progress)
			return
		}

		// Join a load already in flight rather than starting a second one. Its
		// progress goes to whoever asked first; latecomers just get completion.
		if let inFlight = loadTask {
			logger.debug("Joining an in-flight streaming model load")
			_ = try? await inFlight.value
			if loadedModel == model, manager != nil {
				reportComplete(to: progress)
				return
			}
		}

		let task = Task<Void, Error> { [weak self] in
			guard let self else { return }
			try await self.load(model: model, progress: progress)
		}
		loadTask = task
		defer { loadTask = nil }
		try await task.value
	}

	private func reportComplete(to progress: @escaping @Sendable (Progress) -> Void) {
		// Callers drive a progress UI off this closure, so returning silently
		// leaves it stuck at whatever fraction it last saw.
		let done = Progress(totalUnitCount: 100)
		done.completedUnitCount = 100
		progress(done)
	}

	private func load(
		model: StreamingModel,
		progress: @escaping @Sendable (Progress) -> Void
	) async throws {
		// Drop any previously loaded variant before pulling a new one in, so two
		// 0.6B encoders are never resident at once.
		manager = nil
		loadedModel = nil

		let overall = Progress(totalUnitCount: 100)
		overall.completedUnitCount = 0
		progress(overall)

		let start = Date()
		logger.notice("Loading streaming model \(model.identifier)")

		let context = model.attentionContext
		let created = StreamingUnifiedAsrManager(
			config: UnifiedConfig(
				leftFrames: context.left,
				chunkFrames: context.chunk,
				rightFrames: context.right
			)
		)
		// FluidAudio reports real byte-weighted download progress, so unlike the
		// batch Parakeet path there is no need to poll the directory size.
		try await created.loadModels(progressHandler: { update in
			overall.completedUnitCount = Int64(max(0, min(1, update.fractionCompleted)) * 100)
			progress(overall)
		})

		manager = created
		loadedModel = model
		overall.completedUnitCount = 100
		progress(overall)
		logger.notice(
			"Streaming model ready in \(String(format: "%.2f", Date().timeIntervalSince(start)))s"
		)
	}

	/// Transcribes a finished recording by pushing it through the streaming
	/// manager in one go.
	///
	/// Interim path. Live incremental transcription is the actual goal, but that
	/// needs a tap on the capture engine; until then this makes the streaming
	/// model genuinely usable and exercises the same load/decode/finish sequence
	/// the live path will use, so a failure here is a real failure rather than
	/// something deferred to integration time.
	func transcribe(_ url: URL, modelName: String) async throws -> String {
		guard let model = StreamingModel(rawValue: modelName),
		      loadedModel == model,
		      let manager
		else {
			throw NSError(
				domain: "StreamingParakeet",
				code: -4,
				userInfo: [NSLocalizedDescriptionKey: "Streaming model not loaded"]
			)
		}

		let file = try AVAudioFile(forReading: url)
		guard let buffer = AVAudioPCMBuffer(
			pcmFormat: file.processingFormat,
			frameCapacity: AVAudioFrameCount(file.length)
		) else {
			throw NSError(
				domain: "StreamingParakeet",
				code: -5,
				userInfo: [NSLocalizedDescriptionKey: "Could not allocate a read buffer"]
			)
		}
		try file.read(into: buffer)

		// Reset first: the manager holds decoder state across calls, so without
		// this a second recording would be decoded as a continuation of the first.
		try await manager.reset()
		try await manager.appendAudio(buffer)
		try await manager.processBufferedAudio()
		let text = try await manager.finish()
		try await manager.reset()
		return text.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	// MARK: - Live streaming session

	/// Opens a live session, replacing any previous one.
	///
	/// `onPartial` receives the manager's **cumulative** transcript, not a delta —
	/// FluidAudio rebuilds the whole string each time tokens are emitted. Turning
	/// that into insertable deltas is the caller's job, via
	/// `AppendOnlyTranscriptCursor`.
	func startSession(
		modelName: String,
		onPartial: @escaping @Sendable (String) -> Void
	) async throws {
		guard let model = StreamingModel(rawValue: modelName),
		      loadedModel == model,
		      let manager
		else {
			throw NSError(
				domain: "StreamingParakeet",
				code: -6,
				userInfo: [NSLocalizedDescriptionKey: "Streaming model not loaded"]
			)
		}
		// Decoder state persists across sessions, so a missing reset would decode
		// this utterance as a continuation of the previous one.
		try await manager.reset()
		await manager.setPartialTranscriptCallback(onPartial)
	}

	/// Feeds captured audio to the decoder and lets it emit any complete windows.
	func append(_ samples: [Float]) async throws {
		guard let manager else { return }
		try await manager.appendAudio(Self.makeBuffer(samples))
		try await manager.processBufferedAudio()
	}

	/// Flushes remaining audio and returns the final cumulative transcript.
	///
	/// `padMilliseconds` appends silence first. Without it the last word ends
	/// flush against the final encoder window, where the RNN-T decoder can
	/// withhold its trailing emissions — during normal speech the decoder always
	/// has trailing audio, so it never sees this case until the stream stops.
	///
	/// Returned verbatim, unlike `transcribe`: FluidAudio already trims this
	/// string the same way it trims every partial, and trimming it again here
	/// could make the final transcript stop being an extension of the last
	/// partial — which is exactly the append-only invariant the caller's cursor
	/// checks, and a violation means the flushed tail is dropped.
	func finishSession(padMilliseconds: Int = 400) async throws -> String {
		guard let manager else { return "" }
		// Silence the partial callback first. `finish()` decodes the last windows
		// and fires the callback for their emissions, and the string it then
		// returns already contains that text — so leaving the callback installed
		// delivers the tail twice, microseconds apart. The caller inserts each
		// arrival into a live document, and two pastes that close together race:
		// the second overwrites the clipboard before the target app has serviced
		// the first, and the last word lands twice.
		await manager.setPartialTranscriptCallback { _ in }
		if padMilliseconds > 0 {
			let padSamples = [Float](repeating: 0, count: padMilliseconds * 16)
			try await manager.appendAudio(Self.makeBuffer(padSamples))
			try await manager.processBufferedAudio()
		}
		let text = try await manager.finish()
		try await manager.reset()
		return text
	}

	/// Abandons the session without producing a transcript.
	func cancelSession() async {
		guard let manager else { return }
		await manager.setPartialTranscriptCallback { _ in }
		try? await manager.reset()
	}

	private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer {
		// The capture path already converts to this exact format, so the buffer is
		// handed over without resampling.
		let format = AVAudioFormat(
			commonFormat: .pcmFormatFloat32,
			sampleRate: 16_000,
			channels: 1,
			interleaved: false
		)!
		let buffer = AVAudioPCMBuffer(
			pcmFormat: format,
			frameCapacity: AVAudioFrameCount(max(1, samples.count))
		)!
		buffer.frameLength = AVAudioFrameCount(samples.count)
		if let channel = buffer.floatChannelData, !samples.isEmpty {
			samples.withUnsafeBufferPointer { source in
				channel[0].update(from: source.baseAddress!, count: samples.count)
			}
		}
		return buffer
	}

	/// Removes this variant's cached encoder and unloads it.
	///
	/// Every tier shares one folder — and one decoder, joint network, and
	/// vocabulary — differing only by encoder file. So this deletes the encoder,
	/// and takes the shared files with it only once no other tier is still using
	/// them. Removing the whole folder unconditionally would delete a tier the
	/// user never asked to remove, and cost them a 650 MB re-download.
	func deleteCaches(modelName: String) async throws {
		guard let model = StreamingModel(rawValue: modelName) else { return }
		let fileManager = FileManager.default
		let directory = Self.cacheDirectory(for: model)

		let encoder = Self.encoderPath(for: model)
		if fileManager.fileExists(atPath: encoder.path) {
			try fileManager.removeItem(at: encoder)
			logger.notice("Deleted streaming encoder at \(encoder.path)")
		}

		let remainingTiers = StreamingModel.allCases
			.filter { $0 != model && $0.cacheFolderName == model.cacheFolderName }
			.filter { fileManager.fileExists(atPath: Self.encoderPath(for: $0).path) }

		if remainingTiers.isEmpty {
			if fileManager.fileExists(atPath: directory.path) {
				try fileManager.removeItem(at: directory)
				logger.notice("Deleted the shared streaming model cache at \(directory.path)")
			}
		} else {
			logger.notice(
				"Kept the shared streaming model files: \(remainingTiers.count) other tier(s) still installed"
			)
		}
		if loadedModel == model {
			await manager?.cleanup()
			manager = nil
			loadedModel = nil
		}
	}

	/// Directory holding this model's bundle, honoring the same Application
	/// Support root FluidAudio uses. In the SPM executable build there is no
	/// sandbox container, so this resolves to the shared
	/// `~/Library/Application Support/FluidAudio/Models/…` that other FluidAudio
	/// apps already populate — an existing download is reused rather than refetched.
	static func cacheDirectory(for model: StreamingModel) -> URL {
		let base = FileManager.default
			.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
		return base
			.appendingPathComponent("FluidAudio", isDirectory: true)
			.appendingPathComponent("Models", isDirectory: true)
			.appendingPathComponent(model.cacheFolderName, isDirectory: true)
	}

	static func encoderPath(for model: StreamingModel) -> URL {
		// `.int8` matches StreamingUnifiedAsrManager's default encoderPrecision.
		let encoderFile = ModelNames.ParakeetUnified.streamingEncoderFile(
			precision: .int8,
			contextSuffix: model.contextSuffix
		)
		return cacheDirectory(for: model).appendingPathComponent(encoderFile)
	}
}

#else

actor StreamingParakeetClient {
	static let shared = StreamingParakeetClient()

	func isModelAvailable(_: String) async -> Bool { false }
	func isLoaded(_: String) -> Bool { false }
	func ensureLoaded(modelName _: String, progress _: @escaping @Sendable (Progress) -> Void) async throws {
		throw Self.notLinked
	}
	func deleteCaches(modelName _: String) async throws {}
	func transcribe(_: URL, modelName _: String) async throws -> String { throw Self.notLinked }
	func startSession(modelName _: String, onPartial _: @escaping @Sendable (String) -> Void) async throws {
		throw Self.notLinked
	}
	func append(_: [Float]) async throws {}
	func finishSession(padMilliseconds _: Int = 400) async throws -> String { "" }
	func cancelSession() async {}

	private static let notLinked = NSError(
		domain: "StreamingParakeet",
		code: -3,
		userInfo: [NSLocalizedDescriptionKey: "FluidAudio is not linked."]
	)
}

#endif
