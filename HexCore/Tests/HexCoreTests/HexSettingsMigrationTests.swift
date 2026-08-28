import Foundation
import Testing
@testable import HexCore

// Fork note: migrated from XCTest to Swift Testing. XCTest ships only with full
// Xcode, and one XCTest file was enough to stop the whole HexCore test target
// from compiling under Command Line Tools — which is the only toolchain
// available on this machine. Every other suite here was already Swift Testing.
// Behaviour and assertions are unchanged; this is a mechanical port.
struct HexSettingsMigrationTests {
	@Test
	func v1FixtureMigratesToCurrentDefaults() throws {
		let data = try Self.loadFixture(named: "v1")
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		#expect(
			decoded.recordingAudioBehavior == .pauseMedia,
			"Legacy pauseMediaOnRecord bool should map to pauseMedia behavior"
		)
		#expect(decoded.soundEffectsEnabled == false)
		#expect(decoded.soundEffectsVolume == HexSettings.baseSoundEffectsVolume)
		#expect(decoded.openOnLogin == true)
		#expect(decoded.showDockIcon == false)
		#expect(decoded.selectedModel == "whisper-large-v3")
		#expect(decoded.useClipboardPaste == false)
		#expect(decoded.preventSystemSleep == true)
		#expect(decoded.minimumKeyTime == 0.25)
		#expect(decoded.copyToClipboard == true)
		#expect(decoded.superFastModeEnabled)
		#expect(decoded.useDoubleTapOnly == true)
		#expect(decoded.doubleTapLockEnabled == true)
		#expect(decoded.outputLanguage == "en")
		#expect(decoded.selectedMicrophoneID == "builtin:mic")
		#expect(decoded.saveTranscriptionHistory == false)
		#expect(decoded.maxHistoryEntries == 10)
		#expect(decoded.hasCompletedModelBootstrap == true)
		#expect(decoded.hasCompletedStorageMigration == true)
		#expect(!decoded.lowercaseTranscripts)
		#expect(!decoded.removePunctuation)
		#expect(!decoded.lowercaseFirstLetter)
	}

	@Test
	func encodeDecodeRoundTripPreservesDefaults() throws {
		let settings = HexSettings()
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)
		#expect(decoded == settings)
	}

	@Test
	func newSettingsEnableSuperFastModeByDefault() {
		#expect(HexSettings().superFastModeEnabled)
	}

	@Test
	func rustBetaBannerDismissalDefaultsToVisibleAndPersists() throws {
		var settings = try JSONDecoder().decode(HexSettings.self, from: Data("{}".utf8))
		#expect(!settings.hasDismissedRustBetaBanner)
		settings.hasDismissedRustBetaBanner = true
		let decoded = try JSONDecoder().decode(HexSettings.self, from: JSONEncoder().encode(settings))
		#expect(decoded.hasDismissedRustBetaBanner)
		#expect(decoded == settings)
	}

	@Test
	func initNormalizesDoubleTapOnlyWhenLockDisabled() {
		let settings = HexSettings(useDoubleTapOnly: true, doubleTapLockEnabled: false)

		#expect(!settings.useDoubleTapOnly)
		#expect(!settings.doubleTapLockEnabled)
	}

	@Test
	func decodeNormalizesDoubleTapOnlyWhenLockDisabled() throws {
		let payload = "{\"useDoubleTapOnly\":true,\"doubleTapLockEnabled\":false}"
		let data = try #require(payload.data(using: .utf8), "Failed to encode JSON payload")

		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		#expect(!decoded.useDoubleTapOnly)
		#expect(!decoded.doubleTapLockEnabled)
	}

	@Test
	func encodeDecodeRoundTripPreservesNormalizedDoubleTapValues() throws {
		let settings = HexSettings(useDoubleTapOnly: true, doubleTapLockEnabled: false)
		let data = try JSONEncoder().encode(settings)
		let decoded = try JSONDecoder().decode(HexSettings.self, from: data)

		#expect(!settings.useDoubleTapOnly)
		#expect(!decoded.useDoubleTapOnly)
		#expect(decoded == settings)
	}

	private static func loadFixture(named name: String) throws -> Data {
		let url = try #require(
			Bundle.module.url(
				forResource: name,
				withExtension: "json",
				subdirectory: "Fixtures/HexSettings"
			),
			"Missing fixture \(name).json"
		)
		return try Data(contentsOf: url)
	}
}
