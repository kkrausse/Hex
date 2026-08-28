import Foundation

public enum TranscriptFormattingApplier {
	public static func apply(
		_ text: String,
		lowercase: Bool,
		removePunctuation: Bool
	) -> String {
		var output = lowercase ? text.lowercased() : text
		if removePunctuation {
			output = output.components(separatedBy: .punctuationCharacters).joined()
		}
		return output
	}

	/// Lowercases the first letter in `text`, leaving everything else alone.
	///
	/// Recognizers capitalize the start of every utterance as if it were a
	/// sentence. When dictating into the middle of a line — or a chat box where
	/// nobody capitalizes — that capital is wrong, while the ones inside the
	/// text (proper nouns, "I") are usually right. Leading whitespace and
	/// punctuation are skipped so `" Hello"` and `"\"Hello"` are handled too.
	public static func lowercasingFirstLetter(_ text: String) -> String {
		guard let index = text.firstIndex(where: { $0.isLetter }) else { return text }
		var output = text
		output.replaceSubrange(index...index, with: text[index].lowercased())
		return output
	}
}
