import Foundation

enum ImportScanner {
    struct Limits {
        var maxFilesPerRoot = 2_500
        var warningBytes: Int64 = 100 * 1_024 * 1_024 * 1_024

        nonisolated init(maxFilesPerRoot: Int = 2_500, warningBytes: Int64 = 100 * 1_024 * 1_024 * 1_024) {
            self.maxFilesPerRoot = maxFilesPerRoot
            self.warningBytes = warningBytes
        }
    }

    nonisolated static func candidates(from urls: [URL], limits: Limits = Limits()) -> [ImportCandidate] {
        var candidates: [ImportCandidate] = []

        for url in urls {
            if url.hasDirectoryPath {
                candidates.append(contentsOf: scanDirectory(url, limits: limits))
            } else if FilenameOrdering.supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                let bytes = fileSize(url)
                candidates.append(ImportCandidate(
                    kind: .singleAudioFile,
                    title: FilenameOrdering.chapterTitle(from: url),
                    rootURL: url,
                    audioFiles: [url],
                    coverArtURL: nil,
                    totalBytes: bytes,
                    warnings: sizeWarnings(bytes: bytes, truncated: false, limits: limits)
                ))
            } else {
                candidates.append(ImportCandidate(
                    kind: .unsupported,
                    title: url.lastPathComponent,
                    rootURL: url,
                    audioFiles: [],
                    coverArtURL: nil,
                    totalBytes: fileSize(url),
                    status: .skipped,
                    isSelected: false,
                    warnings: ["Unsupported file type"]
                ))
            }
        }

        return mergeLooseAudioFiles(candidates)
    }

    private nonisolated static func scanDirectory(_ root: URL, limits: Limits) -> [ImportCandidate] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let directAudio = FilenameOrdering.sortedAudioFiles(from: children)
        if !directAudio.isEmpty {
            return [candidate(for: root, audioFiles: directAudio, limits: limits)]
        }

        let childDirectories = children.filter { url in
            ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }

        var results: [ImportCandidate] = []
        for directory in childDirectories {
            let audioFiles = recursiveAudioFiles(in: directory, limits: limits)
            if !audioFiles.files.isEmpty {
                var candidate = candidate(for: directory, audioFiles: audioFiles.files, limits: limits)
                if audioFiles.truncated {
                    candidate.warnings.append("Scan stopped at \(limits.maxFilesPerRoot) files")
                }
                results.append(candidate)
            }
        }

        if results.isEmpty {
            return [ImportCandidate(
                kind: .unsupported,
                title: root.lastPathComponent,
                rootURL: root,
                audioFiles: [],
                coverArtURL: nil,
                totalBytes: 0,
                status: .skipped,
                isSelected: false,
                warnings: ["No supported audio files found"]
            )]
        }

        return results
    }

    private nonisolated static func candidate(for root: URL, audioFiles: [URL], limits: Limits) -> ImportCandidate {
        let sorted = FilenameOrdering.sortedAudioFiles(from: audioFiles)
        let bytes = sorted.map(fileSize).reduce(0, +)
        let cover = findCoverArt(near: root)
        var warnings = sizeWarnings(bytes: bytes, truncated: false, limits: limits)
        if sorted.count == 1 {
            warnings.append("Detected as a single long audio file")
        }

        return ImportCandidate(
            kind: sorted.count == 1 ? .singleAudioFile : .audiobookFolder,
            title: root.lastPathComponent,
            rootURL: root,
            audioFiles: sorted,
            coverArtURL: cover,
            totalBytes: bytes,
            status: warnings.isEmpty ? .pending : .warning,
            warnings: warnings
        )
    }

    private nonisolated static func recursiveAudioFiles(in root: URL, limits: Limits) -> (files: [URL], truncated: Bool) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return ([], false)
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if FilenameOrdering.supportedAudioExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
                if files.count >= limits.maxFilesPerRoot {
                    return (files, true)
                }
            }
        }
        return (files, false)
    }

    private nonisolated static func mergeLooseAudioFiles(_ candidates: [ImportCandidate]) -> [ImportCandidate] {
        let looseFiles = candidates.filter { $0.kind == .singleAudioFile && !$0.rootURL.hasDirectoryPath }
        let others = candidates.filter { !looseFiles.contains($0) }
        guard looseFiles.count > 1 else { return candidates }

        let audioFiles = looseFiles.flatMap(\.audioFiles)
        let bytes = looseFiles.map(\.totalBytes).reduce(0, +)
        let parent = audioFiles.first?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")
        let merged = ImportCandidate(
            kind: .audioFiles,
            title: parent.lastPathComponent.isEmpty ? "Dropped Audio Files" : parent.lastPathComponent,
            rootURL: parent,
            audioFiles: FilenameOrdering.sortedAudioFiles(from: audioFiles),
            coverArtURL: findCoverArt(near: parent),
            totalBytes: bytes,
            warnings: []
        )
        return others + [merged]
    }

    private nonisolated static func findCoverArt(near root: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents.first { url in
            FilenameOrdering.supportedImageExtensions.contains(url.pathExtension.lowercased()) &&
            ["cover", "folder", "front", "artwork"].contains(url.deletingPathExtension().lastPathComponent.lowercased())
        }
    }

    private nonisolated static func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey])
        return Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    private nonisolated static func sizeWarnings(bytes: Int64, truncated: Bool, limits: Limits) -> [String] {
        var warnings: [String] = []
        if bytes >= limits.warningBytes {
            warnings.append("Large import: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
        }
        if truncated {
            warnings.append("Scan was limited")
        }
        return warnings
    }
}
