import Foundation

actor FFprobeService {
    private let runner = ProcessRunner()

    func duration(for url: URL) async throws -> TimeInterval {
        guard let ffprobe = FFmpegToolLocator.ffprobeURL() else {
            throw ConversionError.missingTool("ffprobe")
        }

        let result = try await runner.run(
            executableURL: ffprobe,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                url.path
            ]
        )

        guard result.terminationStatus == 0,
              let value = Double(result.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ConversionError.probeFailed(url.lastPathComponent, result.output)
        }

        return value
    }
}
