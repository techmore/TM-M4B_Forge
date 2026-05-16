import Foundation

enum ChapterTemplateKind: String, CaseIterable, Identifiable {
    case audiobook = "Audiobook"
    case narratedBook = "Narrated Book"
    case interview = "Interview"
    case cleanSlate = "Clean Slate"

    nonisolated var id: String { rawValue }

    nonisolated var drafts: [ChapterDraft] {
        switch self {
        case .audiobook:
            return (0..<10).map { index in
                ChapterDraft(
                    title: index == 0 ? "Opening Credits" : "Chapter \(index)",
                    startTime: TimeInterval(index * 600)
                )
            }
        case .narratedBook:
            return [
                ChapterDraft(title: "Introduction", startTime: 0),
                ChapterDraft(title: "Chapter 1", startTime: 60),
                ChapterDraft(title: "Acknowledgements", startTime: 3_600)
            ]
        case .interview:
            return [
                ChapterDraft(title: "Intro", startTime: 0),
                ChapterDraft(title: "Conversation", startTime: 45),
                ChapterDraft(title: "Outro", startTime: 3_600)
            ]
        case .cleanSlate:
            return [
                ChapterDraft(title: "Chapter 1", startTime: 0)
            ]
        }
    }
}
