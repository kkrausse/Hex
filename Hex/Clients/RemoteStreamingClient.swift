import Foundation
import HexCore

enum RemoteDictationError: LocalizedError, Equatable {
	/// The socket never opened, or closed before the recording was finished.
	case connection(String)
	/// The server ended the recording with a terminal `error` event, e.g. `busy`.
	case server(code: String, message: String)
	case timeout(String)
	case protocolViolation(String)
	case recordingTooLong

	var errorDescription: String? {
		switch self {
		case let .connection(detail):
			return "The dictation server could not be reached (\(detail))."
		case .server(code: "busy", message: _):
			return "The dictation server is busy with another recording."
		case let .server(code, message):
			return "The dictation server reported \(code): \(message)"
		case let .timeout(detail):
			return "The dictation server timed out (\(detail))."
		case let .protocolViolation(detail):
			return "The dictation server sent something unexpected (\(detail))."
		case .recordingTooLong:
			return "The recording is longer than the dictation server accepts."
		}
	}
}

/// Runs a live session against a dictation server instead of the on-device
/// decoder: the remote sibling of `StreamingParakeetClient`'s session API.
///
/// Same shape on purpose — open a session with a partial callback, feed 16 kHz
/// mono Float32 samples, finish for the final transcript — so everything above
/// it (`StreamingDictationLive`, the transcript pipeline, the inserter) is
/// shared rather than forked. Partials are cumulative, exactly as FluidAudio's.
///
/// Protocol: `dictation-server/docs/protocol.md`, v1. One WebSocket per
/// recording; `start`, wait for `ready`, binary frames, `stop`, then `final` and
/// `done`.
///
/// Two differences from the on-device client shape everything in here:
///
/// - **Opening a session returns before the socket is open.** The caller opens
///   the microphone only after `startSession` returns, so a TLS + WebSocket
///   handshake there would swallow the opening words. Audio that arrives before
///   `ready` waits in `pending` and is sent the moment the server is ready.
/// - **Failure is asynchronous.** An unreachable or busy server is only known
///   some time after the session "opened". It is latched in `failure` and
///   thrown from `finishSession`, where the caller decides what to do with the
///   recording. Nothing is retried or replayed.
actor RemoteStreamingClient {
	private struct Connection {
		let id: UUID
		let task: URLSessionWebSocketTask
		let onPartial: @Sendable (String) -> Void
		var watchdog: Task<Void, Never>?

		var isReady = false
		var sawLoading = false
		var readyDeadline: ContinuousClock.Instant
		var lastServerActivity = ContinuousClock.now

		/// Captured audio not yet handed to the socket. Sent bytes are dropped
		/// from the front lazily; see `pendingOffset`.
		var pending = Data()
		var pendingOffset = 0
		var appendedBytes = 0
		var sentBytes = 0
		/// The server's cumulative count of bytes it has run inference on.
		var acknowledgedBytes = 0
		var nextSequence = 0

		var stopRequested = false
		var stopSent = false
		var finalText: String?
		var failure: RemoteDictationError?
		var finalWaiter: CheckedContinuation<String, Error>?
	}

	/// Unacknowledged audio allowed on the wire. The server terminates a
	/// recording once two seconds are queued; half of that leaves room for
	/// frames still in the socket. Capture is real time and the server decodes
	/// far faster, so this only ever binds when catching up — after a slow
	/// connect, or behind a model that was still loading.
	private static let windowBytes = RemoteDictationEndpoint.serverQueueBytes / 2
	private static let frameBytes = RemoteDictationEndpoint.frameBytes
	private static let maxRecordingBytes =
		RemoteDictationEndpoint.maxSeconds * RemoteDictationEndpoint.sampleRate * MemoryLayout<Float>.size

	/// How long the server gets to say `ready`. Short, because until then the
	/// user is talking and seeing nothing.
	private static let readyTimeout: Duration = .seconds(8)
	/// A server that answered `loading` is alive and compiling its model; give
	/// it the same two minutes the browser client does. The recording carries on
	/// meanwhile, and is sent from the start once the model is up.
	private static let loadingTimeout: Duration = .seconds(120)
	/// On release, a session that is not ready yet gets this long before the
	/// recording is handed back for on-device transcription instead.
	private static let readyGraceAtFinish: Duration = .seconds(2)
	/// Longest silence tolerated while audio is unacknowledged or the final
	/// transcript is outstanding.
	private static let stallTimeout: Duration = .seconds(15)

	private let urlSession: URLSession = {
		let configuration = URLSessionConfiguration.ephemeral
		configuration.waitsForConnectivity = false
		return URLSession(configuration: configuration)
	}()
	private let logger = HexLog.transcription
	private var connection: Connection?

	/// Opens a session, replacing any previous one. Returns immediately; see the
	/// type's doc comment for why.
	///
	/// `onPartial` receives the server's **cumulative** transcript, in order.
	func startSession(url: URL, onPartial: @escaping @Sendable (String) -> Void) {
		cancelSession()

		let id = UUID()
		let task = urlSession.webSocketTask(with: url)
		var connection = Connection(
			id: id,
			task: task,
			onPartial: onPartial,
			readyDeadline: ContinuousClock.now + Self.readyTimeout
		)
		connection.watchdog = Task { [weak self] in
			while !Task.isCancelled {
				try? await Task.sleep(for: .milliseconds(250))
				await self?.checkDeadlines(id)
			}
		}
		self.connection = connection

		task.resume()
		// Queued by URLSession until the handshake completes, so this needs no
		// "did open" callback and is guaranteed to be the first frame.
		sendControl(
			[
				"type": "start",
				"version": 1,
				"recordingId": id.uuidString.lowercased(),
				"sampleRate": RemoteDictationEndpoint.sampleRate,
				"channels": 1,
				"format": "f32le",
			],
			on: task,
			id: id
		)
		Task { [weak self] in
			await self?.receiveLoop(task: task, id: id)
		}
		logger.notice("Remote dictation session \(id.uuidString, privacy: .public) opening")
	}

	/// Queues captured audio and sends as much as the server's window allows.
	///
	/// Nothing is dropped: audio the window will not take yet stays in `pending`.
	/// The only bound is the server's own recording limit, past which the
	/// session fails rather than silently truncating.
	func append(_ samples: [Float]) {
		guard var connection, connection.failure == nil, !connection.stopRequested, !samples.isEmpty else {
			return
		}
		// The server rejects the whole recording on a single non-finite sample.
		let safe = samples.contains(where: { !$0.isFinite }) ? samples.map { $0.isFinite ? $0 : 0 } : samples
		// Float32 little-endian on the wire, which is the in-memory layout on
		// every Mac Hex runs on.
		safe.withUnsafeBufferPointer { connection.pending.append($0) }
		connection.appendedBytes += safe.count * MemoryLayout<Float>.size
		self.connection = connection

		guard connection.appendedBytes <= Self.maxRecordingBytes else {
			fail(.recordingTooLong, id: connection.id)
			return
		}
		pump()
	}

	/// Sends the rest of the audio, asks the server to finish, and returns its
	/// final cumulative transcript.
	///
	/// Throws the session's failure if it has one — including one that happened
	/// long before this call. Partials keep arriving through `onPartial` until
	/// the final does; the protocol sends none after it, and both come off one
	/// socket in order, so there is no tail to deliver twice.
	func finishSession() async throws -> String {
		guard var connection else { return "" }
		let id = connection.id
		defer { release(id) }

		if let failure = connection.failure { throw failure }
		connection.stopRequested = true
		if !connection.isReady {
			// Still loading on release: the on-device path will have the text
			// long before a cold server does, so stop waiting for it.
			guard !connection.sawLoading else {
				fail(.timeout("the server was still loading its model"), id: id)
				throw RemoteDictationError.timeout("the server was still loading its model")
			}
			connection.readyDeadline = min(connection.readyDeadline, ContinuousClock.now + Self.readyGraceAtFinish)
		}
		self.connection = connection
		pump()

		return try await withCheckedThrowingContinuation { continuation in
			guard var current = self.connection, current.id == id else {
				continuation.resume(throwing: RemoteDictationError.connection("session replaced"))
				return
			}
			if let failure = current.failure {
				continuation.resume(throwing: failure)
			} else if let finalText = current.finalText {
				continuation.resume(returning: finalText)
			} else {
				current.finalWaiter = continuation
				self.connection = current
			}
		}
	}

	/// Abandons the session without producing a transcript.
	func cancelSession() {
		guard let connection else { return }
		self.connection = nil
		connection.watchdog?.cancel()
		connection.finalWaiter?.resume(throwing: CancellationError())
		guard connection.failure == nil, connection.finalText == nil else { return }
		// Closing alone abandons the recording too; the explicit message just
		// lets the server reset its decoder without waiting to notice.
		let task = connection.task
		sendControl(["type": "cancel", "recordingId": connection.id.uuidString.lowercased()], on: task, id: nil) {
			task.cancel(with: .goingAway, reason: nil)
		}
	}

	// MARK: - Sending

	/// Hands `pending` to the socket in 80 ms frames, as far as the window allows.
	///
	/// Synchronous on purpose: `URLSessionWebSocketTask` sends in call order, so
	/// keeping every send inside one actor turn is what keeps frames in order.
	private func pump() {
		guard var connection, connection.isReady, connection.failure == nil else { return }
		let id = connection.id

		while connection.pending.count - connection.pendingOffset > 0 {
			let available = connection.pending.count - connection.pendingOffset
			let size = min(Self.frameBytes, available)
			// A short tail waits for more audio unless the recording is over.
			if size < Self.frameBytes, !connection.stopRequested { break }
			guard connection.sentBytes - connection.acknowledgedBytes + size <= Self.windowBytes else { break }

			let start = connection.pending.startIndex + connection.pendingOffset
			let frame = connection.pending.subdata(in: start..<(start + size))
			connection.pendingOffset += size
			if connection.sentBytes == connection.acknowledgedBytes {
				// First outstanding audio after an idle stretch: the stall clock
				// starts now, not at the last event of the previous burst.
				connection.lastServerActivity = .now
			}
			connection.sentBytes += size
			connection.task.send(.data(frame)) { [weak self] error in
				guard let error else { return }
				Task { await self?.fail(.connection(error.localizedDescription), id: id) }
			}
		}

		// Drop what was sent once it is worth a copy, so a long recording does
		// not keep its whole history in memory.
		if connection.pendingOffset > 1 << 20 {
			connection.pending.removeSubrange(
				connection.pending.startIndex..<(connection.pending.startIndex + connection.pendingOffset)
			)
			connection.pendingOffset = 0
		}

		if connection.stopRequested, !connection.stopSent,
		   connection.pending.count == connection.pendingOffset
		{
			// Strictly after the last audio frame, as the protocol requires.
			connection.stopSent = true
			connection.lastServerActivity = .now
			sendControl(["type": "stop", "recordingId": id.uuidString.lowercased()], on: connection.task, id: id)
		}
		self.connection = connection
	}

	private func sendControl(
		_ message: [String: Any],
		on task: URLSessionWebSocketTask,
		id: UUID?,
		then completion: (@Sendable () -> Void)? = nil
	) {
		guard let data = try? JSONSerialization.data(withJSONObject: message),
		      let text = String(data: data, encoding: .utf8)
		else { return }
		task.send(.string(text)) { [weak self] error in
			completion?()
			guard let error, let id else { return }
			Task { await self?.fail(.connection(error.localizedDescription), id: id) }
		}
	}

	// MARK: - Receiving

	private struct Event: Decodable {
		var type: String
		var recordingId: String?
		var sequence: Int?
		var text: String?
		var bytes: Int?
		var code: String?
		var message: String?
	}

	private func receiveLoop(task: URLSessionWebSocketTask, id: UUID) async {
		while true {
			let message: URLSessionWebSocketTask.Message
			do {
				message = try await task.receive()
			} catch {
				// The server closes after `done`, so this is how every session
				// ends. It is only a failure if the final never arrived.
				fail(.connection(Self.describe(error, task: task)), id: id)
				return
			}
			guard case let .string(text) = message,
			      let event = try? JSONDecoder().decode(Event.self, from: Data(text.utf8))
			else {
				fail(.protocolViolation("undecodable event"), id: id)
				task.cancel(with: .protocolError, reason: nil)
				return
			}
			if event.type == "done" {
				task.cancel(with: .normalClosure, reason: nil)
				return
			}
			handle(event, id: id)
		}
	}

	private func handle(_ event: Event, id: UUID) {
		guard var connection, connection.id == id, connection.failure == nil else { return }
		connection.lastServerActivity = .now

		if event.type == "error" {
			self.connection = connection
			fail(.server(code: event.code ?? "unknown", message: event.message ?? ""), id: id)
			return
		}

		// Ordering is the one guarantee insertion depends on, so a gap is fatal
		// rather than something to paper over.
		guard event.sequence == connection.nextSequence else {
			self.connection = connection
			fail(.protocolViolation("event out of sequence"), id: id)
			return
		}
		connection.nextSequence += 1

		switch event.type {
		case "loading":
			connection.sawLoading = true
			connection.readyDeadline = .now + Self.loadingTimeout
			logger.notice("Remote dictation server is loading its model")
		case "ready":
			connection.isReady = true
			logger.notice("Remote dictation session ready")
		case "ack":
			if let bytes = event.bytes, bytes > connection.acknowledgedBytes, bytes <= connection.sentBytes {
				connection.acknowledgedBytes = bytes
			}
		case "partial":
			if let text = event.text, connection.finalText == nil {
				connection.onPartial(text)
			}
		case "final":
			connection.finalText = event.text ?? ""
			connection.finalWaiter?.resume(returning: event.text ?? "")
			connection.finalWaiter = nil
		default:
			// A newer server may add event types; none can change what the ones
			// above mean.
			break
		}
		self.connection = connection
		if event.type == "ready" || event.type == "ack" { pump() }
	}

	// MARK: - Failure

	private func fail(_ error: RemoteDictationError, id: UUID) {
		guard var connection, connection.id == id,
		      connection.failure == nil, connection.finalText == nil
		else { return }
		connection.failure = error
		connection.pending = Data()
		connection.pendingOffset = 0
		connection.watchdog?.cancel()
		connection.finalWaiter?.resume(throwing: error)
		connection.finalWaiter = nil
		connection.task.cancel(with: .goingAway, reason: nil)
		self.connection = connection
		logger.error(
			"Remote dictation session failed after \(connection.acknowledgedBytes) acknowledged bytes: \(error.localizedDescription, privacy: .public)"
		)
	}

	private func checkDeadlines(_ id: UUID) {
		guard let connection, connection.id == id, connection.failure == nil else { return }
		let now = ContinuousClock.now
		if !connection.isReady {
			if now > connection.readyDeadline {
				fail(.timeout(connection.sawLoading ? "model load" : "no answer"), id: id)
			}
			return
		}
		let awaitingServer = connection.sentBytes > connection.acknowledgedBytes
			|| (connection.stopSent && connection.finalText == nil)
		if awaitingServer, now - connection.lastServerActivity > Self.stallTimeout {
			fail(.timeout("no response for \(Self.stallTimeout.components.seconds)s"), id: id)
		}
	}

	/// Forgets a finished session. The socket is left to see the server's `done`
	/// and close on its own — closing early would cut off the decoder reset the
	/// next recording depends on — with a deadline in case that never comes.
	private func release(_ id: UUID) {
		guard let connection, connection.id == id else { return }
		self.connection = nil
		connection.watchdog?.cancel()
		let task = connection.task
		Task {
			try? await Task.sleep(for: .seconds(5))
			task.cancel(with: .goingAway, reason: nil)
		}
	}

	private static func describe(_ error: Error, task: URLSessionWebSocketTask) -> String {
		if task.closeCode != .invalid {
			return "closed with code \(task.closeCode.rawValue)"
		}
		return error.localizedDescription
	}
}
