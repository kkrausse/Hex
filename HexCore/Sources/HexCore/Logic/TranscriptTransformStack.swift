import Foundation

/// The word-level transforms Hex applies to a transcript before it is inserted,
/// in the order the batch path has always applied them.
///
/// Extracted so the streaming path cannot drift from the batch path. Streaming
/// runs these over each released span rather than over the whole transcript, so
/// every stage here must be position independent — true of all three, which
/// match on `(?<!\w)…(?!\w)` word boundaries or operate per character.
public struct TranscriptTransformStack: Sendable {
	public enum Stage: Equatable, Sendable {
		case removals
		case remappings
		case formatting
	}

	public let removalsEnabled: Bool
	public let removals: [WordRemoval]
	public let remappings: [WordRemapping]
	public let lowercase: Bool
	public let removePunctuation: Bool
	/// Lowercase the first letter of the whole transcript. Unlike every other
	/// stage this is position *dependent*, so `apply` deliberately does not run
	/// it: the batch path uses `applyToWholeTranscript`, and the streaming path
	/// lets `StreamingTranscriptPipeline` do it once, on the first released span.
	public let lowercaseFirstLetter: Bool

	public init(
		removalsEnabled: Bool,
		removals: [WordRemoval],
		remappings: [WordRemapping],
		lowercase: Bool,
		removePunctuation: Bool,
		lowercaseFirstLetter: Bool = false
	) {
		self.removalsEnabled = removalsEnabled
		self.removals = removals
		self.remappings = remappings
		self.lowercase = lowercase
		self.removePunctuation = removePunctuation
		self.lowercaseFirstLetter = lowercaseFirstLetter
	}

	/// A stack that changes nothing, for the scratchpad case where the user is
	/// dictating the remapping rules themselves.
	public static let identity = TranscriptTransformStack(
		removalsEnabled: false,
		removals: [],
		remappings: [],
		lowercase: false,
		removePunctuation: false
	)

	/// The position-independent stages only. Safe to run on any span of the
	/// transcript; what the streaming path calls per released word.
	public func apply(_ text: String) -> String {
		apply(text, onStageChange: { _ in })
	}

	/// Every stage, including the position-dependent first-letter one. Only
	/// correct when `text` is the complete transcript.
	public func applyToWholeTranscript(_ text: String, onStageChange: (Stage) -> Void = { _ in }) -> String {
		var output = apply(text, onStageChange: onStageChange)
		if lowercaseFirstLetter {
			let lowered = TranscriptFormattingApplier.lowercasingFirstLetter(output)
			if lowered != output { onStageChange(.formatting) }
			output = lowered
		}
		return output
	}

	/// - Parameter onStageChange: Called with each stage that actually altered the
	///   text. The batch path uses this for its per-stage logging; the streaming
	///   path runs per word and would make that logging useless noise, so it
	///   passes nothing.
	public func apply(_ text: String, onStageChange: (Stage) -> Void) -> String {
		var output = text

		if removalsEnabled {
			let removed = WordRemovalApplier.apply(output, removals: removals)
			if removed != output { onStageChange(.removals) }
			output = removed
		}

		let remapped = WordRemappingApplier.apply(output, remappings: remappings)
		if remapped != output { onStageChange(.remappings) }
		output = remapped

		let formatted = TranscriptFormattingApplier.apply(
			output,
			lowercase: lowercase,
			removePunctuation: removePunctuation
		)
		if formatted != output { onStageChange(.formatting) }
		output = formatted

		return output
	}
}
