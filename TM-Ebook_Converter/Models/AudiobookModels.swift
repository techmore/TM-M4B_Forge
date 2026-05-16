import Foundation

struct AudiobookProject: Identifiable, Codable, Hashable {
    enum SourceMode: String, Codable, Hashable {
        case multipleFiles
        case singleFile
    }

    var id = UUID()
    var sourceMode: SourceMode = .multipleFiles
    var title = "Untitled Audiobook"
    var author = ""
    var narrator = ""
    var album = ""
    var genre = "Audiobook"
    var description = ""
    var year = Calendar.current.component(.year, from: Date())
    var publisher = ""
    var isbn = ""
    var language = ""
    var copyright = ""
    var series = ""
    var seriesNumber = ""
    var chapters: [Chapter] = []
    var coverArtURL: URL?
    var sourceFolderURL: URL?
    var singleSourceURL: URL?
    var sourceDuration: TimeInterval?
    var outputURL: URL?
    var settings = ConversionSettings()
    var createdAt = Date()
    var updatedAt = Date()

    nonisolated var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Audiobook" : title }
    nonisolated var duration: TimeInterval { chapters.map(\.duration).reduce(0, +) }
    nonisolated var timelineDuration: TimeInterval { sourceDuration ?? duration }
}

struct Chapter: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var sourceURL: URL
    var duration: TimeInterval = 0
    var startTime: TimeInterval = 0
    var manualStartTime: TimeInterval?

    nonisolated var effectiveStartTime: TimeInterval { manualStartTime ?? startTime }
    nonisolated var fileName: String { sourceURL.lastPathComponent }
    nonisolated var endTime: TimeInterval { effectiveStartTime + duration }
}

struct ConversionSettings: Codable, Hashable {
    var bitrateKbps = 160
    var sampleRate = 44_100
    var allowStreamCopy = false
    var overwriteExisting = false
    var outputIntoProjectFolder = true
    var cleanOutputNames = true
    var outputFolderURL: URL?
}

struct AppDefaults: Codable, Hashable {
    var bitrateKbps = 160
    var sampleRate = 44_100
    var allowStreamCopy = false
    var overwriteExisting = false
    var outputIntoProjectFolder = true
    var cleanOutputNames = true
    var outputFolderURL: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
}

struct ConversionJob: Identifiable, Hashable {
    enum Status: String, Hashable {
        case queued = "Queued"
        case running = "Running"
        case completed = "Completed"
        case failed = "Failed"
        case canceled = "Canceled"
    }

    let id = UUID()
    var project: AudiobookProject
    var status: Status = .queued
    var progress: Double = 0
    var estimatedRemaining: TimeInterval?
    var log = ""
    var outputURL: URL?
}

struct ImportCandidate: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case audiobookFolder = "Folder"
        case audioFiles = "Audio Files"
        case singleAudioFile = "Single File"
        case unsupported = "Unsupported"
    }

    enum Status: String, Hashable {
        case pending = "Pending"
        case approved = "Approved"
        case skipped = "Skipped"
        case warning = "Warning"
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var rootURL: URL
    var audioFiles: [URL]
    var coverArtURL: URL?
    var totalBytes: Int64
    var status: Status = .pending
    var isSelected = true
    var warnings: [String] = []
    var chapterDrafts: [ChapterDraft] = []
    var metadataDraft = BookMetadataDraft()

    nonisolated var fileCount: Int { audioFiles.count }
    nonisolated var sizeDescription: String { ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file) }
    nonisolated var supportsChapterTemplate: Bool {
        kind == .singleAudioFile && audioFiles.first?.pathExtension.lowercased() != "m4b"
    }
}

struct ChapterDraft: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var startTime: TimeInterval
}

struct BookMetadataDraft: Codable, Hashable {
    var description = ""
    var genre = "Audiobook"
    var publisher = ""
    var isbn = ""
    var language = ""
    var copyright = ""
    var series = ""
    var seriesNumber = ""

    nonisolated init(
        description: String = "",
        genre: String = "Audiobook",
        publisher: String = "",
        isbn: String = "",
        language: String = "",
        copyright: String = "",
        series: String = "",
        seriesNumber: String = ""
    ) {
        self.description = description
        self.genre = genre
        self.publisher = publisher
        self.isbn = isbn
        self.language = language
        self.copyright = copyright
        self.series = series
        self.seriesNumber = seriesNumber
    }
}
