import Testing
@testable import HexCore

/// The observations here mirror what `StreamingUnifiedAsrManager` actually
/// delivers: the *whole* transcript each time, rebuilt from sentencepiece pieces
/// and trimmed of surrounding whitespace, so it grows word by word and never
/// leads with a space.
struct StreamingTranscriptPipelineTests {
	private static let identity: @Sendable (String) -> String = { $0 }

	private static let commaStack = TranscriptTransformStack(
		removalsEnabled: false,
		removals: [],
		remappings: [WordRemapping(match: "comma", replacement: ",")],
		lowercase: false,
		removePunctuation: false
	)

	// MARK: - Ordinary dictation

	@Test
	func releasesWholeWordsOneBehindAndFlushesTheTailOnFinish() {
		var pipeline = StreamingTranscriptPipeline()

		// The first word is held: nothing yet proves the decoder is done with it.
		#expect(pipeline.observe("hello", transform: Self.identity).textToInsert == "")
		#expect(pipeline.observe("hello there", transform: Self.identity).textToInsert == "hello ")
		#expect(pipeline.pendingText == "there")

		#expect(pipeline.finish("hello there", transform: Self.identity).textToInsert == "there")
		#expect(pipeline.insertedText == "hello there")
	}

	@Test
	func aRepeatedObservationInsertsNothing() {
		var pipeline = StreamingTranscriptPipeline()
		_ = pipeline.observe("hello there", transform: Self.identity)
		let repeated = pipeline.observe("hello there", transform: Self.identity)
		#expect(repeated == .nothing)
	}

	@Test
	func insertedTextIsTheTransformedTextNotTheRawTranscript() {
		var pipeline = StreamingTranscriptPipeline()
		let transform = { Self.commaStack.apply($0) }

		_ = pipeline.observe("hello comma", transform: transform)
		_ = pipeline.observe("hello comma there", transform: transform)
		_ = pipeline.finish("hello comma there", transform: transform)

		#expect(pipeline.insertedText == "hello , there")
	}

	@Test
	func finishWithNoObservationsInsertsNothing() {
		var pipeline = StreamingTranscriptPipeline()
		#expect(pipeline.finish("", transform: Self.identity) == .nothing)
		#expect(pipeline.insertedText == "")
	}

	@Test
	func finishReleasesTheTailEvenWhenItCarriesNewText() {
		// finish() sees the last window's emissions, so its transcript can be
		// longer than any partial the callback delivered.
		var pipeline = StreamingTranscriptPipeline()
		_ = pipeline.observe("hello there", transform: Self.identity)

		let outcome = pipeline.finish("hello there world", transform: Self.identity)
		#expect(outcome.textToInsert == "there world")
		#expect(pipeline.insertedText == "hello there world")
	}

	// MARK: - Divergence

	@Test
	func divergenceInsertsNothingAndReportsWhy() {
		var pipeline = StreamingTranscriptPipeline()
		_ = pipeline.observe("hello there", transform: Self.identity)

		let outcome = pipeline.observe("goodbye there", transform: Self.identity)
		#expect(outcome.textToInsert == "")
		#expect(outcome.divergenceDiagnostic != nil)
		#expect(pipeline.insertedText == "hello ")
	}

	@Test
	func divergenceOnFinishStillFlushesTextThatWasAlreadyValid() {
		// "there" was held back by a legitimate observation. A contradicting final
		// transcript is no reason to swallow it — it was already earned.
		var pipeline = StreamingTranscriptPipeline()
		_ = pipeline.observe("hello there", transform: Self.identity)

		let outcome = pipeline.finish("something else", transform: Self.identity)
		#expect(outcome.textToInsert == "there")
		#expect(outcome.divergenceDiagnostic != nil)
		#expect(pipeline.insertedText == "hello there")
	}

	// MARK: - Cancellation

	@Test
	func cancelKeepsWhatWasInsertedAndDropsTheHeldWord() {
		var pipeline = StreamingTranscriptPipeline()
		_ = pipeline.observe("hello", transform: Self.identity)
		_ = pipeline.observe("hello there", transform: Self.identity)

		#expect(pipeline.cancel() == "hello ")
		#expect(pipeline.pendingText == "")
	}

	@Test
	func resetClearsEverythingForTheNextSession() {
		var pipeline = StreamingTranscriptPipeline()
		_ = pipeline.observe("hello there", transform: Self.identity)
		pipeline.reset()

		// Without the cursor reset this would read as a divergence against the
		// previous utterance rather than a fresh one.
		#expect(pipeline.observe("goodbye now", transform: Self.identity).textToInsert == "goodbye ")
		#expect(pipeline.insertedText == "goodbye ")
	}
}
