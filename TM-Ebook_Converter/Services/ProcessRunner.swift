import Foundation

struct ProcessResult {
    let terminationStatus: Int32
    let output: String
}

actor ProcessRunner {
    func run(executableURL: URL, arguments: [String]) async throws -> ProcessResult {
        try await runStreaming(executableURL: executableURL, arguments: arguments, output: { _ in })
    }

    func runStreaming(
        executableURL: URL,
        arguments: [String],
        output: @escaping @Sendable (String) -> Void
    ) async throws -> ProcessResult {
        final class ProcessBox: @unchecked Sendable {
            var process: Process?
            let lock = NSLock()

            func set(_ process: Process) {
                lock.lock()
                self.process = process
                lock.unlock()
            }

            func terminate() {
                lock.lock()
                let process = self.process
                lock.unlock()
                guard let process, process.isRunning else { return }
                process.terminate()
            }
        }

        let box = ProcessBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments

                let pipe = Pipe()
                let outputBuffer = LockedString()
                process.standardOutput = pipe
                process.standardError = pipe

                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                    outputBuffer.append(chunk)
                    output(chunk)
                }

                process.terminationHandler = { completedProcess in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                    if !remaining.isEmpty, let chunk = String(data: remaining, encoding: .utf8) {
                        outputBuffer.append(chunk)
                        output(chunk)
                    }
                    continuation.resume(returning: ProcessResult(terminationStatus: completedProcess.terminationStatus, output: outputBuffer.value))
                }

                do {
                    box.set(process)
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            box.terminate()
        }
    }
}

private final class LockedString: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var storage = ""

    nonisolated init() {}

    nonisolated var value: String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    nonisolated func append(_ string: String) {
        lock.lock()
        storage += string
        lock.unlock()
    }
}
