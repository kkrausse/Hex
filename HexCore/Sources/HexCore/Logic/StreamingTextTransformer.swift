import Foundation

/// Applies Hex's text transforms to an incrementally-arriving transcript.
///
/// Streaming ASR hands us cumulative text that grows by whatever subword tokens
/// the decoder emitted for the latest window, so a delta can end in the middle
/// of a word. That matters because the transforms are word-oriented:
/// `WordRemappingApplier` matches on `(?<!\w)…(?!\w)` boundaries. Given the
/// remapping `comma → ","` and the spoken word "commanding", a delta that
/// happens to break as `" comma"` + `"nding"` would otherwise be rewritten to
/// `",nding"` — silent corruption in already-pasted text, which cannot be
/// walked back.
///
/// The fix is to move the boundary off the delta and onto whitespace: buffer
/// incoming text, release only the part up to the last space, and hold the
/// trailing (possibly incomplete) word until more text arrives or the stream
/// ends. Steady state is one word behind; `flush()` releases the remainder, so
/// nothing is lost when the user releases the hotkey.
///
/// **The separating whitespace is held back with the next word, not emitted
/// with the previous one** — releases look like `"hello"`, `" world"`,
/// `" there"` rather than `"hello "`, `"world "`. Each release is pasted into
/// the focused app as its own fragment, and rich-text editors routinely trim
/// whitespace at the edges of a pasted fragment. Slack's composer trims a
/// trailing space and keeps a leading one (verified by hand), so a trailing
/// space is silently dropped and the words arrive glued together as
/// `"helloworld"`. Leading whitespace survives, so that is where it goes. The
/// concatenation is identical either way; only the fragment boundaries move.
///
/// Known limitation, accepted deliberately: a remapping whose *match* spans a
/// space (`"new line" → "\n"`) will not fire when the words land in different
/// deltas. Handling that needs multi-word lookahead, which is out of scope.
public struct StreamingTextTransformer: Sendable {
	/// Text received but not yet safe to emit — everything after the last space.
	private var pending: String = ""

	public init() {}

	/// Text held back so far. Exposed for diagnostics and tests.
	public var pendingText: String { pending }

	/// Absorbs a delta and returns the text that is now safe to insert.
	///
	/// - Parameters:
	///   - delta: New characters appended to the cumulative transcript.
	///   - transform: Applied to complete words only. Runs on each released
	///     span rather than the whole transcript, so it must be position
	///     independent — true of the word-level transforms Hex applies.
	/// - Returns: Transformed text ready to insert, or `""` when the delta did
	///   not complete a word.
	public mutating func consume(
		_ delta: String,
		transform: (String) -> String
	) -> String {
		guard !delta.isEmpty else { return "" }
		pending += delta

		// Release up to the final whitespace: everything before it is made of
		// words the decoder can no longer extend.
		guard let lastBreak = pending.lastIndex(where: { $0.isWhitespace }) else {
			return ""
		}

		// Then back up over the whole run of whitespace that break belongs to, so
		// the released text ends on a word character and the separator stays with
		// the word it precedes. See the type's doc comment for why that matters.
		var releaseEnd = lastBreak
		while releaseEnd > pending.startIndex {
			let previous = pending.index(before: releaseEnd)
			guard pending[previous].isWhitespace else { break }
			releaseEnd = previous
		}

		// Nothing but whitespace so far — hold it for the word it will precede.
		guard releaseEnd > pending.startIndex else { return "" }

		let ready = String(pending[..<releaseEnd])
		pending = String(pending[releaseEnd...])
		return transform(ready)
	}

	/// Releases any held text. Call when the stream ends so the final word,
	/// which by definition is never followed by whitespace, still lands.
	public mutating func flush(transform: (String) -> String) -> String {
		guard !pending.isEmpty else { return "" }
		let remainder = pending
		pending = ""
		return transform(remainder)
	}

	/// Drops held text without emitting it, for a cancelled session.
	public mutating func reset() {
		pending = ""
	}
}
