import Foundation

final class CopyProgressMonitor {
    private let mountPath: String
    private let estimatedBytes: Int64?
    private let cancellationToken: CancellationToken?
    private let log: AcquisitionRunner.LogHandler
    private let lock = NSLock()
    private var stopped = false
    private var baselineBytes: Int64?
    private var lastLoggedPercent = -1
    private var lastLoggedAt = Date.distantPast
    private var lastObservedBytes: Int64?
    private var lastObservedAt: Date?
    private let startedAt = Date()

    init(mountPath: String, estimatedBytes: Int64?, cancellationToken: CancellationToken?, log: @escaping AcquisitionRunner.LogHandler) {
        self.mountPath = mountPath
        self.estimatedBytes = estimatedBytes
        self.cancellationToken = cancellationToken
        self.log = log
    }

    func start() {
        guard let estimatedBytes, estimatedBytes > 0 else {
            log("[progress] Copying source data; estimated byte count unavailable.")
            return
        }
        baselineBytes = usedBytes(onMountedPath: mountPath)
        lastObservedBytes = 0
        lastObservedAt = startedAt
        lastLoggedPercent = 0
        lastLoggedAt = startedAt
        log("[progress] Copying source data 0% (0 B of \(ByteCount.string(from: estimatedBytes)))")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            while !self.isStopped && self.cancellationToken?.isCancelled != true {
                Thread.sleep(forTimeInterval: 5)
                self.poll()
            }
        }
    }

    func stop(completed: Bool) {
        lock.lock()
        stopped = true
        lock.unlock()
        guard completed,
              let estimatedBytes,
              let usedBytes = usedBytes(onMountedPath: mountPath) else { return }
        let copiedBytes = max(0, usedBytes - (baselineBytes ?? 0))
        log("[progress] Copying source data complete (\(ByteCount.string(from: copiedBytes)) written into target; sizing estimate was \(ByteCount.string(from: estimatedBytes)))")
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func poll() {
        guard let estimatedBytes, estimatedBytes > 0,
              let usedBytes = usedBytes(onMountedPath: mountPath) else { return }
        let now = Date()
        let copiedBytes = max(0, usedBytes - (baselineBytes ?? 0))
        let percent = min(99, max(0, Int((Double(copiedBytes) / Double(estimatedBytes) * 100.0).rounded(.down))))
        let previousBytes = lastObservedBytes ?? copiedBytes
        let previousAt = lastObservedAt ?? startedAt
        let recentElapsed = max(1, now.timeIntervalSince(previousAt))
        let recentSpeedBytesPerSecond = max(0, Double(copiedBytes - previousBytes) / recentElapsed)
        lastObservedBytes = copiedBytes
        lastObservedAt = now

        let progressed = percent >= lastLoggedPercent + 2 || (percent > 0 && lastLoggedPercent < 0)
        let heartbeat = now.timeIntervalSince(lastLoggedAt) >= 30
        guard progressed || heartbeat else { return }
        if progressed {
            lastLoggedPercent = percent
        }
        lastLoggedAt = now
        let remainingBytes = max(0, estimatedBytes - copiedBytes)
        let etaSeconds = recentSpeedBytesPerSecond > 1 ? Int(Double(remainingBytes) / recentSpeedBytesPerSecond) : nil
        let speed = recentSpeedBytesPerSecond > 1 ? "\(ByteCount.string(from: Int64(recentSpeedBytesPerSecond)))/s" : "no recent growth"
        let eta = etaSeconds.map(Self.durationText) ?? "unknown"
        let note = progressed ? "" : ", still running"
        log("[progress] Copying source data \(percent)% (\(ByteCount.string(from: copiedBytes)) of \(ByteCount.string(from: estimatedBytes)), \(speed), ETA \(eta)\(note))")
    }

    private static func durationText(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        return String(format: "%02d:%02d:%02d", safe / 3600, (safe / 60) % 60, safe % 60)
    }

    private func usedBytes(onMountedPath path: String) -> Int64? {
        guard let result = try? CommandRunner.run("/bin/df", arguments: ["-k", path], timeoutSeconds: 4),
              result.exitCode == 0 else { return nil }
        let lines = result.stdout.split(separator: "\n")
        guard lines.count >= 2 else { return nil }
        let parts = lines[1].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, let usedKB = Int64(parts[2]) else { return nil }
        return usedKB * 1024
    }
}

final class FileGrowthProgressMonitor {
    private let label: String
    private let outputURL: URL
    private let expectedBytes: Int64?
    private let cancellationToken: CancellationToken?
    private let log: AcquisitionRunner.LogHandler
    private let lock = NSLock()
    private var stopped = false

    init(label: String, outputURL: URL, expectedBytes: Int64?, cancellationToken: CancellationToken?, log: @escaping AcquisitionRunner.LogHandler) {
        self.label = label
        self.outputURL = outputURL
        self.expectedBytes = expectedBytes
        self.cancellationToken = cancellationToken
        self.log = log
    }

    func start() {
        guard expectedBytes.map({ $0 > 0 }) == true else {
            log("[progress] \(label) running (source size unavailable; progress percent cannot be estimated)")
            return
        }
        log("[progress] \(label) started 0%")
        Thread { [weak self] in
            guard let self else { return }
            var lastLoggedPercent = -1
            var lastLoggedAt = Date.distantPast
            while !self.isStopped {
                if self.cancellationToken?.isCancelled == true { return }
                (lastLoggedPercent, lastLoggedAt) = self.poll(lastLoggedPercent: lastLoggedPercent, lastLoggedAt: lastLoggedAt)
                Thread.sleep(forTimeInterval: 5)
            }
        }.start()
    }

    func stop(completed: Bool) {
        lock.lock()
        stopped = true
        lock.unlock()
        log(completed ? "[progress] \(label) complete" : "[progress] \(label) stopped")
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func poll(lastLoggedPercent: Int, lastLoggedAt: Date) -> (Int, Date) {
        guard let expectedBytes, expectedBytes > 0 else { return (lastLoggedPercent, lastLoggedAt) }
        let writtenBytes = currentOutputBytes()
        let percent = min(99, max(0, Int((Double(writtenBytes) / Double(expectedBytes) * 100.0).rounded(.down))))
        let now = Date()
        let progressed = percent >= lastLoggedPercent + 2 || (percent > 0 && lastLoggedPercent < 0)
        let heartbeat = now.timeIntervalSince(lastLoggedAt) >= 30
        guard progressed || heartbeat else { return (lastLoggedPercent, lastLoggedAt) }
        let note = progressed ? "" : ", still running"
        log("[progress] \(label) \(percent)% (\(ByteCount.string(from: writtenBytes)) of about \(ByteCount.string(from: expectedBytes))\(note))")
        return (progressed ? percent : lastLoggedPercent, now)
    }

    private func currentOutputBytes() -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path) else { return 0 }
        if let number = attributes[.size] as? NSNumber { return number.int64Value }
        if let value = attributes[.size] as? Int64 { return value }
        return 0
    }
}
