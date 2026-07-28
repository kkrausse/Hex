import AppKit
import ComposableArchitecture
import HexCore
import Sauce

private let inserterLogger = HexLog.pasteboard

/// Preserves every pasteboard item and representation while dictation uses the
/// clipboard as a transport for synthetic paste events.
///
/// Ported from `../dictate-wrapper`. `PasteboardClient.pasteWithClipboard` does
/// the same job for the batch path, but does a full snapshot/write/paste/wait/
/// restore cycle per call — fine once per recording, far too heavy per word.
/// This snapshots once for the whole session and defers the restore until the
/// user stops talking.
@MainActor
final class ClipboardPreserver {
	private struct Snapshot {
		let items: [[NSPasteboard.PasteboardType: Data]]

		init(pasteboard: NSPasteboard) {
			items = (pasteboard.pasteboardItems ?? []).map { item in
				Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
					item.data(forType: type).map { (type, $0) }
				})
			}
		}

		func restore(to pasteboard: NSPasteboard) {
			pasteboard.clearContents()
			guard !items.isEmpty else { return }

			let restoredItems = items.map { representations in
				let item = NSPasteboardItem()
				for (type, data) in representations {
					item.setData(data, forType: type)
				}
				return item
			}
			pasteboard.writeObjects(restoredItems)
		}
	}

	/// How long temporary contents stay on the pasteboard before the snapshot is
	/// restored. The synthetic Cmd+V must be handled by the target app within
	/// this window or it pastes the restored (old) contents instead — slow apps
	/// can need well over 100 ms. Each new word reschedules it, so during
	/// continuous speech the restore only ever fires after the user stops.
	static let restorationDelay: Duration = .milliseconds(250)

	private let pasteboard: NSPasteboard
	private var snapshot: Snapshot?
	private var pendingRestoration: Task<Void, Never>?
	private var pendingFinish: Task<Void, Never>?
	private var temporaryContentsAreActive = false

	nonisolated init(pasteboard: NSPasteboard = .general) {
		self.pasteboard = pasteboard
	}

	/// Awaits any still-pending restore from the previous session before taking
	/// its snapshot. Starting a new recording within the restore delay of the
	/// last one would otherwise snapshot the dictated word and hand that back to
	/// the user as their clipboard.
	func beginSession() async {
		await pendingFinish?.value
		pendingRestoration?.cancel()
		pendingRestoration = nil
		snapshot = Snapshot(pasteboard: pasteboard)
		temporaryContentsAreActive = false
	}

	func writeTemporaryString(_ string: String) -> Bool {
		guard snapshot != nil else { return false }

		pendingRestoration?.cancel()
		pendingRestoration = nil
		pasteboard.clearContents()
		guard pasteboard.setString(string, forType: .string) else {
			restoreNow()
			return false
		}
		temporaryContentsAreActive = true
		scheduleRestoration()
		return true
	}

	/// Ends the session. `finalText` is left on the pasteboard instead of the
	/// snapshot when the user has "copy to clipboard" turned on, matching what
	/// the batch path leaves behind after a transcription.
	///
	/// The final write is deferred by the same delay as a restore whenever a
	/// paste is still in flight: overwriting the pasteboard immediately would
	/// race the last Cmd+V, which the target app may not have serviced yet.
	func finishSession(leaving finalText: String?) {
		pendingRestoration?.cancel()
		pendingRestoration = nil
		guard let snapshot else { return }

		let pasteboard = pasteboard
		let delay = temporaryContentsAreActive ? Self.restorationDelay : .zero
		let apply: @MainActor @Sendable () -> Void = {
			if let finalText, !finalText.isEmpty {
				pasteboard.clearContents()
				pasteboard.setString(finalText, forType: .string)
				inserterLogger.debug("Left the dictated transcript on the clipboard")
			} else {
				snapshot.restore(to: pasteboard)
				inserterLogger.debug("Restored the clipboard snapshot over dictated contents")
			}
		}

		self.snapshot = nil
		temporaryContentsAreActive = false

		if delay == .zero {
			apply()
			return
		}
		// Deliberately not stored in `pendingRestoration`: the session is over and
		// nothing may cancel this — the user's clipboard has to come back. The
		// next `beginSession()` waits on it instead.
		pendingFinish = Task { @MainActor in
			try? await Task.sleep(for: delay)
			apply()
		}
	}

	private func scheduleRestoration() {
		pendingRestoration?.cancel()
		pendingRestoration = Task { @MainActor [weak self] in
			try? await Task.sleep(for: Self.restorationDelay)
			guard !Task.isCancelled, let self else { return }
			self.restoreNow()
		}
	}

	private func restoreNow() {
		pendingRestoration = nil
		snapshot?.restore(to: pasteboard)
		if temporaryContentsAreActive {
			inserterLogger.debug("Restored the clipboard snapshot over dictated contents")
		}
		temporaryContentsAreActive = false
	}
}

/// Inserts text into whatever application has focus, one delta at a time.
///
/// The transport is the clipboard plus a synthetic Cmd+V, the same mechanism
/// `PasteboardClient` uses — but held open across a whole dictation session.
@MainActor
final class IncrementalTextInserter {
	/// Minimum gap between two synthetic pastes.
	///
	/// The clipboard is a single slot, so a second delta written before the
	/// target app has serviced the first Cmd+V makes that app paste the *new*
	/// contents twice and lose the old — a duplicated word, in text that cannot
	/// be taken back. Word-rate deltas normally arrive one encoder window apart
	/// (~560 ms) and never wait here; this only bites when the decoder catches
	/// up on several windows at once and emits them back to back.
	static let minimumInsertInterval: Duration = .milliseconds(120)

	private let preserver = ClipboardPreserver()
	private var insertedAnything = false
	private var lastInsertAt: ContinuousClock.Instant?

	nonisolated init() {}

	func begin() async {
		insertedAnything = false
		lastInsertAt = nil
		await preserver.beginSession()
	}

	/// - Returns: whether the text reached the pasteboard. A failure here means
	///   nothing was typed, so the caller must not count it as inserted.
	func insert(_ text: String) async -> Bool {
		guard !text.isEmpty else { return true }
		await waitForInsertSlot()

		guard preserver.writeTemporaryString(text) else {
			inserterLogger.error("Could not write a dictation delta to the pasteboard")
			return false
		}
		// Deliberately no poll for the pasteboard changeCount to settle, unlike
		// the batch path: NSPasteboard writes are synchronous for the writer, and
		// a 150 ms poll per word would put insertion behind live speech.
		postCommandV()
		lastInsertAt = .now
		insertedAnything = true
		return true
	}

	private func waitForInsertSlot() async {
		guard let lastInsertAt else { return }
		let elapsed = ContinuousClock.now - lastInsertAt
		guard elapsed < Self.minimumInsertInterval else { return }
		try? await Task.sleep(for: Self.minimumInsertInterval - elapsed)
	}

	func end(leaving finalText: String?) {
		preserver.finishSession(leaving: insertedAnything ? finalText : nil)
		insertedAnything = false
	}

	private func postCommandV() {
		let source = CGEventSource(stateID: .combinedSessionState)
		let vKey = Sauce.shared.keyCode(for: .v)
		let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
		let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
		// Set exactly Command, overriding any modifier the user is physically
		// holding. Press-and-hold dictation means Option (or whatever the hotkey
		// is) is down for the whole session, and letting that ride along would
		// turn every paste into Cmd+Option+V — a different shortcut entirely.
		keyDown?.flags = .maskCommand
		keyUp?.flags = .maskCommand
		keyDown?.post(tap: .cghidEventTap)
		keyUp?.post(tap: .cghidEventTap)
	}
}
