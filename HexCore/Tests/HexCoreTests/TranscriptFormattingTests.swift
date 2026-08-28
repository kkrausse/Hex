import Testing
@testable import HexCore

struct TranscriptFormattingTests {
	@Test
	func lowercasesTranscript() {
		let result = TranscriptFormattingApplier.apply(
			"Hello WORLD!",
			lowercase: true,
			removePunctuation: false
		)

		#expect(result == "hello world!")
	}

	@Test
	func removesUnicodePunctuation() {
		let result = TranscriptFormattingApplier.apply(
			"Hello, world! It’s well-known — really.",
			lowercase: false,
			removePunctuation: true
		)

		#expect(result == "Hello world Its wellknown  really")
	}

	@Test
	func appliesBothOptionsIndependently() {
		let result = TranscriptFormattingApplier.apply(
			"Hello, WORLD!",
			lowercase: true,
			removePunctuation: true
		)

		#expect(result == "hello world")
	}

	@Test
	func leavesTranscriptUnchangedWhenDisabled() {
		let input = "Hello, WORLD!"
		let result = TranscriptFormattingApplier.apply(
			input,
			lowercase: false,
			removePunctuation: false
		)

		#expect(result == input)
	}
}

struct LowercaseFirstLetterTests {
	@Test
	func lowersOnlyTheFirstLetter() {
		#expect(TranscriptFormattingApplier.lowercasingFirstLetter("Hello, I met Kevin.") == "hello, I met Kevin.")
	}

	@Test
	func skipsLeadingWhitespaceAndPunctuation() {
		#expect(TranscriptFormattingApplier.lowercasingFirstLetter(" \"Hello\"") == " \"hello\"")
	}

	@Test
	func leavesTextWithoutLettersAlone() {
		#expect(TranscriptFormattingApplier.lowercasingFirstLetter("123 ...") == "123 ...")
		#expect(TranscriptFormattingApplier.lowercasingFirstLetter("") == "")
	}

	@Test
	func stackAppliesItOnlyToTheWholeTranscript() {
		let stack = TranscriptTransformStack(
			removalsEnabled: false, removals: [], remappings: [],
			lowercase: false, removePunctuation: false, lowercaseFirstLetter: true
		)
		#expect(stack.applyToWholeTranscript("Hello There") == "hello There")
		// The per-span form must stay position independent.
		#expect(stack.apply("Hello There") == "Hello There")
	}

	@Test
	func streamingPipelineLowersTheFirstReleasedLetterOnce() {
		var pipeline = StreamingTranscriptPipeline(lowercaseFirstLetter: true)
		let identity: (String) -> String = { $0 }
		#expect(pipeline.observe("Hello", transform: identity).textToInsert == "")
		#expect(pipeline.observe("Hello Kevin", transform: identity).textToInsert == "hello")
		#expect(pipeline.observe("Hello Kevin. I", transform: identity).textToInsert == " Kevin.")
		#expect(pipeline.finish("Hello Kevin. I", transform: identity).textToInsert == " I")
		#expect(pipeline.insertedText == "hello Kevin. I")
	}

	@Test
	func streamingPipelineWaitsForTheFirstLetter() {
		var pipeline = StreamingTranscriptPipeline(lowercaseFirstLetter: true)
		let identity: (String) -> String = { $0 }
		// A leading number releases no letter yet; the lowering waits for one.
		_ = pipeline.observe("42 Hello there", transform: identity)
		#expect(pipeline.insertedText == "42 hello")
	}
}
