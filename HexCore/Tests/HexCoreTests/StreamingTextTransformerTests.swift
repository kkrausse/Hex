import Testing
@testable import HexCore

/// Deltas here mimic FluidAudio's cumulative-suffix callback: sentencepiece
/// pieces with `▁` rendered as a leading space, so words usually arrive whole
/// but are not guaranteed to.
struct StreamingTextTransformerTests {
	private static let commaRemapping = [
		WordRemapping(match: "comma", replacement: ",")
	]

	private static func remap(_ text: String) -> String {
		WordRemappingApplier.apply(text, remappings: commaRemapping)
	}

	private static let identity: @Sendable (String) -> String = { $0 }

	// MARK: - Boundary behavior

	@Test
	func holdsBackTrailingWordUntilNextDelta() {
		var transformer = StreamingTextTransformer()
		#expect(transformer.consume("hello", transform: Self.identity) == "")
		#expect(transformer.pendingText == "hello")

		// The space that ends "hello" arrives with the next piece, and stays with
		// it: released fragments start on whitespace and end on a word character.
		#expect(transformer.consume(" there", transform: Self.identity) == "hello")
		#expect(transformer.pendingText == " there")
	}

	@Test
	func flushReleasesFinalWord() {
		var transformer = StreamingTextTransformer()
		_ = transformer.consume("hello there", transform: Self.identity)
		#expect(transformer.flush(transform: Self.identity) == " there")
		#expect(transformer.pendingText == "")
	}

	@Test
	func flushOnEmptyBufferEmitsNothing() {
		var transformer = StreamingTextTransformer()
		#expect(transformer.flush(transform: Self.identity) == "")
	}

	@Test
	func emptyDeltaIsIgnored() {
		var transformer = StreamingTextTransformer()
		#expect(transformer.consume("", transform: Self.identity) == "")
	}

	@Test
	func concatenatedOutputReconstructsInputExactly() {
		var transformer = StreamingTextTransformer()
		let deltas = [" the", " quick", " brown", " fox", " jumps"]
		var output = ""
		for delta in deltas {
			output += transformer.consume(delta, transform: Self.identity)
		}
		output += transformer.flush(transform: Self.identity)
		#expect(output == deltas.joined())
	}

	/// The invariant that keeps dictated words from gluing together in Slack.
	///
	/// Each release is pasted as its own fragment, and Slack's composer trims a
	/// trailing space off a pasted fragment while keeping a leading one. So a
	/// release must never end in whitespace, or the separator is silently
	/// dropped and the words arrive as "helloworld".
	@Test
	func noReleaseEndsInWhitespace() {
		var transformer = StreamingTextTransformer()
		let deltas = [
			"hello", " there", " ", " friend", "s", "  spaced", "\ttabbed", " end",
		]
		var releases: [String] = []
		for delta in deltas {
			releases.append(transformer.consume(delta, transform: Self.identity))
		}
		releases.append(transformer.flush(transform: Self.identity))

		for release in releases where !release.isEmpty {
			#expect(release.last?.isWhitespace == false, "released \(String(reflecting: release))")
		}
		// And nothing is lost or reordered in the process.
		#expect(releases.joined() == deltas.joined())
	}

	@Test
	func handlesMultipleWordsInOneDelta() {
		var transformer = StreamingTextTransformer()
		#expect(transformer.consume("one two three", transform: Self.identity) == "one two")
		#expect(transformer.pendingText == " three")
	}

	@Test
	func newlineCountsAsABoundary() {
		var transformer = StreamingTextTransformer()
		#expect(transformer.consume("line\nnext", transform: Self.identity) == "line")
		#expect(transformer.pendingText == "\nnext")
	}

	// MARK: - The corruption case this type exists to prevent

	@Test
	func doesNotRemapAWordThatIsStillBeingBuilt() {
		var transformer = StreamingTextTransformer()
		// "commanding" tokenized as "▁comma" + "nding". Applying the remapping
		// per-delta would emit ",nding"; holding "comma" back until a boundary
		// proves it was a prefix, not a word, keeps it intact.
		var output = ""
		output += transformer.consume(" comma", transform: Self.remap)
		output += transformer.consume("nding", transform: Self.remap)
		output += transformer.flush(transform: Self.remap)
		#expect(output == " commanding")
		// Nothing is released until the word completes: the leading space is held
		// back to travel with the word it precedes, so the per-call split is
		// "" / "" / " commanding". Only the concatenation is contractual.
	}

	@Test
	func remapsAWordOnceItIsComplete() {
		var transformer = StreamingTextTransformer()
		var output = ""
		output += transformer.consume(" comma", transform: Self.remap)
		output += transformer.consume(" then", transform: Self.remap)
		output += transformer.flush(transform: Self.remap)
		#expect(output == " , then")
	}

	@Test
	func remappingSurvivesBeingSplitAcrossDeltas() {
		var transformer = StreamingTextTransformer()
		var output = ""
		for delta in [" com", "ma", " here"] {
			output += transformer.consume(delta, transform: Self.remap)
		}
		output += transformer.flush(transform: Self.remap)
		#expect(output == " , here")
	}

	// MARK: - Documented limitation

	@Test
	func multiWordRemappingSpanningDeltasDoesNotFire() {
		// Accepted V1 limitation: "new line" is released as two separate spans,
		// so the applier never sees the phrase intact. Documented so a future
		// lookahead implementation has a test to flip.
		var transformer = StreamingTextTransformer()
		let remappings = [WordRemapping(match: "new line", replacement: "\\n")]
		let transform = { WordRemappingApplier.apply($0, remappings: remappings) }

		var output = ""
		output += transformer.consume("new", transform: transform)
		output += transformer.consume(" line", transform: transform)
		output += transformer.consume(" x", transform: transform)
		output += transformer.flush(transform: transform)
		#expect(output == "new line x")
	}

	// MARK: - Cancellation

	@Test
	func resetDropsHeldText() {
		var transformer = StreamingTextTransformer()
		_ = transformer.consume("partial", transform: Self.identity)
		transformer.reset()
		#expect(transformer.pendingText == "")
		#expect(transformer.flush(transform: Self.identity) == "")
	}
}
