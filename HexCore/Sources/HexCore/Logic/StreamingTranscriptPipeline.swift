import Foundation

/// Turns the cumulative transcript a streaming recognizer emits into ordered,
/// transformed spans that are safe to insert into another application.
///
/// Composes the two halves that already exist:
/// `AppendOnlyTranscriptCursor` (cumulative → strict-suffix delta, refusing to
/// guess when the model revises itself) and `StreamingTextTransformer` (delta →
/// whole words, with Hex's transforms applied). It also remembers everything it
/// handed back, which is the only record of what actually landed in the user's
/// document — the recognizer's own final transcript is not, because the tail may
/// never have been released.
public struct StreamingTranscriptPipeline: Sendable {
	/// What the caller should do with one observation.
	public struct Outcome: Equatable, Sendable {
		/// Text to insert now. Empty when the observation completed no words.
		public let textToInsert: String
		/// Set when the recognizer contradicted text it had already emitted.
		/// Nothing is inserted for the contradicting part; the caller should log
		/// it. Both fields can be populated at once: held-back text from earlier,
		/// valid observations is still released.
		public let divergenceDiagnostic: String?

		public var isEmpty: Bool { textToInsert.isEmpty }

		static let nothing = Outcome(textToInsert: "", divergenceDiagnostic: nil)
	}

	private var cursor = AppendOnlyTranscriptCursor()
	private var transformer = StreamingTextTransformer()

	/// Everything this pipeline has released for insertion, concatenated.
	///
	/// This — not the recognizer's transcript — is what belongs in history, so
	/// the entry matches what the user is looking at in their document.
	public private(set) var insertedText = ""

	public init() {}

	/// Text received but not yet released, always at most one partial word.
	public var pendingText: String { transformer.pendingText }

	/// Absorbs a partial (cumulative) transcript.
	public mutating func observe(
		_ cumulative: String,
		transform: (String) -> String
	) -> Outcome {
		let update = cursor.observe(cumulative, isFinal: false)
		switch update.kind {
		case .ignored:
			return .nothing
		case .divergence:
			return Outcome(textToInsert: "", divergenceDiagnostic: update.diagnostic)
		case .appended:
			return record(transformer.consume(update.textToInsert, transform: transform))
		}
	}

	/// Absorbs the recognizer's final transcript and releases the held-back tail.
	///
	/// The final string is normally identical to the last partial — the flush is
	/// what matters, since the last word of an utterance is by definition never
	/// followed by the whitespace the transformer waits for.
	public mutating func finish(
		_ cumulative: String,
		transform: (String) -> String
	) -> Outcome {
		var diagnostic: String?
		var released = ""

		let update = cursor.observe(cumulative, isFinal: true)
		switch update.kind {
		case .appended:
			released += transformer.consume(update.textToInsert, transform: transform)
		case .divergence:
			diagnostic = update.diagnostic
		case .ignored:
			break
		}

		released += transformer.flush(transform: transform)
		return record(released, diagnostic: diagnostic)
	}

	/// Ends the session without releasing the held-back tail.
	///
	/// Cancelling cannot retract what is already in the document, so the pending
	/// partial word is dropped rather than completing a word the user asked to
	/// stop mid-way through. Returns what was actually inserted.
	public mutating func cancel() -> String {
		transformer.reset()
		return insertedText
	}

	public mutating func reset() {
		cursor.reset()
		transformer.reset()
		insertedText = ""
	}

	private mutating func record(_ text: String, diagnostic: String? = nil) -> Outcome {
		insertedText += text
		return Outcome(textToInsert: text, divergenceDiagnostic: diagnostic)
	}
}
