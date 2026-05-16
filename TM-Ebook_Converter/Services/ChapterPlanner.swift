import Foundation

enum ChapterPlanner {
    nonisolated static func chapters(
        for sourceURL: URL,
        totalDuration: TimeInterval,
        intervalMinutes: Int
    ) -> [Chapter] {
        guard intervalMinutes > 0, totalDuration > 0 else { return [] }

        let interval = TimeInterval(intervalMinutes * 60)
        var chapters: [Chapter] = []
        var cursor: TimeInterval = 0
        var number = 1

        while cursor < totalDuration {
            let duration = min(interval, totalDuration - cursor)
            chapters.append(Chapter(title: "Chapter \(number)", sourceURL: sourceURL, duration: duration, startTime: cursor))
            cursor += duration
            number += 1
        }

        return chapters
    }

    nonisolated static func rebuildSingleFileDurations(_ chapters: [Chapter], totalDuration: TimeInterval) -> [Chapter] {
        guard totalDuration > 0 else { return chapters }
        var rebuilt = chapters.sorted { $0.effectiveStartTime < $1.effectiveStartTime }

        for index in rebuilt.indices {
            let start = max(0, min(rebuilt[index].effectiveStartTime, totalDuration))
            rebuilt[index].startTime = start
            rebuilt[index].manualStartTime = start

            let nextStart = rebuilt.indices.contains(index + 1)
                ? max(start, min(rebuilt[index + 1].effectiveStartTime, totalDuration))
                : totalDuration
            rebuilt[index].duration = max(0, nextStart - start)
        }

        return rebuilt
    }
}
