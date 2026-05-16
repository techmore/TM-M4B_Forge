import Foundation

struct SavedProjectStatus: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let title: String
    let updatedAt: Date
    let chapterCount: Int
    let duration: TimeInterval
}
