import Foundation

/// The dictation server a live session can run against instead of the on-device
/// streaming model.
///
/// The wire protocol is "streaming dictation protocol v1" from the sibling
/// `dictation-server` repo (`docs/protocol.md`): one WebSocket per recording,
/// 16 kHz mono Float32 frames in, cumulative partial transcripts out. The server
/// runs the same Parakeet Unified 1120 ms model as `StreamingModel`, so its
/// partials mean the same thing and go through the same pipeline.
public enum RemoteDictationEndpoint {
	/// The audio format the protocol accepts. Identical to what the capture tap
	/// already produces, which is why the client never resamples.
	public static let sampleRate = 16_000
	/// Largest binary frame the server accepts (100 ms).
	public static let maxFrameBytes = 6_400
	/// Recommended frame size (80 ms).
	public static let frameBytes = 5_120
	/// The server terminates a recording with more than this queued (two seconds).
	public static let serverQueueBytes = 128_000
	/// Longest recording the server accepts, in seconds.
	public static let maxSeconds = 300

	/// Turns what the user typed into the WebSocket URL of the stream endpoint.
	///
	/// Accepts the server's origin in either spelling — `https://host:9876`, as
	/// `GET /v1/status` is addressed, or `wss://host:9876` — with or without the
	/// `/v1/stream` path. Returns nil for anything that cannot be a server
	/// address, which callers treat the same as the feature being off.
	public static func streamURL(from raw: String) -> URL? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty,
		      var components = URLComponents(string: trimmed),
		      let host = components.host, !host.isEmpty
		else { return nil }

		switch components.scheme?.lowercased() {
		case "https", "wss": components.scheme = "wss"
		case "http", "ws": components.scheme = "ws"
		default: return nil
		}

		var path = components.path
		while path.hasSuffix("/") { path.removeLast() }
		if !path.hasSuffix("/v1/stream") { path += "/v1/stream" }
		components.path = path
		components.query = nil
		components.fragment = nil
		return components.url
	}
}

public extension HexSettings {
	/// The stream endpoint to dictate against, or nil when remote dictation is
	/// off or the address is unusable.
	var remoteDictationStreamURL: URL? {
		guard remoteDictationEnabled else { return nil }
		return RemoteDictationEndpoint.streamURL(from: remoteDictationURL)
	}
}
