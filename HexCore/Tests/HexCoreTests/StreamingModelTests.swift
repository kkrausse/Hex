import Testing
@testable import HexCore

struct StreamingModelTests {
	/// `contextSuffix` is interpolated straight into the encoder's filename, so a
	/// wrong value does not fail loudly — it looks for a file that is not there,
	/// reports the model as missing, and re-downloads. Pin both tiers.
	@Test
	func contextSuffixMatchesTheEncoderFilename() {
		#expect(StreamingModel.parakeetUnified1120ms.contextSuffix == "70_7_7")
		#expect(StreamingModel.parakeetUnified2080ms.contextSuffix == "70_13_13")
	}

	@Test
	func latencyIsChunkPlusRightContextAtEightyMillisecondsPerFrame() {
		#expect(StreamingModel.parakeetUnified1120ms.latencyMilliseconds == 1120)
		#expect(StreamingModel.parakeetUnified2080ms.latencyMilliseconds == 2080)
	}

	/// The raw value is `HexSettings.selectedModel` on disk. Changing one silently
	/// resets a user's model choice back to the default.
	@Test
	func identifiersAreStable() {
		#expect(
			StreamingModel.parakeetUnified1120ms.identifier
				== "parakeet-unified-en-0.6b-streaming-1120ms"
		)
		#expect(
			StreamingModel.parakeetUnified2080ms.identifier
				== "parakeet-unified-en-0.6b-streaming-2080ms"
		)
		#expect(StreamingModel.isStreaming("parakeet-tdt-0.6b-v3-coreml") == false)
	}

	/// Tiers share one download. If a tier ever needs its own folder, the
	/// delete path in `StreamingParakeetClient` has to learn about it.
	@Test
	func allTiersShareOneCacheFolder() {
		#expect(Set(StreamingModel.allCases.map(\.cacheFolderName)).count == 1)
	}
}
