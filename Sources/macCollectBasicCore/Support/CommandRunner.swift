import Foundation

public struct CommandResult {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum CommandRunner {
    public static func run(
        _ executable: String,
        arguments: [String] = [],
        standardInput: String? = nil,
        cancellationToken: CancellationToken? = nil,
        timeoutSeconds: TimeInterval? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let deadline = timeoutSeconds.map { Date().addingTimeInterval($0) }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = standardInput == nil ? nil : Pipe()
        process.standardInput = stdinPipe

        var stdoutData = Data()
        var stderrData = Data()
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        try process.run()
        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        }
        while process.isRunning {
            if cancellationToken?.isCancelled == true {
                process.terminate()
                process.waitUntilExit()
                group.wait()
                throw AcquisitionError.cancelled
            }
            if let deadline, Date() >= deadline {
                process.terminate()
                process.waitUntilExit()
                group.wait()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                return CommandResult(
                    exitCode: 124,
                    stdout: stdout,
                    stderr: stderr + "\nTimed out after \(String(format: "%.1f", timeoutSeconds ?? 0))s: \(executable) \(arguments.joined(separator: " "))"
                )
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        group.wait()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    public static func runStreaming(
        _ executable: String,
        arguments: [String] = [],
        standardInput: String? = nil,
        cancellationToken: CancellationToken? = nil,
        outputHandler: @escaping (String) -> Void
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = standardInput == nil ? nil : Pipe()
        process.standardInput = stdinPipe

        let lock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            lock.lock()
            stdoutData.append(data)
            lock.unlock()
            if let text = String(data: data, encoding: .utf8) {
                outputHandler(text)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            lock.lock()
            stderrData.append(data)
            lock.unlock()
            if let text = String(data: data, encoding: .utf8) {
                outputHandler(text)
            }
        }

        try process.run()
        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            stdinPipe.fileHandleForWriting.closeFile()
        }

        while process.isRunning {
            if cancellationToken?.isCancelled == true {
                process.terminate()
                process.waitUntilExit()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                throw AcquisitionError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        Thread.sleep(forTimeInterval: 0.1)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        lock.lock()
        stdoutData.append(remainingStdout)
        stderrData.append(remainingStderr)
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        lock.unlock()

        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
