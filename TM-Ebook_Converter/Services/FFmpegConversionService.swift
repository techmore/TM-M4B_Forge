import Foundation

enum ConversionError: LocalizedError {
    case missingTool(String)
    case probeFailed(String, String)
    case conversionFailed(String)
    case noChapters
    case outputNotSet

    var errorDescription: String? {
        switch self {
        case .missingTool(let tool): return "\(tool) was not found. Install it with Homebrew or bundle it in the app resources."
        case .probeFailed(let file, let output): return "Could not read duration for \(file). \(output)"
        case .conversionFailed(let output): return output
        case .noChapters: return "Add at least one audio chapter before converting."
        case .outputNotSet: return "Choose an output folder or file."
        }
    }
}

actor FFmpegConversionService {
    private let runner = ProcessRunner()

    func convert(project: AudiobookProject, progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        guard !project.chapters.isEmpty else { throw ConversionError.noChapters }
        guard let ffmpeg = FFmpegToolLocator.ffmpegURL() else { throw ConversionError.missingTool("ffmpeg") }

        let outputURL = resolvedOutputURL(for: project)
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("M4BForge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let metadataURL = workDir.appendingPathComponent("chapters.txt")
        try makeMetadataFile(project: project, at: metadataURL)

        var arguments = ["-hide_banner", "-nostats", project.settings.overwriteExisting ? "-y" : "-n"]
        let metadataInputIndex: Int
        let coverInputIndex: Int

        switch project.sourceMode {
        case .multipleFiles:
            let concatURL = workDir.appendingPathComponent("inputs.ffconcat")
            try makeConcatFile(project.chapters, at: concatURL)
            arguments += ["-f", "concat", "-safe", "0", "-i", concatURL.path]
            metadataInputIndex = 1
            coverInputIndex = 2
        case .singleFile:
            guard let sourceURL = project.singleSourceURL ?? project.chapters.first?.sourceURL else {
                throw ConversionError.noChapters
            }
            arguments += ["-i", sourceURL.path]
            metadataInputIndex = 1
            coverInputIndex = 2
        }

        arguments += ["-i", metadataURL.path]
        if let cover = project.coverArtURL {
            arguments += ["-i", cover.path]
        }

        arguments += ["-map_metadata", "\(metadataInputIndex)", "-map_chapters", "\(metadataInputIndex)", "-map", "0:a"]
        if project.coverArtURL != nil {
            arguments += ["-map", "\(coverInputIndex):v", "-disposition:v", "attached_pic"]
        }

        if project.settings.allowStreamCopy {
            arguments += ["-c:a", "copy"]
        } else {
            arguments += ["-c:a", "aac", "-b:a", "\(project.settings.bitrateKbps)k", "-ar", "\(project.settings.sampleRate)"]
        }

        if project.coverArtURL != nil {
            arguments += ["-c:v", "copy"]
        }

        arguments += ["-movflags", "+faststart", "-progress", "pipe:1", outputURL.path]
        progress(0.1, "Prepared FFmpeg inputs")

        let totalDuration = max(project.timelineDuration, project.duration, 1)
        let parser = LockedFFmpegProgressParser(totalDuration: totalDuration)
        let result = try await runner.runStreaming(executableURL: ffmpeg, arguments: arguments) { chunk in
            for event in parser.consume(chunk) {
                progress(event.progress, event.message)
            }
        }
        guard result.terminationStatus == 0 else {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw ConversionError.conversionFailed(result.output)
        }

        progress(1.0, result.output)
        return outputURL
    }

    private func resolvedOutputURL(for project: AudiobookProject) -> URL {
        if let outputURL = project.outputURL { return outputURL }
        let baseFolder = project.settings.outputFolderURL ?? FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        let cleanTitle = project.settings.cleanOutputNames ? NameCleaner.fileSystemName(from: project.displayTitle) : project.displayTitle.replacingOccurrences(of: "/", with: "-")
        let folder = project.settings.outputIntoProjectFolder ? baseFolder.appendingPathComponent(cleanTitle, isDirectory: true) : baseFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = cleanTitle + ".m4b"
        return folder.appendingPathComponent(fileName)
    }

    private func makeConcatFile(_ chapters: [Chapter], at url: URL) throws {
        let lines = chapters.map { "file '\($0.sourceURL.path.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: "\n")
        try lines.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeMetadataFile(project: AudiobookProject, at url: URL) throws {
        var lines = [";FFMETADATA1"]
        lines.append("title=\(escape(project.title))")
        lines.append("artist=\(escape(project.author))")
        lines.append("album=\(escape(project.album.isEmpty ? project.title : project.album))")
        lines.append("genre=\(escape(project.genre))")
        lines.append("date=\(project.year)")
        lines.append("comment=\(escape(project.description))")
        lines.append("description=\(escape(project.description))")
        lines.append("synopsis=\(escape(project.description))")
        lines.append("longdesc=\(escape(project.description))")
        lines.append("composer=\(escape(project.narrator))")
        appendOptional("publisher", project.publisher, to: &lines)
        appendOptional("ISBN", project.isbn, to: &lines)
        appendOptional("isbn", project.isbn, to: &lines)
        appendOptional("language", project.language, to: &lines)
        appendOptional("copyright", project.copyright, to: &lines)
        appendOptional("series", project.series, to: &lines)
        appendOptional("series-part", project.seriesNumber, to: &lines)

        for chapter in project.chapters {
            let start = Int((chapter.effectiveStartTime * 1000).rounded())
            let end = Int(((chapter.effectiveStartTime + chapter.duration) * 1000).rounded())
            lines += [
                "[CHAPTER]",
                "TIMEBASE=1/1000",
                "START=\(start)",
                "END=\(max(start + 1, end))",
                "title=\(escape(chapter.title))"
            ]
        }

        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "=", with: "\\=")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: "#", with: "\\#")
    }

    private func appendOptional(_ key: String, _ value: String, to lines: inout [String]) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append("\(key)=\(escape(trimmed))")
    }
}

private struct FFmpegProgressParser {
    struct Event {
        let progress: Double
        let message: String
    }

    let totalDuration: TimeInterval
    private var pending = ""
    private var lastProgress = 0.1

    nonisolated init(totalDuration: TimeInterval) {
        self.totalDuration = totalDuration
    }

    nonisolated mutating func consume(_ chunk: String) -> [Event] {
        pending += chunk
        var events: [Event] = []

        while let newline = pending.firstIndex(of: "\n") {
            let rawLine = String(pending[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            pending.removeSubrange(...newline)

            guard let separator = rawLine.firstIndex(of: "=") else { continue }
            let key = String(rawLine[..<separator])
            let value = String(rawLine[rawLine.index(after: separator)...])

            if key == "out_time_ms", let microseconds = Double(value) {
                let seconds = microseconds / 1_000_000
                let computed = min(0.99, max(0.1, seconds / totalDuration))
                if computed - lastProgress >= 0.005 {
                    lastProgress = computed
                    events.append(Event(progress: computed, message: "Encoded \(DurationFormatter.positional(seconds)) of \(DurationFormatter.positional(totalDuration))"))
                }
            } else if key == "out_time_us", let microseconds = Double(value) {
                let seconds = microseconds / 1_000_000
                let computed = min(0.99, max(0.1, seconds / totalDuration))
                if computed - lastProgress >= 0.005 {
                    lastProgress = computed
                    events.append(Event(progress: computed, message: "Encoded \(DurationFormatter.positional(seconds)) of \(DurationFormatter.positional(totalDuration))"))
                }
            } else if key == "out_time", let seconds = parseTimestamp(value) {
                let computed = min(0.99, max(0.1, seconds / totalDuration))
                if computed - lastProgress >= 0.005 {
                    lastProgress = computed
                    events.append(Event(progress: computed, message: "Encoded \(DurationFormatter.positional(seconds)) of \(DurationFormatter.positional(totalDuration))"))
                }
            } else if key == "progress", value == "end" {
                events.append(Event(progress: 1, message: "Encoding complete"))
            }
        }

        return events
    }

    nonisolated private func parseTimestamp(_ value: String) -> TimeInterval? {
        let pieces = value.split(separator: ":").map(String.init)
        guard pieces.count == 3,
              let hours = Double(pieces[0]),
              let minutes = Double(pieces[1]),
              let seconds = Double(pieces[2])
        else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}

private final class LockedFFmpegProgressParser: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var parser: FFmpegProgressParser

    nonisolated init(totalDuration: TimeInterval) {
        parser = FFmpegProgressParser(totalDuration: totalDuration)
    }

    nonisolated func consume(_ chunk: String) -> [FFmpegProgressParser.Event] {
        lock.lock()
        defer { lock.unlock() }
        return parser.consume(chunk)
    }
}
