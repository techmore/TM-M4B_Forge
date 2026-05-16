import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppViewModel: ObservableObject {
    @Published var projects: [AudiobookProject] = []
    @Published var selectedProjectID: AudiobookProject.ID?
    @Published var jobs: [ConversionJob] = []
    @Published var defaults = AppDefaults()
    @Published var logMessages: [String] = []
    @Published var isImporting = false
    @Published var importCandidates: [ImportCandidate] = []
    @Published var autoApproveImports = false
    @Published var isQueueRunning = false

    private let ffprobe = FFprobeService()
    private let converter = FFmpegConversionService()
    private var queueTask: Task<Void, Never>?

    init() {
        if defaults.outputFolderURL == nil {
            defaults.outputFolderURL = Self.downloadsFolderURL()
        }
    }

    var selectedProject: AudiobookProject? {
        get { projects.first { $0.id == selectedProjectID } }
        set {
            guard let newValue, let index = projects.firstIndex(where: { $0.id == newValue.id }) else { return }
            projects[index] = newValue
        }
    }

    func importFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        if panel.runModal() == .OK {
            SecurityScopedBookmarkStore.persistAccess(for: panel.urls)
            prepareImportReview(panel.urls)
        }
    }

    func importAudioFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .mpeg4Audio, UTType(filenameExtension: "mp3") ?? .audio]
        panel.prompt = "Import"
        if panel.runModal() == .OK {
            SecurityScopedBookmarkStore.persistAccess(for: panel.urls)
            prepareImportReview(panel.urls)
        }
    }

    func importSingleFileForChaptering() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .mpeg4Audio, UTType(filenameExtension: "mp3") ?? .audio]
        panel.prompt = "Chapter"
        if panel.runModal() == .OK, let url = panel.url {
            SecurityScopedBookmarkStore.persistAccess(for: [url])
            Task { await importSingleFile(url) }
        }
    }

    func prepareImportReview(_ urls: [URL]) {
        SecurityScopedBookmarkStore.persistAccess(for: urls)
        isImporting = true
        Task.detached(priority: .userInitiated) { [urls] in
            let candidates = ImportScanner.candidates(from: urls)
            await MainActor.run {
                self.isImporting = false

                guard !candidates.isEmpty else {
                    self.appendLog("No supported files found.")
                    return
                }

                self.importCandidates = candidates
                self.selectedProjectID = nil
                self.appendLog("Reviewed \(candidates.count) import candidate\(candidates.count == 1 ? "" : "s").")

                if self.autoApproveImports {
                    Task { await self.approveSelectedImportCandidates(addToQueue: true) }
                }
            }
        }
    }

    func setImportCandidateSelection(_ id: ImportCandidate.ID, isSelected: Bool) {
        guard let index = importCandidates.firstIndex(where: { $0.id == id }) else { return }
        importCandidates[index].isSelected = isSelected
    }

    func applyChapterTemplate(_ template: ChapterTemplateKind, to id: ImportCandidate.ID) {
        guard let index = importCandidates.firstIndex(where: { $0.id == id }),
              importCandidates[index].supportsChapterTemplate
        else { return }
        importCandidates[index].chapterDrafts = template.drafts
    }

    func clearChapterTemplate(for id: ImportCandidate.ID) {
        guard let index = importCandidates.firstIndex(where: { $0.id == id }) else { return }
        importCandidates[index].chapterDrafts.removeAll()
    }

    func importChapterFile(for id: ImportCandidate.ID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.json,
            UTType.commaSeparatedText,
            UTType(filenameExtension: "tsv") ?? .plainText
        ]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Chapters"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let drafts = try ChapterFileParser.parse(url: url)
                guard let index = importCandidates.firstIndex(where: { $0.id == id }) else { return }
                importCandidates[index].chapterDrafts = drafts
                appendLog("Imported \(drafts.count) chapter candidates from \(url.lastPathComponent).")
            } catch {
                appendLog(error.localizedDescription)
            }
        }
    }

    func chooseCoverArt(for id: ImportCandidate.ID) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Cover"
        if panel.runModal() == .OK, let url = panel.url {
            SecurityScopedBookmarkStore.persistAccess(for: [url])
            setCoverArt(url, for: id)
        }
    }

    func setCoverArt(_ url: URL?, for id: ImportCandidate.ID) {
        guard let index = importCandidates.firstIndex(where: { $0.id == id }) else { return }
        importCandidates[index].coverArtURL = url
    }

    func addChapterDraft(to id: ImportCandidate.ID) {
        guard let index = importCandidates.firstIndex(where: { $0.id == id }) else { return }
        let lastStart = importCandidates[index].chapterDrafts.map(\.startTime).max() ?? 0
        importCandidates[index].chapterDrafts.append(ChapterDraft(
            title: "Chapter \(importCandidates[index].chapterDrafts.count + 1)",
            startTime: lastStart + 600
        ))
    }

    func updateChapterDraft(candidateID: ImportCandidate.ID, draftID: ChapterDraft.ID, title: String? = nil, startTime: TimeInterval? = nil) {
        guard let candidateIndex = importCandidates.firstIndex(where: { $0.id == candidateID }),
              let draftIndex = importCandidates[candidateIndex].chapterDrafts.firstIndex(where: { $0.id == draftID })
        else { return }
        if let title {
            importCandidates[candidateIndex].chapterDrafts[draftIndex].title = title
        }
        if let startTime {
            importCandidates[candidateIndex].chapterDrafts[draftIndex].startTime = max(0, startTime)
        }
        importCandidates[candidateIndex].chapterDrafts.sort { $0.startTime < $1.startTime }
    }

    func removeChapterDraft(candidateID: ImportCandidate.ID, draftID: ChapterDraft.ID) {
        guard let candidateIndex = importCandidates.firstIndex(where: { $0.id == candidateID }) else { return }
        importCandidates[candidateIndex].chapterDrafts.removeAll { $0.id == draftID }
    }

    func updateMetadataDraft(_ id: ImportCandidate.ID, _ update: (inout BookMetadataDraft) -> Void) {
        guard let index = importCandidates.firstIndex(where: { $0.id == id }) else { return }
        update(&importCandidates[index].metadataDraft)
    }

    func approveSelectedImportCandidates(addToQueue: Bool = false) async {
        let selected = importCandidates.filter { $0.isSelected && !$0.audioFiles.isEmpty }
        guard !selected.isEmpty else {
            appendLog("No import candidates selected.")
            return
        }

        for candidate in selected {
            await createProject(from: candidate)
            if addToQueue, let project = selectedProject {
                jobs.append(ConversionJob(project: project))
            }
            if let index = importCandidates.firstIndex(where: { $0.id == candidate.id }) {
                importCandidates[index].status = .approved
                importCandidates[index].isSelected = false
            }
        }
    }

    func clearImportReview() {
        importCandidates.removeAll()
    }

    func importURLs(_ urls: [URL]) async {
        isImporting = true
        defer { isImporting = false }

        let audioFiles = collectAudioFiles(from: urls)
        guard !audioFiles.isEmpty else {
            appendLog("No supported audio files found.")
            return
        }

        var chapters: [Chapter] = []
        var cursor: TimeInterval = 0
        for file in FilenameOrdering.sortedAudioFiles(from: audioFiles) {
            let duration = (try? await ffprobe.duration(for: file)) ?? 0
            chapters.append(Chapter(title: FilenameOrdering.chapterTitle(from: file), sourceURL: file, duration: duration, startTime: cursor))
            cursor += duration
        }

        let folder = urls.first(where: { $0.hasDirectoryPath })
        var project = AudiobookProject(
            title: folder?.lastPathComponent ?? audioFiles.first?.deletingLastPathComponent().lastPathComponent ?? "Untitled Audiobook",
            chapters: chapters,
            sourceFolderURL: folder
        )
        project.settings = ConversionSettings(
            bitrateKbps: defaults.bitrateKbps,
            sampleRate: defaults.sampleRate,
            allowStreamCopy: defaults.allowStreamCopy,
            overwriteExisting: defaults.overwriteExisting,
            outputIntoProjectFolder: defaults.outputIntoProjectFolder,
            cleanOutputNames: defaults.cleanOutputNames,
            outputFolderURL: defaults.outputFolderURL
        )

        projects.append(project)
        selectedProjectID = project.id
        appendLog("Imported \(chapters.count) chapter files.")
    }

    func createProject(from candidate: ImportCandidate) async {
        switch candidate.kind {
        case .singleAudioFile:
            guard let url = candidate.audioFiles.first else { return }
            await importSingleFile(url)
            updateSelectedProject { project in
                project.title = candidate.title
                project.coverArtURL = candidate.coverArtURL
                applyChapterDrafts(candidate.chapterDrafts, to: &project)
                applyMetadataDraft(candidate.metadataDraft, to: &project)
                project.settings.outputFolderURL = defaults.outputFolderURL
                project.settings.overwriteExisting = defaults.overwriteExisting
                project.settings.outputIntoProjectFolder = defaults.outputIntoProjectFolder
                project.settings.cleanOutputNames = defaults.cleanOutputNames
            }
        case .audiobookFolder, .audioFiles:
            await importAudioFiles(candidate.audioFiles, title: candidate.title, sourceFolder: candidate.rootURL, coverArt: candidate.coverArtURL)
            updateSelectedProject { project in
                applyMetadataDraft(candidate.metadataDraft, to: &project)
            }
        case .unsupported:
            appendLog("Skipped unsupported import: \(candidate.title).")
        }
    }

    func importAudioFiles(_ audioFiles: [URL], title: String, sourceFolder: URL?, coverArt: URL?) async {
        isImporting = true
        defer { isImporting = false }

        let sortedFiles = FilenameOrdering.sortedAudioFiles(from: audioFiles)
        guard !sortedFiles.isEmpty else {
            appendLog("No supported audio files found.")
            return
        }

        var chapters: [Chapter] = []
        var cursor: TimeInterval = 0
        for file in sortedFiles {
            let duration = (try? await ffprobe.duration(for: file)) ?? 0
            chapters.append(Chapter(title: FilenameOrdering.chapterTitle(from: file), sourceURL: file, duration: duration, startTime: cursor))
            cursor += duration
        }

        var project = AudiobookProject(
            title: title,
            chapters: chapters,
            coverArtURL: coverArt,
            sourceFolderURL: sourceFolder
        )
        project.settings = ConversionSettings(
            bitrateKbps: defaults.bitrateKbps,
            sampleRate: defaults.sampleRate,
            allowStreamCopy: defaults.allowStreamCopy,
            overwriteExisting: defaults.overwriteExisting,
            outputIntoProjectFolder: defaults.outputIntoProjectFolder,
            cleanOutputNames: defaults.cleanOutputNames,
            outputFolderURL: defaults.outputFolderURL
        )

        projects.append(project)
        selectedProjectID = project.id
        appendLog("Imported \(chapters.count) chapter files for \(project.displayTitle).")
    }

    func importSingleFile(_ url: URL) async {
        isImporting = true
        defer { isImporting = false }

        let duration = (try? await ffprobe.duration(for: url)) ?? 0
        let projectTitle = FilenameOrdering.chapterTitle(from: url)
        var project = AudiobookProject(
            sourceMode: .singleFile,
            title: projectTitle,
            chapters: [Chapter(title: "Chapter 1", sourceURL: url, duration: duration, startTime: 0)],
            sourceFolderURL: url.deletingLastPathComponent(),
            singleSourceURL: url,
            sourceDuration: duration
        )
        project.settings = ConversionSettings(
            bitrateKbps: defaults.bitrateKbps,
            sampleRate: defaults.sampleRate,
            allowStreamCopy: defaults.allowStreamCopy,
            overwriteExisting: defaults.overwriteExisting,
            outputIntoProjectFolder: defaults.outputIntoProjectFolder,
            cleanOutputNames: defaults.cleanOutputNames,
            outputFolderURL: defaults.outputFolderURL
        )

        projects.append(project)
        selectedProjectID = project.id
        appendLog("Imported single file for chaptering: \(url.lastPathComponent).")
    }

    func splitSelectedProject(every intervalMinutes: Int) {
        guard intervalMinutes > 0 else { return }
        updateSelectedProject { project in
            guard project.sourceMode == .singleFile,
                  let sourceURL = project.singleSourceURL ?? project.chapters.first?.sourceURL,
                  let totalDuration = project.sourceDuration ?? project.chapters.map({ $0.effectiveStartTime + $0.duration }).max()
            else { return }

            project.chapters = ChapterPlanner.chapters(for: sourceURL, totalDuration: totalDuration, intervalMinutes: intervalMinutes)
        }
        appendLog("Generated chapters every \(intervalMinutes) minutes.")
    }

    func importChapterFileForSelectedProject() {
        guard selectedProject != nil else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.json,
            UTType.commaSeparatedText,
            UTType(filenameExtension: "tsv") ?? .plainText
        ]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Import Chapters"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let drafts = try ChapterFileParser.parse(url: url)
                updateSelectedProject { project in
                    applyChapterDrafts(drafts, to: &project)
                }
                appendLog("Imported \(drafts.count) chapter candidates from \(url.lastPathComponent).")
            } catch {
                appendLog(error.localizedDescription)
            }
        }
    }

    func addChapterBoundary(at startTime: TimeInterval) {
        updateSelectedProject { project in
            guard project.sourceMode == .singleFile,
                  let sourceURL = project.singleSourceURL ?? project.chapters.first?.sourceURL else { return }
            let boundedStart = max(0, min(startTime, project.timelineDuration))
            project.chapters.append(Chapter(title: "Chapter \(project.chapters.count + 1)", sourceURL: sourceURL, duration: 0, startTime: boundedStart, manualStartTime: boundedStart))
            project.chapters.sort { $0.effectiveStartTime < $1.effectiveStartTime }
            rebuildSingleFileDurations(&project, totalDuration: project.timelineDuration)
        }
    }

    func moveChapterBoundary(chapterID: Chapter.ID, to startTime: TimeInterval) {
        updateSelectedProject { project in
            guard project.sourceMode == .singleFile,
                  let index = project.chapters.firstIndex(where: { $0.id == chapterID }),
                  index != project.chapters.startIndex else { return }
            let boundedStart = max(0, min(startTime, project.timelineDuration))
            project.chapters[index].manualStartTime = boundedStart
            project.chapters[index].startTime = boundedStart
            rebuildSingleFileDurations(&project, totalDuration: project.timelineDuration)
        }
    }

    func updateSelectedProject(_ update: (inout AudiobookProject) -> Void) {
        guard let index = projects.firstIndex(where: { $0.id == selectedProjectID }) else { return }
        update(&projects[index])
        projects[index].updatedAt = Date()
        recalculateChapterStarts(projectIndex: index)
    }

    func moveChapters(from offsets: IndexSet, to destination: Int) {
        updateSelectedProject { project in
            project.chapters.move(fromOffsets: offsets, toOffset: destination)
        }
    }

    func removeChapters(at offsets: IndexSet) {
        updateSelectedProject { project in
            project.chapters.remove(atOffsets: offsets)
        }
    }

    func setCoverArt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                SecurityScopedBookmarkStore.persistAccess(for: [url])
                updateSelectedProject { $0.coverArtURL = url }
            }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            SecurityScopedBookmarkStore.persistAccess(for: [url])
            updateSelectedProject { $0.settings.outputFolderURL = url }
        }
    }

    func ensureDefaultOutputFolderSelected() -> Bool {
        if let outputFolder = defaults.outputFolderURL {
            _ = SecurityScopedBookmarkStore.restoreAccess(to: outputFolder)
            return true
        }

        if let downloads = Self.downloadsFolderURL() {
            defaults.outputFolderURL = downloads
            appendLog("Export folder defaulted to Downloads: \(downloads.path).")
            return true
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use for Exports"
        panel.message = "Choose where M4B Forge should write completed audiobooks."

        guard panel.runModal() == .OK, let url = panel.url else {
            appendLog("Conversion canceled: choose an export folder before queueing.")
            return false
        }

        SecurityScopedBookmarkStore.persistAccess(for: [url])
        defaults.outputFolderURL = url
        appendLog("Export folder set to \(url.path).")
        return true
    }

    static func downloadsFolderURL() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    func enqueueSelectedProject() {
        guard let project = selectedProject else { return }
        if jobs.contains(where: { $0.project.id == project.id && ($0.status == .queued || $0.status == .running) }) {
            appendLog("\(project.displayTitle) is already queued.")
            return
        }
        jobs.append(ConversionJob(project: project))
    }

    func convertSelectedProject() async {
        guard let project = selectedProject else { return }
        if let existingIndex = jobs.firstIndex(where: { $0.project.id == project.id && ($0.status == .queued || $0.status == .running) }) {
            await convertJob(at: existingIndex)
        } else {
            jobs.append(ConversionJob(project: project))
            await convertJob(at: jobs.index(before: jobs.endIndex))
        }
    }

    private func convertJob(at index: Int) async {
        guard jobs.indices.contains(index) else { return }

        jobs[index].status = .running
        jobs[index].progress = 0
        jobs[index].estimatedRemaining = nil
        jobs[index].log.removeAll()

        let project = jobs[index].project
        let jobID = jobs[index].id
        SecurityScopedBookmarkStore.persistAccess(for: project)
        SecurityScopedBookmarkStore.restoreAccess(for: project)
        appendLog("Starting \(project.displayTitle): \(project.chapters.count) chapters, \(DurationFormatter.positional(project.timelineDuration)).")

        do {
            let started = Date()
            let output = try await converter.convert(project: project) { [jobID, started] progress, log in
                Task { @MainActor [weak self] in
                    guard let self, let index = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                    self.jobs[index].progress = progress
                    self.jobs[index].estimatedRemaining = progress > 0 ? Date().timeIntervalSince(started) * (1 - progress) / progress : nil
                    if !log.isEmpty {
                        self.jobs[index].log += log + "\n"
                    }
                }
            }
            guard let completedIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            jobs[completedIndex].status = .completed
            jobs[completedIndex].progress = 1
            jobs[completedIndex].outputURL = output
            appendLog("Created \(output.path).")
        } catch is CancellationError {
            guard let canceledIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            jobs[canceledIndex].status = .canceled
            jobs[canceledIndex].log += "Canceled by user.\n"
            appendLog("Canceled \(jobs[canceledIndex].project.displayTitle).")
        } catch {
            guard let failedIndex = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            jobs[failedIndex].status = .failed
            let message = "Failed \(jobs[failedIndex].project.displayTitle): \(error.localizedDescription)"
            jobs[failedIndex].log += message + "\n"
            appendLog(message)
        }
    }

    func startQueue() {
        guard !isQueueRunning else { return }
        queueTask = Task { [weak self] in
            await self?.runQueue()
        }
    }

    func cancelQueue() {
        queueTask?.cancel()
        queueTask = nil
    }

    func runQueue() async {
        guard !isQueueRunning else { return }
        isQueueRunning = true
        defer {
            isQueueRunning = false
            queueTask = nil
        }

        while let index = jobs.firstIndex(where: { $0.status == .queued }) {
            if Task.isCancelled { break }
            await convertJob(at: index)
        }
    }

    func saveProject() {
        guard let project = selectedProject else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m4bforge") ?? .json]
        panel.nameFieldStringValue = "\(project.displayTitle).m4bforge"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                SecurityScopedBookmarkStore.persistAccess(for: project)
                let data = try JSONEncoder.pretty.encode(project)
                try data.write(to: url)
                appendLog("Saved project to \(url.path).")
            } catch {
                appendLog(error.localizedDescription)
            }
        }
    }

    func saveProjectStatus() {
        guard let project = selectedProject else { return }
        do {
            SecurityScopedBookmarkStore.persistAccess(for: project)
            let folder = autosaveFolderURL()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let filename = NameCleaner.fileSystemName(from: project.displayTitle) + ".m4bforge"
            let url = folder.appendingPathComponent(filename)
            let data = try JSONEncoder.pretty.encode(project)
            try data.write(to: url, options: .atomic)
            appendLog("Saved project status to \(url.path).")
        } catch {
            appendLog(error.localizedDescription)
        }
    }

    func loadProjectStatus() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m4bforge") ?? .json]
        panel.directoryURL = autosaveFolderURL()
        panel.prompt = "Restore"
        if panel.runModal() == .OK, let url = panel.url {
            loadProject(from: url)
        }
    }

    func loadProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "m4bforge") ?? .json]
        if panel.runModal() == .OK, let url = panel.url {
            loadProject(from: url)
        }
    }

    private func loadProject(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            var project = try JSONDecoder().decode(AudiobookProject.self, from: data)
            project.id = UUID()
            SecurityScopedBookmarkStore.restoreAccess(for: project)
            projects.append(project)
            selectedProjectID = project.id
            appendLog("Loaded project from \(url.path).")
        } catch {
            appendLog(error.localizedDescription)
        }
    }

    private func collectAudioFiles(from urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            if url.hasDirectoryPath {
                let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                return contents.filter { FilenameOrdering.supportedAudioExtensions.contains($0.pathExtension.lowercased()) }
            }
            return [url]
        }
    }

    private func autosaveFolderURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("M4B Forge", isDirectory: true)
            .appendingPathComponent("Saved Project Status", isDirectory: true)
    }

    private func recalculateChapterStarts(projectIndex: Int) {
        if projects[projectIndex].sourceMode == .singleFile {
            rebuildSingleFileDurations(&projects[projectIndex])
            return
        }

        var cursor: TimeInterval = 0
        for chapterIndex in projects[projectIndex].chapters.indices {
            projects[projectIndex].chapters[chapterIndex].startTime = cursor
            if projects[projectIndex].chapters[chapterIndex].manualStartTime == nil {
                cursor += projects[projectIndex].chapters[chapterIndex].duration
            } else {
                cursor = projects[projectIndex].chapters[chapterIndex].effectiveStartTime + projects[projectIndex].chapters[chapterIndex].duration
            }
        }
    }

    private func rebuildSingleFileDurations(_ project: inout AudiobookProject, totalDuration explicitTotalDuration: TimeInterval? = nil) {
        guard project.sourceMode == .singleFile else { return }
        let totalDuration = explicitTotalDuration ?? project.sourceDuration ?? project.chapters.map { $0.effectiveStartTime + $0.duration }.max() ?? project.duration
        project.chapters = ChapterPlanner.rebuildSingleFileDurations(project.chapters, totalDuration: totalDuration)
    }

    private func applyChapterDrafts(_ drafts: [ChapterDraft], to project: inout AudiobookProject) {
        guard project.sourceMode == .singleFile,
              let sourceURL = project.singleSourceURL ?? project.chapters.first?.sourceURL,
              !drafts.isEmpty
        else { return }

        let totalDuration = max(1, project.sourceDuration ?? project.duration)
        let boundedDrafts = drafts
            .map { draft in
                ChapterDraft(title: draft.title, startTime: min(max(0, draft.startTime), max(0, totalDuration - 1)))
            }
            .sorted { $0.startTime < $1.startTime }

        var uniqueStarts = Set<Int>()
        project.chapters = boundedDrafts.compactMap { draft in
            let roundedStart = Int(draft.startTime.rounded())
            guard uniqueStarts.insert(roundedStart).inserted else { return nil }
            return Chapter(title: draft.title, sourceURL: sourceURL, duration: 0, startTime: draft.startTime, manualStartTime: draft.startTime)
        }

        if project.chapters.isEmpty {
            project.chapters = [Chapter(title: "Chapter 1", sourceURL: sourceURL, duration: totalDuration, startTime: 0)]
        }
        rebuildSingleFileDurations(&project, totalDuration: totalDuration)
    }

    private func applyMetadataDraft(_ draft: BookMetadataDraft, to project: inout AudiobookProject) {
        if !draft.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            project.description = draft.description
        }
        if !draft.genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            project.genre = draft.genre
        }
        project.publisher = draft.publisher
        project.isbn = draft.isbn
        project.language = draft.language
        project.copyright = draft.copyright
        project.series = draft.series
        project.seriesNumber = draft.seriesNumber
    }

    private func appendLog(_ message: String) {
        logMessages.append("[\(Date().formatted(date: .omitted, time: .standard))] \(message)")
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
