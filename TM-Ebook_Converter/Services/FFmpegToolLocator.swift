import Foundation

enum FFmpegToolLocator {
    nonisolated static func ffmpegURL() -> URL? { locate("ffmpeg") }
    nonisolated static func ffprobeURL() -> URL? { locate("ffprobe") }

    private nonisolated static func locate(_ name: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: nil),
           isRunnable(bundled) {
            return bundled
        }

        if let bundledTool = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Resources/Tools"),
           isRunnable(bundledTool) {
            return bundledTool
        }

        if let bundledTool = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Tools"),
           isRunnable(bundledTool) {
            return bundledTool
        }

        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]

        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { isRunnable($0) }
    }

    private nonisolated static func isRunnable(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }

        let process = Process()
        process.executableURL = url
        process.arguments = ["-version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
