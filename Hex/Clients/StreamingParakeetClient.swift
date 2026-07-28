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
	// Held concretely rather than as `any StreamingAsrManager`: the protocol's
	// loadModels() takes no progress handler, and this is a ~650 MB download that
	// must not look frozen. Widen back to the protocol when a second engine
	// family (Nemotron, EOU) is actually supported.
	private var manager: StreamingUnifiedAsrManager?
	private var loadedModel: StreamingModel?
	private let logger = HexLog.parakeet

	/// The loaded manager, or nil if `ensureLoaded` has not run for this model.
	func loadedManager(for model: StreamingModel) -> StreamingUnifiedAsrManager? {
		guard loadedModel == model else { return nil }
		return manager
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
			// Still report completion. Callers drive a progress UI off this
			// closure, so returning silently leaves it stuck at whatever fraction
			// it last saw.
			let done = Progress(totalUnitCount: 100)
			done.completedUnitCount = 100
			progress(done)
			return
		}

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

	/// Removes the cached bundle for this variant and unloads it.
	func deleteCaches(modelName: String) async throws {
		guard let model = StreamingModel(rawValue: modelName) else { return }
		let directory = Self.cacheDirectory(for: model)

		if FileManager.default.fileExists(atPath: directory.path) {
			try FileManager.default.removeItem(at: directory)
			logger.notice("Deleted streaming model cache at \(directory.path)")
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
	func isModelAvailable(_: String) async -> Bool { false }
	func ensureLoaded(modelName _: String, progress _: @escaping @Sendable (Progress) -> Void) async throws {
		throw NSError(
			domain: "StreamingParakeet",
			code: -3,
			userInfo: [NSLocalizedDescriptionKey: "FluidAudio is not linked."]
		)
	}
	func deleteCaches(modelName _: String) async throws {}
}

#endif
