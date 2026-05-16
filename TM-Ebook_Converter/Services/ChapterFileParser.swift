import Foundation

enum ChapterFileParser {
    enum ParserError: LocalizedError {
        case unsupported
        case noChapters

        var errorDescription: String? {
            switch self {
            case .unsupported: return "Use a JSON or CSV chapter file."
            case .noChapters: return "No chapter rows were found in that file."
            }
        }
    }

    nonisolated static func parse(url: URL) throws -> [ChapterDraft] {
        let ext = url.pathExtension.lowercased()
        let data = try Data(contentsOf: url)
        switch ext {
        case "json":
            return try parseJSON(data)
        case "csv", "tsv":
            let text = String(data: data, encoding: .utf8) ?? ""
            return try parseDelimited(text, delimiter: ext == "tsv" ? "\t" : ",")
        default:
            throw ParserError.unsupported
        }
    }

    nonisolated private static func parseJSON(_ data: Data) throws -> [ChapterDraft] {
        let object = try JSONSerialization.jsonObject(with: data)
        let rows: [[String: Any]]

        if let array = object as? [[String: Any]] {
            rows = array
        } else if let dictionary = object as? [String: Any],
                  let chapters = dictionary["chapters"] as? [[String: Any]] ?? dictionary["segments"] as? [[String: Any]] {
            rows = chapters
        } else {
            throw ParserError.noChapters
        }

        let drafts = rows.enumerated().compactMap { index, row -> ChapterDraft? in
            guard let start = timeValue(row["start"] ?? row["start_time"] ?? row["timestamp"] ?? row["time"]) else { return nil }
            let title = stringValue(row["title"] ?? row["chapter"] ?? row["heading"] ?? row["text"])
            return ChapterDraft(title: cleanedTitle(title, index: index), startTime: start)
        }

        guard !drafts.isEmpty else { throw ParserError.noChapters }
        return sortedUnique(drafts)
    }

    nonisolated private static func parseDelimited(_ text: String, delimiter: Character) throws -> [ChapterDraft] {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let first = lines.first else { throw ParserError.noChapters }

        let header = split(first, delimiter: delimiter).map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let hasHeader = header.contains { ["title", "chapter", "start", "start_time", "timestamp", "time"].contains($0) }
        let dataLines = hasHeader ? Array(lines.dropFirst()) : lines
        let titleIndex = hasHeader ? firstIndex(in: header, names: ["title", "chapter", "heading", "text"]) : 0
        let startIndex = hasHeader ? firstIndex(in: header, names: ["start", "start_time", "timestamp", "time"]) : 1

        let drafts = dataLines.enumerated().compactMap { index, line -> ChapterDraft? in
            let columns = split(line, delimiter: delimiter)
            guard columns.indices.contains(startIndex),
                  let start = timeValue(columns[startIndex])
            else { return nil }
            let title = columns.indices.contains(titleIndex) ? columns[titleIndex] : ""
            return ChapterDraft(title: cleanedTitle(title, index: index), startTime: start)
        }

        guard !drafts.isEmpty else { throw ParserError.noChapters }
        return sortedUnique(drafts)
    }

    nonisolated private static func firstIndex(in header: [String], names: [String]) -> Int {
        header.firstIndex { names.contains($0) } ?? 0
    }

    nonisolated private static func split(_ line: String, delimiter: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false

        for character in line {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == delimiter && !inQuotes {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll()
            } else {
                current.append(character)
            }
        }
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }

    nonisolated private static func timeValue(_ value: Any?) -> TimeInterval? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let int = value as? Int { return TimeInterval(int) }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = Double(trimmed) { return seconds }
            let pieces = trimmed.split(separator: ":").compactMap { Double($0) }
            if pieces.count == 3 { return pieces[0] * 3600 + pieces[1] * 60 + pieces[2] }
            if pieces.count == 2 { return pieces[0] * 60 + pieces[1] }
        }
        return nil
    }

    nonisolated private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value { return "\(value)" }
        return ""
    }

    nonisolated private static func cleanedTitle(_ title: String, index: Int) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Chapter \(index + 1)" : trimmed
    }

    nonisolated private static func sortedUnique(_ drafts: [ChapterDraft]) -> [ChapterDraft] {
        var starts = Set<Int>()
        return drafts
            .sorted { $0.startTime < $1.startTime }
            .filter { starts.insert(Int($0.startTime.rounded())).inserted }
    }
}
