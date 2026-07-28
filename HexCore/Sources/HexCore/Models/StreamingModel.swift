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
	/// context. The fork's default: FluidAudio measures it as both lower latency
	/// *and* lower WER than the 2080 ms tier on test-clean (2.25% vs 2.47%).
	case parakeetUnified1120ms = "parakeet-unified-en-0.6b-streaming-1120ms"

	/// The same weights at the 2080 ms tier: 1.04 s chunk + 1.04 s right context.
	/// Slightly worse WER and twice the lag before a word appears, but a big
	/// chunk re-encodes far less often — 54x realtime against the 1120 ms tier's
	/// 33x. Worth having on a machine where the encoder is the bottleneck.
	case parakeetUnified2080ms = "parakeet-unified-en-0.6b-streaming-2080ms"

	public var identifier: String { rawValue }

	/// Matches `StreamingModelVariant.rawValue` in FluidAudio. Kept as a string
	/// so HexCore does not have to link FluidAudio; the client maps it back.
	public var fluidVariantRawValue: String {
		switch self {
		case .parakeetUnified1120ms: return "parakeet-unified-1120ms"
		case .parakeetUnified2080ms: return "parakeet-unified-2080ms"
		}
	}

	/// `[left, chunk, right]` attention context in encoder frames. Baked into the
	/// encoder at conversion time, so each tier is a separate encoder file and a
	/// separate `UnifiedConfig` — but the same 0.6B checkpoint, re-exported with
	/// a different attention mask.
	public var attentionContext: (left: Int, chunk: Int, right: Int) {
		switch self {
		case .parakeetUnified1120ms: return (70, 7, 7)
		case .parakeetUnified2080ms: return (70, 13, 13)
		}
	}

	/// Latency in milliseconds: `(chunk + right) × 80 ms` per encoder frame.
	public var latencyMilliseconds: Int {
		let context = attentionContext
		return (context.chunk + context.right) * 80
	}

	/// The context as it appears in the encoder's filename.
	public var contextSuffix: String {
		let context = attentionContext
		return "\(context.left)_\(context.chunk)_\(context.right)"
	}

	/// Cache folder under `…/Application Support/FluidAudio/Models/`.
	/// Mirrors FluidAudio's `Repo.folderName`, which strips the `-coreml` suffix.
	///
	/// **Shared by every tier.** They differ only by which encoder file they use;
	/// the decoder, joint network, and vocabulary are one copy for all of them.
	/// So switching tiers downloads one encoder, not another 650 MB — and
	/// deleting a tier must not delete the folder out from under the others.
	public var cacheFolderName: String {
		switch self {
		case .parakeetUnified1120ms, .parakeetUnified2080ms: return "parakeet-unified-en-0.6b"
		}
	}

	public var displayName: String {
		switch self {
		case .parakeetUnified1120ms: return "Parakeet Streaming (1.1s)"
		case .parakeetUnified2080ms: return "Parakeet Streaming (2.1s)"
		}
	}

	/// Whether `name` refers to a streaming model rather than a batch one.
	public static func isStreaming(_ name: String) -> Bool {
		StreamingModel(rawValue: name) != nil
	}
}
