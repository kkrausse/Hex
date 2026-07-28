import Foundation

/// Streaming-capable ASR models this fork supports.
///
/// Distinct from `ParakeetModel`, which lists the batch Parakeet TDT bundles
/// upstream uses. Those run an offline encoder over a finished recording; these
/// keep decoder state across microphone callbacks and emit a growing transcript
/// while the user is still talking.
///
/// The raw value doubles as `HexSettings.selectedModel`, so it must stay stable
/// once written to disk.
public enum StreamingModel: String, CaseIterable, Sendable {
	/// Parakeet Unified 0.6B at the 1120 ms tier: 0.56 s chunk + 0.56 s right
	/// context. Chosen as the fork's default because FluidAudio measures it as
	/// both lower latency *and* lower WER than the 2080 ms tier on test-clean.
	case parakeetUnified1120ms = "parakeet-unified-en-0.6b-streaming-1120ms"

	public var identifier: String { rawValue }

	/// Matches `StreamingModelVariant.rawValue` in FluidAudio. Kept as a string
	/// so HexCore does not have to link FluidAudio; the client maps it back.
	public var fluidVariantRawValue: String {
		switch self {
		case .parakeetUnified1120ms: return "parakeet-unified-1120ms"
		}
	}

	/// `[left, chunk, right]` attention context in encoder frames. Baked into the
	/// encoder at conversion time, so each tier is a separate download and a
	/// separate `UnifiedConfig`.
	public var attentionContext: (left: Int, chunk: Int, right: Int) {
		switch self {
		case .parakeetUnified1120ms: return (70, 7, 7)
		}
	}

	/// The context as it appears in the encoder's filename.
	public var contextSuffix: String {
		let context = attentionContext
		return "\(context.left)_\(context.chunk)_\(context.right)"
	}

	/// Cache folder under `…/Application Support/FluidAudio/Models/`.
	/// Mirrors FluidAudio's `Repo.folderName`, which strips the `-coreml` suffix.
	public var cacheFolderName: String {
		switch self {
		case .parakeetUnified1120ms: return "parakeet-unified-en-0.6b"
		}
	}

	public var displayName: String {
		switch self {
		case .parakeetUnified1120ms: return "Parakeet Unified (Streaming)"
		}
	}

	/// Whether `name` refers to a streaming model rather than a batch one.
	public static func isStreaming(_ name: String) -> Bool {
		StreamingModel(rawValue: name) != nil
	}
}
