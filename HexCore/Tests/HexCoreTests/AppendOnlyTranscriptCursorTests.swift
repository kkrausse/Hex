import Testing
@testable import HexCore

struct AppendOnlyTranscriptCursorTests {
	@Test
	func firstObservationInsertsEverything() {
		var cursor = AppendOnlyTranscriptCursor()
		let update = cursor.observe("hello", isFinal: false)
		#expect(update.kind == .appended)
		#expect(update.textToInsert == "hello")
	}

	@Test
	func subsequentObservationInsertsOnlyTheSuffix() {
		var cursor = AppendOnlyTranscriptCursor()
		_ = cursor.observe("hello", isFinal: false)
		let update = cursor.observe("hello there", isFinal: false)
		#expect(update.kind == .appended)
		#expect(update.textToInsert == " there")
	}

	@Test
	func unchangedTranscriptInsertsNothing() {
		var cursor = AppendOnlyTranscriptCursor()
		_ = cursor.observe("hello", isFinal: false)
		#expect(cursor.observe("hello", isFinal: false).kind == .ignored)
	}

	@Test
	func emptyTranscriptIsIgnored() {
		var cursor = AppendOnlyTranscriptCursor()
		#expect(cursor.observe("", isFinal: false).kind == .ignored)
	}

	@Test
	func concatenatedDeltasReconstructTheTranscript() {
		var cursor = AppendOnlyTranscriptCursor()
		var assembled = ""
		for step in ["the", "the quick", "the quick brown", "the quick brown fox"] {
			assembled += cursor.observe(step, isFinal: false).textToInsert
		}
		#expect(assembled == "the quick brown fox")
	}

	@Test
	func revisedTranscriptReportsDivergenceAndInsertsNothing() {
		var cursor = AppendOnlyTranscriptCursor()
		_ = cursor.observe("their", isFinal: false)
		// The model rewrote a word it had already emitted. That text is already in
		// the user's document, so nothing may be inserted.
		let update = cursor.observe("there", isFinal: true)
		#expect(update.kind == .divergence)
		#expect(update.textToInsert == "")
		#expect(update.diagnostic != nil)
	}

	@Test
	func divergenceDoesNotAdvanceTheCursor() {
		var cursor = AppendOnlyTranscriptCursor()
		_ = cursor.observe("their", isFinal: false)
		_ = cursor.observe("there", isFinal: false)
		#expect(cursor.observedText == "their")
		// Recovery: a transcript extending the original prefix still works.
		let update = cursor.observe("their car", isFinal: false)
		#expect(update.kind == .appended)
		#expect(update.textToInsert == " car")
	}

	@Test
	func resetClearsState() {
		var cursor = AppendOnlyTranscriptCursor()
		_ = cursor.observe("hello", isFinal: false)
		cursor.reset()
		#expect(cursor.observedText == "")
		#expect(cursor.observe("hello", isFinal: false).textToInsert == "hello")
	}
}
