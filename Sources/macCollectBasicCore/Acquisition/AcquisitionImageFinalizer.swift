import Foundation

struct MountedImage {
    let container: String
    let volume: String
    let mountPath: String
}

final class AcquisitionImageFinalizer {
    private let outputFormat: AcquisitionOutputFormat
    private let cancellationToken: CancellationToken?
    private let log: AcquisitionRunner.LogHandler
    private let phase: (String, Bool) -> Void
    private let runCommand: (String, [String]) throws -> CommandResult

    init(
        outputFormat: AcquisitionOutputFormat,
        cancellationToken: CancellationToken?,
        log: @escaping AcquisitionRunner.LogHandler,
        phase: @escaping (String, Bool) -> Void = { _, _ in },
        runCommand: @escaping (String, [String]) throws -> CommandResult
    ) {
        self.outputFormat = outputFormat
        self.cancellationToken = cancellationToken
        self.log = log
        self.phase = phase
        self.runCommand = runCommand
    }

    func finalize(sparseURL: URL, outputDirectory: URL, imageBaseName: String) throws -> URL {
        switch outputFormat {
        case .sparseImage:
            let finalURL = outputDirectory.appendingPathComponent("\(imageBaseName).sparseimage")
            if sparseURL.path != finalURL.path {
                guard !FileManager.default.fileExists(atPath: finalURL.path) else {
                    throw AcquisitionError.validation("Final image already exists: \(finalURL.path)")
                }
                try FileManager.default.moveItem(at: sparseURL, to: finalURL)
            }
            log("Sparse image ready: \(finalURL.path)")
            return finalURL
        case .compressedDMG:
            let dmgURL = outputDirectory.appendingPathComponent("\(imageBaseName).dmg")
            guard !FileManager.default.fileExists(atPath: dmgURL.path) else {
                throw AcquisitionError.validation("Final image already exists: \(dmgURL.path)")
            }
            log("Converting sparse image -> compressed DMG via staged conversion image")
            try convertViaStagingImage(
                source: sparseURL,
                format: "UDZO",
                finalOutput: dmgURL,
                outputDirectory: outputDirectory,
                imageBaseName: imageBaseName,
                label: "DMG conversion"
            )
            removeTemporaryImage(at: sparseURL, label: "temporary sparse image")
            return dmgURL
        case .uncompressedDMG:
            let rawURL = outputDirectory.appendingPathComponent("\(imageBaseName)_uncompressed.dmg")
            guard !FileManager.default.fileExists(atPath: rawURL.path) else {
                throw AcquisitionError.validation("Final image already exists: \(rawURL.path)")
            }
            log("Converting sparse image -> uncompressed UDRW DMG via staged conversion image")
            try convertViaStagingImage(
                source: sparseURL,
                format: "UDRW",
                finalOutput: rawURL,
                outputDirectory: outputDirectory,
                imageBaseName: imageBaseName,
                label: "UDRW conversion"
            )
            removeTemporaryImage(at: sparseURL, label: "temporary sparse image")
            return rawURL
        }
    }

    private func removeTemporaryImage(at url: URL, label: String) {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
                log("Removed \(label): \(url.path)")
            }
        } catch {
            log("[warning] Could not remove \(label) \(url.path): \(error.localizedDescription)")
        }
    }

    private func convertViaStagingImage(
        source: URL,
        format: String,
        finalOutput: URL,
        outputDirectory: URL,
        imageBaseName: String,
        label: String
    ) throws {
        let conversionURL = outputDirectory.appendingPathComponent("\(imageBaseName)-conversion.sparseimage")
        try? FileManager.default.removeItem(at: conversionURL)

        log("Creating conversion staging image: \(conversionURL.path)")
        _ = try runCommand("/usr/bin/hdiutil", [
            "create",
            "-size", conversionImageSizeArgument(source: source),
            "-fs", "APFS",
            "-volname", "\(imageBaseName)-conversion",
            conversionURL.path
        ])

        let mounted = try attachConversionImage(conversionURL)
        defer {
            _ = try? runCommand("/usr/bin/hdiutil", ["detach", mounted.volume])
            removeTemporaryImage(at: conversionURL, label: "conversion sparse image")
        }

        let stagedOutput = URL(fileURLWithPath: mounted.mountPath, isDirectory: true)
            .appendingPathComponent(finalOutput.lastPathComponent)
        try? FileManager.default.removeItem(at: stagedOutput)
        try convert(source: source, format: format, output: stagedOutput, label: label)

        log("Copying converted image to destination: \(finalOutput.path)")
        guard !FileManager.default.fileExists(atPath: finalOutput.path) else {
            throw AcquisitionError.validation("Final image already exists: \(finalOutput.path)")
        }
        try copyFinalImageWithProgress(source: stagedOutput, destination: finalOutput)
        try? FileManager.default.removeItem(at: stagedOutput)
        log("[progress] Final image copy complete")
        log("Flushing filesystem writes before hashing")
        _ = try? runCommand("/bin/sync", [])
    }

    private func copyFinalImageWithProgress(source: URL, destination: URL) throws {
        let monitor = FileGrowthProgressMonitor(
            label: "Final image copy",
            outputURL: destination,
            expectedBytes: fileSize(source),
            cancellationToken: cancellationToken,
            log: log
        )
        monitor.start()
        var completed = false
        defer { monitor.stop(completed: completed) }
        phase("Final image copy", true)
        defer { phase("Final image copy", false) }
        try FileManager.default.copyItem(at: source, to: destination)
        completed = true
    }

    private func convert(source: URL, format: String, output: URL, label: String) throws {
        let monitor = FileGrowthProgressMonitor(
            label: label,
            outputURL: output,
            expectedBytes: fileSize(source),
            cancellationToken: cancellationToken,
            log: log
        )
        monitor.start()
        var completed = false
        defer { monitor.stop(completed: completed) }
        phase(label, true)
        defer { phase(label, false) }
        _ = try runCommand("/usr/bin/hdiutil", ["convert", source.path, "-format", format, "-o", output.path])
        completed = true
    }

    private func conversionImageSizeArgument(source: URL) -> String {
        guard let bytes = fileSize(source) else { return "1g" }
        let paddedBytes = Int64(Double(bytes) * 1.10) + (512 * 1024 * 1024)
        let megabytes = max(1024, (paddedBytes + 1_048_575) / 1_048_576)
        return "\(megabytes)m"
    }

    private func attachConversionImage(_ url: URL) throws -> MountedImage {
        log("Attaching conversion staging image")
        let result = try runCommand("/usr/bin/hdiutil", ["attach", "-nobrowse", url.path])
        let lines = result.stdout.split(separator: "\n").map(String.init)
        let deviceLines = lines.filter { $0.hasPrefix("/dev/disk") }
        guard let mountLine = deviceLines.first(where: { $0.contains("/Volumes/") }) else {
            throw AcquisitionError.command("hdiutil attach did not return a mounted conversion volume.")
        }
        let parts = mountLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let volume = parts.first, let mountStart = mountLine.range(of: "/Volumes/")?.lowerBound else {
            throw AcquisitionError.command("Could not parse mounted conversion image path.")
        }
        let container = deviceLines.first?.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? volume
        return MountedImage(container: container, volume: volume, mountPath: String(mountLine[mountStart...]))
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        if let number = attributes[.size] as? NSNumber { return number.int64Value }
        if let value = attributes[.size] as? Int64 { return value }
        return nil
    }
}
