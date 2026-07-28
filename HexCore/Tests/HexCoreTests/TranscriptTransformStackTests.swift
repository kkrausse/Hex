import Testing
@testable import HexCore

/// The stack exists so the streaming and batch paths cannot drift apart. These
/// pin the order and the reporting the batch path's logging depends on.
struct TranscriptTransformStackTests {
	@Test
	func removalsRunBeforeRemappingsWhichRunBeforeFormatting() {
		// "uh" is removed, then "comma" becomes ",", and only then is the result
		// lowercased. Reversing any pair changes the output.
		let stack = TranscriptTransformStack(
			removalsEnabled: true,
			removals: [WordRemoval(pattern: "uh")],
			remappings: [WordRemapping(match: "comma", replacement: ",")],
			lowercase: true,
			removePunctuation: false
		)

		#expect(stack.apply("Uh Hello comma World") == "hello , world")
	}

	@Test
	func removalsAreSkippedWhenDisabled() {
		let stack = TranscriptTransformStack(
			removalsEnabled: false,
			removals: [WordRemoval(pattern: "uh")],
			remappings: [],
			lowercase: false,
			removePunctuation: false
		)

		#expect(stack.apply("uh hello") == "uh hello")
	}

	@Test
	func onlyStagesThatChangedTheTextAreReported() {
		let stack = TranscriptTransformStack(
			removalsEnabled: true,
			removals: [WordRemoval(pattern: "uh")],
			remappings: [WordRemapping(match: "comma", replacement: ",")],
			lowercase: true,
			removePunctuation: false
		)

		var stages: [TranscriptTransformStack.Stage] = []
		_ = stack.apply("Hello comma", onStageChange: { stages.append($0) })

		// No "uh" to remove; the remapping and the lowercasing both bite.
		#expect(stages == [.remappings, .formatting])
	}

	@Test
	func identityChangesNothing() {
		#expect(TranscriptTransformStack.identity.apply("Hello, World.") == "Hello, World.")
	}

	// MARK: - Applying the stack per word

	/// Streaming releases one whitespace-terminated span at a time, so each span
	/// keeps its own trailing space. This mirrors `StreamingTextTransformer`.
	private static func perSpan(_ text: String, _ stack: TranscriptTransformStack) -> String {
		var spans: [String] = []
		var current = ""
		for character in text {
			current.append(character)
			if character.isWhitespace {
				spans.append(current)
				current = ""
			}
		}
		if !current.isEmpty { spans.append(current) }
		return spans.map { stack.apply($0) }.joined()
	}

	@Test
	func applyingPerWordMatchesApplyingToTheWholeTranscript() {
		let stack = TranscriptTransformStack(
			removalsEnabled: true,
			removals: [WordRemoval(pattern: "um")],
			remappings: [WordRemapping(match: "period", replacement: ".")],
			lowercase: true,
			removePunctuation: false
		)

		let whole = "Testing um one period Two"
		#expect(stack.apply(whole) == "testing one . two")
		#expect(Self.perSpan(whole, stack) == "testing one . two")
	}

	/// Documents a known, accepted divergence rather than asserting parity.
	///
	/// `WordRemovalApplier.cleanup` tidies whitespace *around* the text it
	/// deleted — pulling a following comma back onto the previous word. Streaming
	/// hands it one span at a time, so it never sees the two sides together and
	/// the tidy-up cannot fire. The words are identical either way; only the
	/// spacing before punctuation differs, and only when a removal sits directly
	/// in front of it. Fixing it needs the same multi-word lookahead
	/// `StreamingTextTransformer` documents as out of scope.
	@Test
	func aRemovalDirectlyBeforePunctuationLeavesAnExtraSpaceWhenAppliedPerWord() {
		let stack = TranscriptTransformStack(
			removalsEnabled: true,
			removals: [WordRemoval(pattern: "um")],
			remappings: [],
			lowercase: false,
			removePunctuation: false
		)

		#expect(stack.apply("Hello um , world") == "Hello, world")
		#expect(Self.perSpan("Hello um , world", stack) == "Hello , world")
	}
}
