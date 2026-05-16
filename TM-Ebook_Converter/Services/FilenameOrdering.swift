import Foundation

enum FilenameOrdering {
    nonisolated static let supportedAudioExtensions = Set(["mp3", "m4a", "aac", "wav", "flac"])
    nonisolated static let supportedImageExtensions = Set(["jpg", "jpeg", "png", "webp"])

    nonisolated static func sortedAudioFiles(from urls: [URL]) -> [URL] {
        urls
            .filter { supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                let left = sortKey(for: lhs)
                let right = sortKey(for: rhs)
                if left.number != right.number {
                    return (left.number ?? .max) < (right.number ?? .max)
                }
                return left.normalized.localizedStandardCompare(right.normalized) == .orderedAscending
            }
    }

    nonisolated static func chapterTitle(from url: URL) -> String {
        NameCleaner.title(from: url.deletingPathExtension().lastPathComponent)
    }

    private nonisolated static func sortKey(for url: URL) -> (number: Int?, normalized: String) {
        let name = url.deletingPathExtension().lastPathComponent
        let match = name.range(of: #"^\s*(\d+)"#, options: .regularExpression)
        let number = match.map { Int(name[$0].trimmingCharacters(in: .whitespaces)) } ?? nil
        return (number, name.lowercased())
    }
}
