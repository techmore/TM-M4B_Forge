//
//  TM_Ebook_ConverterTests.swift
//  TM-Ebook_ConverterTests
//
//  Created by techmore on 5/15/26.
//

import Foundation
import Testing
@testable import M4B_Forge

struct TM_Ebook_ConverterTests {

    @Test func filenameOrderingUsesLeadingNumbers() async throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/10-End.mp3"),
            URL(fileURLWithPath: "/tmp/02-Middle.mp3"),
            URL(fileURLWithPath: "/tmp/01-Intro.mp3")
        ]

        let sorted = FilenameOrdering.sortedAudioFiles(from: urls).map(\.lastPathComponent)
        #expect(sorted == ["01-Intro.mp3", "02-Middle.mp3", "10-End.mp3"])
    }

    @Test func durationFormattingIsPositional() async throws {
        #expect(DurationFormatter.positional(3_661) == "01:01:01")
    }

    @MainActor @Test func chapterPlannerSplitsSingleFileByInterval() async throws {
        let url = URL(fileURLWithPath: "/tmp/book.mp3")
        let chapters = ChapterPlanner.chapters(for: url, totalDuration: 1_500, intervalMinutes: 10)

        #expect(chapters.map(\.title) == ["Chapter 1", "Chapter 2", "Chapter 3"])
        #expect(chapters.map(\.startTime) == [0, 600, 1_200])
        #expect(chapters.map(\.duration) == [600, 600, 300])
    }

    @MainActor @Test func chapterPlannerRebuildsDurationsFromBoundaries() async throws {
        let url = URL(fileURLWithPath: "/tmp/book.mp3")
        let chapters = [
            Chapter(title: "Three", sourceURL: url, duration: 0, startTime: 900, manualStartTime: 900),
            Chapter(title: "One", sourceURL: url, duration: 0, startTime: 0, manualStartTime: 0),
            Chapter(title: "Two", sourceURL: url, duration: 0, startTime: 300, manualStartTime: 300)
        ]

        let rebuilt = ChapterPlanner.rebuildSingleFileDurations(chapters, totalDuration: 1_200)

        #expect(rebuilt.map(\.title) == ["One", "Two", "Three"])
        #expect(rebuilt.map(\.duration) == [300, 600, 300])
    }

    @MainActor @Test func importScannerMergesLooseAudioFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("02-Chapter.mp3")
        let second = root.appendingPathComponent("01-Intro.mp3")
        FileManager.default.createFile(atPath: first.path, contents: Data())
        FileManager.default.createFile(atPath: second.path, contents: Data())

        let candidates = ImportScanner.candidates(from: [first, second])

        #expect(candidates.count == 1)
        #expect(candidates.first?.kind == .audioFiles)
        #expect(candidates.first?.audioFiles.map(\.lastPathComponent) == ["01-Intro.mp3", "02-Chapter.mp3"])
    }

    @MainActor @Test func importScannerLoadsBookSidecars() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let audio = root.appendingPathComponent("Book.mp3")
        let cover = root.appendingPathComponent("Book_cover_art.jpg")
        let chapters = root.appendingPathComponent("book.chapters.json")
        let description = root.appendingPathComponent("description.txt")
        FileManager.default.createFile(atPath: audio.path, contents: Data())
        FileManager.default.createFile(atPath: cover.path, contents: Data())
        try #"{"chapters":[{"title":"Prologue","start":0},{"title":"Chapter 1","start":60}]}"#
            .write(to: chapters, atomically: true, encoding: .utf8)
        try "A useful book description.".write(to: description, atomically: true, encoding: .utf8)

        let candidate = try #require(ImportScanner.candidates(from: [root]).first)

        #expect(candidate.kind == .singleAudioFile)
        #expect(candidate.coverArtURL?.lastPathComponent == "Book_cover_art.jpg")
        #expect(candidate.chapterDrafts.map(\.title) == ["Prologue", "Chapter 1"])
        #expect(candidate.metadataDraft.description == "A useful book description.")
    }

    @Test func nameCleanerRemovesCommonNoise() async throws {
        #expect(NameCleaner.title(from: "01_The.Book.Title_[Retail]_MP3") == "The Book Title")
        #expect(NameCleaner.fileSystemName(from: #"A/B: C? <D>"#) == "A-B- C- -D-")
    }

    @MainActor @Test func chapterFileParserReadsJSONChapters() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try """
        {"chapters":[{"title":"Opening","start":"00:00:00"},{"title":"Part One","start":75.5}]}
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let drafts = try ChapterFileParser.parse(url: url)

        #expect(drafts.map { $0.title } == ["Opening", "Part One"])
        #expect(drafts.map { $0.startTime } == [0, 75.5])
    }

    @MainActor @Test func chapterFileParserReadsCSVChapters() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("csv")
        try """
        title,start
        Opening,00:00:00
        Chapter 1,00:10:30
        """.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let drafts = try ChapterFileParser.parse(url: url)

        #expect(drafts.map { $0.title } == ["Opening", "Chapter 1"])
        #expect(drafts.map { $0.startTime } == [0, 630])
    }

    @MainActor @Test func conversionServiceCreatesM4BFromChapterFiles() async throws {
        guard let ffmpeg = FFmpegToolLocator.ffmpegURL() else { return }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("01-Intro.mp3")
        let second = root.appendingPathComponent("02-Chapter.mp3")
        try run(ffmpeg, ["-hide_banner", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=0.35", "-q:a", "9", first.path])
        try run(ffmpeg, ["-hide_banner", "-y", "-f", "lavfi", "-i", "sine=frequency=660:duration=0.35", "-q:a", "9", second.path])

        var project = AudiobookProject(
            title: "Smoke Test Book",
            author: "M4B Forge",
            chapters: [
                Chapter(title: "Intro", sourceURL: first, duration: 0.35, startTime: 0),
                Chapter(title: "Chapter", sourceURL: second, duration: 0.35, startTime: 0.35)
            ],
            sourceFolderURL: root
        )
        project.settings.outputFolderURL = root
        project.settings.outputIntoProjectFolder = false
        project.settings.overwriteExisting = true

        let output = try await FFmpegConversionService().convert(project: project) { _, _ in }

        #expect(output.pathExtension == "m4b")
        #expect(FileManager.default.fileExists(atPath: output.path))
        let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        #expect((size?.intValue ?? 0) > 0)
    }

    @MainActor @Test func largeFixtureConvertsWhenEnabled() async throws {
        let enableFixtureURL = URL(fileURLWithPath: "/Users/techmore/projects/tm-ebook-converter/.run-large-fixture")
        guard FileManager.default.fileExists(atPath: enableFixtureURL.path) else { return }

        let fixture = URL(fileURLWithPath: "/Users/techmore/projects/tm-ebook-converter/Test-ebook", isDirectory: true)
        guard FileManager.default.fileExists(atPath: fixture.path) else { return }

        let candidate = try #require(ImportScanner.candidates(from: [fixture]).first)
        let sourceURL = try #require(candidate.audioFiles.first)
        let duration = try await FFprobeService().duration(for: sourceURL)
        let chapters = ChapterPlanner.rebuildSingleFileDurations(
            candidate.chapterDrafts.map {
                Chapter(title: $0.title, sourceURL: sourceURL, duration: 0, startTime: $0.startTime, manualStartTime: $0.startTime)
            },
            totalDuration: duration
        )

        let outputRoot = FileManager.default.temporaryDirectory.appendingPathComponent("M4BForge-Fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        var project = AudiobookProject(
            sourceMode: .singleFile,
            title: candidate.title,
            chapters: chapters,
            coverArtURL: candidate.coverArtURL,
            sourceFolderURL: fixture,
            singleSourceURL: sourceURL,
            sourceDuration: duration
        )
        project.description = candidate.metadataDraft.description
        project.settings.outputFolderURL = outputRoot
        project.settings.outputIntoProjectFolder = false
        project.settings.overwriteExisting = true
        project.settings.allowStreamCopy = true

        let output = try await FFmpegConversionService().convert(project: project) { _, _ in }

        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect((try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0 > 1_000_000)
    }

    private func run(_ executableURL: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw ConversionError.conversionFailed(output)
        }
    }

}
