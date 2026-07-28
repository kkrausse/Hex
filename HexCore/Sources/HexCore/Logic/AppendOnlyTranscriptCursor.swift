import Foundation

/// One observation of the streaming transcript.
public struct CursorUpdate: Equatable, Sendable {
	public enum Kind: Equatable, Sendable {
		/// Nothing new to insert.
		case ignored
		/// `textToInsert` extends what was already inserted.
		case appended
		/// The model revised text it had already emitted. Nothing is inserted.
		case divergence
	}

	public let kind: Kind
	public let textToInsert: String
	public let cumulativeText: String
	public let isFinal: Bool
	public let diagnostic: String?
}

/// Converts a cumulative streaming transcript into deltas that are safe to paste.
///
/// FluidAudio's partial callback hands back the whole transcript each time, but
/// text has already been pasted into another application, where it cannot be
/// retracted. So the only safe delta is a strict suffix.
///
/// Parakeet Unified decodes an append-only RNN-T token stream, so each callback
/// should have the previous one as a prefix. This type verifies that rather than
/// assuming it: if the invariant ever breaks, it reports `.divergence` and
/// inserts nothing, leaving the caller to surface the discrepancy. Guessing at a
/// correction would mean editing text in someone else's document.
public struct AppendOnlyTranscriptCursor: Sendable {
	public private(set) var observedText = ""

	public init() {}

	public mutating func observe(_ cumulative: String, isFinal: Bool) -> CursorUpdate {
		guard !cumulative.isEmpty else {
			return CursorUpdate(
				kind: .ignored,
				textToInsert: "",
				cumulativeText: cumulative,
				isFinal: isFinal,
				diagnostic: nil
			)
		}

		guard cumulative.hasPrefix(observedText) else {
			return CursorUpdate(
				kind: .divergence,
				textToInsert: "",
				cumulativeText: cumulative,
				isFinal: isFinal,
				diagnostic: "append-only prefix violation: had "
					+ "\(String(reflecting: observedText)), received \(String(reflecting: cumulative))"
			)
		}

		let suffix = String(cumulative.dropFirst(observedText.count))
		observedText = cumulative

		if suffix.isEmpty {
			return CursorUpdate(
				kind: .ignored,
				textToInsert: "",
				cumulativeText: cumulative,
				isFinal: isFinal,
				diagnostic: nil
			)
		}

		return CursorUpdate(
			kind: .appended,
			textToInsert: suffix,
			cumulativeText: cumulative,
			isFinal: isFinal,
			diagnostic: nil
		)
	}

	public mutating func reset() {
		observedText = ""
	}
}
