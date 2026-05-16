import Foundation

enum NameCleaner {
    nonisolated static func title(from raw: String) -> String {
        var value = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: #"\[[^\]]+\]|\([^\)]+\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(uncut|retail|audiobook|mp3|m4a|m4b|complete|chapter|chapters)\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^\s*\d+[\s._-]*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if value.isEmpty {
            value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return value
    }

    nonisolated static func fileSystemName(from raw: String) -> String {
        let cleaned = title(from: raw)
            .replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "-", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "Untitled Audiobook" : cleaned
    }
}
