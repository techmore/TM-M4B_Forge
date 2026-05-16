import Foundation

enum SecurityScopedBookmarkStore {
    private static let filename = "SecurityScopedBookmarks.json"
    private static var activeAccessPaths: Set<String> = []

    static func persistAccess(for urls: [URL]) {
        var bookmarks = loadBookmarks()

        for url in urls {
            do {
                let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                bookmarks[key(for: url)] = data
            } catch {
                continue
            }
        }

        saveBookmarks(bookmarks)
    }

    @discardableResult
    static func startAccessing(_ urls: [URL]) -> [String] {
        urls.compactMap { startAccessing($0) }
    }

    @discardableResult
    static func startAccessing(_ url: URL?) -> String? {
        guard let url else { return nil }
        let key = key(for: url)
        if activeAccessPaths.contains(key) {
            return nil
        }

        if url.startAccessingSecurityScopedResource() {
            activeAccessPaths.insert(key)
            return "Access granted: \(url.path)"
        }

        return "No security scope granted for \(url.path). If conversion fails, import with the Import Folder button instead of drag/drop."
    }

    @discardableResult
    static func restoreAccess(to url: URL?) -> Bool {
        guard let url else { return false }
        let bookmarks = loadBookmarks()
        guard let data = bookmarks[key(for: url)] else { return false }

        do {
            var isStale = false
            let resolved = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            if isStale {
                persistAccess(for: [resolved])
            }
            _ = startAccessing(resolved)
            return true
        } catch {
            return false
        }
    }

    static func persistAccess(for project: AudiobookProject) {
        persistAccess(for: urls(in: project))
    }

    static func restoreAccess(for project: AudiobookProject) {
        for url in urls(in: project) {
            _ = restoreAccess(to: url)
        }
    }

    private static func urls(in project: AudiobookProject) -> [URL] {
        var urls = project.chapters.map(\.sourceURL)
        urls.append(contentsOf: [project.coverArtURL, project.sourceFolderURL, project.singleSourceURL, project.outputURL, project.settings.outputFolderURL].compactMap { $0 })
        return Array(Set(urls))
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func loadBookmarks() -> [String: Data] {
        guard let data = try? Data(contentsOf: storeURL()) else { return [:] }
        return (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    private static func saveBookmarks(_ bookmarks: [String: Data]) {
        do {
            let url = storeURL()
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(bookmarks)
            try data.write(to: url, options: .atomic)
        } catch {
            return
        }
    }

    private static func storeURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        return base
            .appendingPathComponent("M4B Forge", isDirectory: true)
            .appendingPathComponent(filename)
    }
}
