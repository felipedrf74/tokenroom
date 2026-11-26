import Foundation

extension BlockingIO {
    struct ProcessOutput: Sendable {
        var status: Int32
        var stdout: Data
        var timedOut: Bool

        var succeeded: Bool {
            !timedOut && status == 0
        }
    }

    static func runProcess(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval = 5,
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        input: Data? = nil,
        maxOutput: Int = 16 * 1024 * 1024
    ) -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }
        if let environment {
            process.environment = environment
        }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return ProcessOutput(status: -1, stdout: Data(), timedOut: false)
        }

        let collected = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        let reader = stdout.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while let chunk = try? reader.read(upToCount: 64 * 1024), !chunk.isEmpty {
                if collected.append(chunk) > maxOutput {
                    process.terminate()
                    break
                }
            }
            drained.signal()
        }
        if let input, let stdin {
            let writer = stdin.fileHandleForWriting
            writer.write(input)
            try? writer.close()
        }

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        if drained.wait(timeout: .now() + 1) == .timedOut {
            try? reader.close()
            _ = drained.wait(timeout: .now() + 1)
        }
        return ProcessOutput(
            status: timedOut ? -1 : process.terminationStatus,
            stdout: collected.data,
            timedOut: timedOut
        )
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Data()

        var data: Data {
            lock.withLock { value }
        }

        func append(_ chunk: Data) -> Int {
            lock.withLock {
                value.append(chunk)
                return value.count
            }
        }
    }
}
