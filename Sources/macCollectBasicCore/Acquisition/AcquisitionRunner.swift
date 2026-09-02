import CryptoKit
import Foundation

private struct FailedCopyPlaceholder {
    static let marker = "MCFFP1"
    static let xattrName = "com.maccollect.failed-file-placeholder"
    static let finderTagName = "macCollectFailed"
    static let finderTagsXattrName = "com.apple.metadata:_kMDItemUserTags"
    static let content = """
    MCFFP1
    macCollect failed-file placeholder

    WARNING: This file is not the original evidence item.
    This byte-identical placeholder was created because macCollect could not copy the original item.
    Details for the original path and copy error are recorded in the matching *-failed-files.csv report.
    All MCFFP1 placeholder files intentionally have identical content so they can be excluded by hash.
    """

    let tool: String
    let relativePath: String
    let sourcePath: String
    let reason: String
    let rawLine: String
}

public enum AcquisitionMethod: String, CaseIterable, Identifiable {
    case rsync
    case ditto

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .rsync:
            return "rsync copy (recommended)"
        case .ditto:
            return "ditto copy"
        }
    }

    public var executablePath: String {
        switch self {
        case .ditto:
            return "/usr/bin/ditto"
        case .rsync:
            return ForensicToolLocator.resolve("rsync") ?? "/usr/bin/rsync"
        }
    }

    public var executableName: String {
        URL(fileURLWithPath: executablePath).lastPathComponent
    }
}

public enum AcquisitionOutputFormat: String, CaseIterable, Identifiable {
    case compressedDMG
    case sparseImage
    case uncompressedDMG

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .compressedDMG:
            return "Compressed DMG"
        case .sparseImage:
            return "Sparse image"
        case .uncompressedDMG:
            return "Uncompressed DMG"
        }
    }

    public var technicalName: String {
        switch self {
        case .compressedDMG:
            return "hdiutil UDZO"
        case .sparseImage:
            return "hdiutil UDSP"
        case .uncompressedDMG:
            return "hdiutil UDRW"
        }
    }
}

public enum AcquisitionHashMethod: String, CaseIterable, Identifiable, Hashable {
    case md5
    case sha256

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .md5: return "MD5"
        case .sha256: return "SHA256"
        }
    }

    public var commandPreview: String {
        switch self {
        case .md5:
            return "streamed MD5 <final image>"
        case .sha256:
            return "streamed SHA256 <final image>"
        }
    }
}

public struct AcquisitionTimeContext {
    public let actualSystemTime: String
    public let effectiveDisplayTime: String
    public let effectiveTimeZone: String
    public let actualReferenceDate: Date
    public let displayReferenceDate: Date
    public let effectiveSecondsFromGMT: Int

    public init(
        actualSystemTime: String,
        effectiveDisplayTime: String,
        effectiveTimeZone: String,
        actualReferenceDate: Date,
        displayReferenceDate: Date,
        effectiveSecondsFromGMT: Int
    ) {
        self.actualSystemTime = actualSystemTime
        self.effectiveDisplayTime = effectiveDisplayTime
        self.effectiveTimeZone = effectiveTimeZone
        self.actualReferenceDate = actualReferenceDate
        self.displayReferenceDate = displayReferenceDate
        self.effectiveSecondsFromGMT = effectiveSecondsFromGMT
    }
}

public struct AcquisitionTimelineEntry {
    public let phase: String
    public let startedAt: Date
    public let endedAt: Date?

    public init(phase: String, startedAt: Date, endedAt: Date?) {
        self.phase = phase
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct AcquisitionPlan {
    public let caseName: String
    public let examiner: String
    public let imageName: String
    public let sourcePath: String
    public let sourceDeviceIdentifier: String?
    public let sourceVolumeUUID: String?
    public let sourceReadOnlyHint: Bool?
    public let sourceRoles: [String]
    public let destinationPath: String
    public let method: AcquisitionMethod
    public let outputFormat: AcquisitionOutputFormat
    public let requireReadOnly: Bool
    public let readOnlyCheckNotApplicable: Bool
    public let skipDestinationSizeCheck: Bool
    public let createFailedFilePlaceholders: Bool
    public let hashMethods: [AcquisitionHashMethod]
    public let notes: String
    public let systemProfile: SystemProfile?
    public let timeContext: AcquisitionTimeContext?

    public var safeImageBaseName: String {
        SafeFileName.component(imageName)
    }

    public var safeCaseDirectoryName: String {
        SafeFileName.component(caseName, allowingSpaces: true, fallback: safeImageBaseName)
    }

    public var outputDirectoryURL: URL {
        URL(fileURLWithPath: destinationPath, isDirectory: true)
            .appendingPathComponent(safeCaseDirectoryName, isDirectory: true)
            .appendingPathComponent(safeImageBaseName, isDirectory: true)
    }

    public var expectedFinalImageURL: URL {
        switch outputFormat {
        case .compressedDMG:
            return outputDirectoryURL.appendingPathComponent("\(safeImageBaseName).dmg")
        case .uncompressedDMG:
            return outputDirectoryURL.appendingPathComponent("\(safeImageBaseName)_uncompressed.dmg")
        case .sparseImage:
            return outputDirectoryURL.appendingPathComponent("\(safeImageBaseName).sparseimage")
        }
    }

    public var protectedOutputURLs: [URL] {
        [
            expectedFinalImageURL,
            outputDirectoryURL.appendingPathComponent("\(safeImageBaseName)-temporary.sparseimage"),
            outputDirectoryURL.appendingPathComponent("\(safeImageBaseName)-conversion.sparseimage")
        ]
    }

    public func existingOutputConflicts(fileManager: FileManager = .default) -> [URL] {
        protectedOutputURLs.filter { fileManager.fileExists(atPath: $0.path) }
    }

    public init(
        caseName: String,
        examiner: String,
        imageName: String,
        sourcePath: String,
        sourceDeviceIdentifier: String? = nil,
        sourceVolumeUUID: String? = nil,
        sourceReadOnlyHint: Bool? = nil,
        sourceRoles: [String] = [],
        destinationPath: String,
        method: AcquisitionMethod,
        outputFormat: AcquisitionOutputFormat,
        requireReadOnly: Bool,
        readOnlyCheckNotApplicable: Bool = false,
        skipDestinationSizeCheck: Bool = false,
        createFailedFilePlaceholders: Bool = false,
        hashMethods: [AcquisitionHashMethod],
        notes: String,
        systemProfile: SystemProfile? = nil,
        timeContext: AcquisitionTimeContext? = nil
    ) {
        self.caseName = caseName
        self.examiner = examiner
        self.imageName = imageName
        self.sourcePath = sourcePath
        self.sourceDeviceIdentifier = sourceDeviceIdentifier
        self.sourceVolumeUUID = sourceVolumeUUID
        self.sourceReadOnlyHint = sourceReadOnlyHint
        self.sourceRoles = sourceRoles
        self.destinationPath = destinationPath
        self.method = method
        self.outputFormat = outputFormat
        self.requireReadOnly = requireReadOnly
        self.readOnlyCheckNotApplicable = readOnlyCheckNotApplicable
        self.skipDestinationSizeCheck = skipDestinationSizeCheck
        self.createFailedFilePlaceholders = createFailedFilePlaceholders
        self.hashMethods = hashMethods
        self.notes = notes
        self.systemProfile = systemProfile
        self.timeContext = timeContext
    }
}

public final class CancellationToken {
    public init() {}
    private let lock = NSLock()
    private var cancelled = false

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public struct AcquisitionRunResult {
    public let finalImagePath: String
    public let hashText: String
    public let endedAt: Date
    public let timeline: [AcquisitionTimelineEntry]
}

public final class AcquisitionRunner {
    public typealias LogHandler = (String) -> Void

    private let plan: AcquisitionPlan
    private let log: LogHandler
    private let cancellationToken: CancellationToken?
    private var mountedImage: MountedImage?
    private var commandLog: [String] = []
    private var toolVersions: [String: String] = [:]
    private var startedAt = Date()
    private var estimatedCopyBytes: Int64?
    private var copyWarnings: [String] = []
    private var failedCopies: [String] = []
    private var placeholderHashLogged = false
    private var openTimelinePhases: [String: Date] = [:]
    private var timelineEntries: [AcquisitionTimelineEntry] = []

    public init(plan: AcquisitionPlan, cancellationToken: CancellationToken? = nil, log: @escaping LogHandler) {
        self.plan = plan
        self.cancellationToken = cancellationToken
        self.log = log
    }

    public func run() throws -> AcquisitionRunResult {
        startedAt = Date()
        log("macCollect logical acquisition started")
        log("Method: \(plan.method.rawValue)")
        log("Output: \(plan.outputFormat.label)")
        toolVersions = collectToolVersions()

        try validate()
        try checkCancellation()

        let outputDirectory = plan.outputDirectoryURL
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let sourceURL = URL(fileURLWithPath: plan.sourcePath, isDirectory: true)
        let imageBaseName = plan.safeImageBaseName
        let sparseURL = outputDirectory.appendingPathComponent("\(imageBaseName)-temporary.sparseimage")

        let sizeArgument = try estimateImageSizeArgument(sourcePath: plan.sourcePath)
        try checkCancellation()
        startTimelinePhase("Sparse image")
        try createSparseImage(at: sparseURL, sizeArgument: sizeArgument, volumeName: imageBaseName)
        endTimelinePhase("Sparse image")
        try checkCancellation()
        startTimelinePhase("Attach image")
        let mounted = try attachSparseImage(sparseURL)
        endTimelinePhase("Attach image")
        mountedImage = mounted

        do {
            try checkCancellation()
            startTimelinePhase("Copy source")
            try copySource(sourceURL, toMountedPath: mounted.mountPath)
            endTimelinePhase("Copy source")
            try checkCancellation()
            startTimelinePhase("Detach source image")
            try detach(mounted)
            endTimelinePhase("Detach source image")
            mountedImage = nil

            startTimelinePhase("Finalize output")
            let finalImage = try AcquisitionImageFinalizer(
                outputFormat: plan.outputFormat,
                cancellationToken: cancellationToken,
                log: log,
                phase: { phase, isStart in
                    isStart ? self.startTimelinePhase(phase) : self.endTimelinePhase(phase)
                },
                runCommand: { executable, arguments in
                    try self.runLogged(executable, arguments)
                }
            ).finalize(sparseURL: sparseURL, outputDirectory: outputDirectory, imageBaseName: imageBaseName)
            endTimelinePhase("Finalize output")
            var hashText = "Not computed"
            if !plan.hashMethods.isEmpty {
                do {
                    startTimelinePhase("Hash output")
                    hashText = try AcquisitionHasher(cancellationToken: cancellationToken, log: log)
                        .hashFile(finalImage, methods: plan.hashMethods)
                    endTimelinePhase("Hash output")
                } catch {
                    endTimelinePhase("Hash output")
                    let warning = "Hashing failed after acquisition output was created: \(error.localizedDescription)"
                    copyWarnings.append(warning)
                    log("[warning] \(warning)")
                    hashText = warning
                }
            }
            let endedAt = Date()
            try AcquisitionManifestWriter(
                plan: plan,
                startedAt: startedAt,
                timeline: timelineEntries,
                copyWarnings: copyWarnings,
                failedCopies: failedCopies,
                commandLog: commandLog,
                toolVersions: toolVersions,
                log: log
            ).write(outputDirectory: outputDirectory, finalImage: finalImage, hashText: hashText, endedAt: endedAt)
            log("Acquisition completed: \(finalImage.path)")
            return AcquisitionRunResult(finalImagePath: finalImage.path, hashText: hashText, endedAt: endedAt, timeline: timelineEntries)
        } catch {
            if let mountedImage {
                try? detach(mountedImage)
                self.mountedImage = nil
            }
            throw error
        }
    }

    private func startTimelinePhase(_ phase: String) {
        openTimelinePhases[phase] = Date()
    }

    private func endTimelinePhase(_ phase: String) {
        let endedAt = Date()
        let startedAt = openTimelinePhases.removeValue(forKey: phase) ?? endedAt
        timelineEntries.append(AcquisitionTimelineEntry(phase: phase, startedAt: startedAt, endedAt: endedAt))
    }

    private func validate() throws {
        guard !plan.imageName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AcquisitionError.validation("Image name is required.")
        }
        guard FileManager.default.fileExists(atPath: plan.sourcePath) else {
            throw AcquisitionError.validation("Source does not exist: \(plan.sourcePath)")
        }
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: plan.destinationPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AcquisitionError.validation("Destination directory does not exist: \(plan.destinationPath)")
        }
        let conflicts = plan.existingOutputConflicts()
        guard conflicts.isEmpty else {
            throw AcquisitionError.validation("Image name already exists. Choose a new image name or move the existing output first:\n\(conflicts.map(\.path).joined(separator: "\n"))")
        }
        let checks = AcquisitionPreflight.run(plan: plan)
        let failures = checks.filter { $0.severity == .fail }
        if !failures.isEmpty {
            let detail = failures.map { "\($0.title): \($0.detail)" }.joined(separator: "\n")
            throw AcquisitionError.validation("Preflight failed:\n\(detail)")
        }
    }

    private func createSparseImage(at url: URL, sizeArgument: String, volumeName: String) throws {
        log("Creating temporary sparse image: \(url.path)")
        try runLogged("/usr/bin/hdiutil", [
            "create",
            "-size", sizeArgument,
            "-fs", "APFS",
            "-volname", volumeName,
            url.path
        ])
    }

    private func attachSparseImage(_ url: URL) throws -> MountedImage {
        log("Attaching sparse image")
        let result = try runLogged("/usr/bin/hdiutil", ["attach", "-nobrowse", url.path])
        let lines = result.stdout.split(separator: "\n").map(String.init)
        let deviceLines = lines.filter { $0.hasPrefix("/dev/disk") }
        guard let mountLine = deviceLines.first(where: { $0.contains("/Volumes/") }) else {
            throw AcquisitionError.command("hdiutil attach did not return a mounted volume.")
        }
        let parts = mountLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let volume = parts.first, let mountStart = mountLine.range(of: "/Volumes/")?.lowerBound else {
            throw AcquisitionError.command("Could not parse mounted image path.")
        }
        let container = deviceLines.first?.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? volume
        return MountedImage(container: container, volume: volume, mountPath: String(mountLine[mountStart...]))
    }

    private static let rsyncFlagsLock = NSLock()
    private static var rsyncFlagsCache: [String: [String]] = [:]

    public static func rsyncPreservationArguments(executablePath: String) -> [String] {
        rsyncFlagsLock.lock()
        if let cached = rsyncFlagsCache[executablePath] {
            rsyncFlagsLock.unlock()
            return cached
        }
        rsyncFlagsLock.unlock()
        let probe = try? CommandRunner.run(executablePath, arguments: ["--version"], timeoutSeconds: 5)
        let version = ((probe?.stdout ?? "") + (probe?.stderr ?? "")).lowercased()
        let flags = (version.contains("openrsync") || version.contains("2.6.9"))
            ? ["-xrlptgoE"]
            : ["-xrlptgoXA"]
        rsyncFlagsLock.lock()
        rsyncFlagsCache[executablePath] = flags
        rsyncFlagsLock.unlock()
        return flags
    }

    private func rsyncPreservationArguments(executablePath: String) -> [String] {
        Self.rsyncPreservationArguments(executablePath: executablePath)
    }

    private func copySource(_ sourceURL: URL, toMountedPath mountPath: String) throws {
        log("Copying \(sourceURL.path) -> \(mountPath)")
        let sourcePath = sourceURL.path.hasSuffix("/") ? sourceURL.path : sourceURL.path + "/"
        let monitor = CopyProgressMonitor(
            mountPath: mountPath,
            estimatedBytes: estimatedCopyBytes,
            cancellationToken: cancellationToken,
            log: log
        )
        var copyCompleted = false
        monitor.start()
        defer { monitor.stop(completed: copyCompleted) }

        switch plan.method {
        case .ditto:
            try copyWithDitto(sourceURL: sourceURL, mountPath: mountPath)
            copyCompleted = true
        case .rsync:
            let rsyncDestination = URL(fileURLWithPath: mountPath, isDirectory: true)
            let preservationArguments = rsyncPreservationArguments(executablePath: plan.method.executablePath)
            let result = try runLogged(plan.method.executablePath, preservationArguments + logicalCopyExcludeArguments + [sourcePath, rsyncDestination.path], allowedExitCodes: [0, 12, 23, 24])
            if result.exitCode != 0 {
                let output = result.stdout + result.stderr
                failedCopies.append(failedCopyEntry(context: "rsync logical copy", exitCode: result.exitCode, output: output))
                writeFailedCopiesSnapshotIfNeeded()
                createFailedFilePlaceholdersIfRequested(
                    output: output,
                    sourceURL: sourceURL,
                    destinationRoot: rsyncDestination,
                    context: "rsync logical copy"
                )
            }
            if result.exitCode == 12 {
                let warning = "rsync exited with protocol data stream error 12; attempting ditto fallback into the same mounted image."
                copyWarnings.append(warning)
                log("[warning] \(warning)")
                try copyWithDitto(sourceURL: sourceURL, mountPath: mountPath)
            }
            copyCompleted = true
        }
    }

    private func volumeUUID(forDeviceIdentifier deviceIdentifier: String) -> String? {
        let trimmed = deviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return volumeUUID(fromDiskInfoArgument: trimmed)
    }

    private func volumeUUID(forPath path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/dev/disk") else { return nil }
        return volumeUUID(fromDiskInfoArgument: trimmed)
    }

    private func volumeUUID(fromDiskInfoArgument argument: String) -> String? {
        guard let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", argument], timeoutSeconds: 3),
              result.exitCode == 0,
              let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return firstNonEmpty([
            stringValue(plist["APFSVolumeUUID"]),
            stringValue(plist["VolumeUUID"]),
            stringValue(plist["UUID"])
        ])
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { continue }
            return trimmed
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private func boolText(_ value: Any?) -> String {
        if let value = value as? Bool { return value ? "yes" : "no" }
        if let value = value as? NSNumber { return value.boolValue ? "yes" : "no" }
        if let value = stringValue(value) { return value }
        return "unknown"
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = stringValue(value) {
            return ["1", "true", "yes"].contains(value.lowercased())
        }
        return false
    }

    private var logicalTopLevelExclusions: [String] {
        ["macOS Install Data"]
    }

    private var logicalCopyExcludeArguments: [String] {
        logicalTopLevelExclusions.flatMap { ["--exclude", "/\($0)/***"] }
    }

    private func copyWithDitto(sourceURL: URL, mountPath: String) throws {
        let mountURL = URL(fileURLWithPath: mountPath, isDirectory: true)
        let excluded = Set(logicalTopLevelExclusions)
        let children = try FileManager.default.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil, options: [])

        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try checkCancellation()
            if excluded.contains(child.lastPathComponent) {
                let warning = "Skipped protected update staging path: \(child.path)"
                copyWarnings.append(warning)
                log("[warning] \(warning)")
                continue
            }
            let destination = mountURL.appendingPathComponent(child.lastPathComponent)
            if child.lastPathComponent == "Users", isDirectory(child) {
                try copyUsersDirectoryWithDitto(sourceURL: child, destinationURL: destination)
            } else {
                try runDittoCopy(["-X", child.path, destination.path], context: child.lastPathComponent)
            }
        }
    }

    private func copyUsersDirectoryWithDitto(sourceURL: URL, destinationURL: URL) throws {
        log("[progress] Copying Users directory in smaller units so one problematic home item does not hide the rest of the copy.")
        try createMetadataPreservingDirectory(from: sourceURL, to: destinationURL)
        let users = try FileManager.default.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        for user in users.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try checkCancellation()
            let userDestination = destinationURL.appendingPathComponent(user.lastPathComponent)
            if isDirectory(user) {
                try copyDirectoryContentsIndividually(
                    sourceURL: user,
                    destinationURL: userDestination,
                    contextPrefix: "Users/\(user.lastPathComponent)"
                )
            } else {
                try runDittoCopy(["-X", user.path, userDestination.path], context: "Users/\(user.lastPathComponent)")
            }
        }
    }

    private func copyDirectoryContentsIndividually(sourceURL: URL, destinationURL: URL, contextPrefix: String) throws {
        try createMetadataPreservingDirectory(from: sourceURL, to: destinationURL)
        let children = try FileManager.default.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil, options: [])
        if children.isEmpty {
            return
        }
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try checkCancellation()
            let destination = destinationURL.appendingPathComponent(child.lastPathComponent)
            try runDittoCopy(["-X", child.path, destination.path], context: "\(contextPrefix)/\(child.lastPathComponent)")
        }
    }

    private func createMetadataPreservingDirectory(from sourceURL: URL, to destinationURL: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: destinationURL.path) {
            try manager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        }
        guard let attributes = try? manager.attributesOfItem(atPath: sourceURL.path) else { return }
        var writableAttributes: [FileAttributeKey: Any] = [:]
        for key in [FileAttributeKey.posixPermissions, .ownerAccountID, .groupOwnerAccountID, .creationDate, .modificationDate] {
            if let value = attributes[key] {
                writableAttributes[key] = value
            }
        }
        try? manager.setAttributes(writableAttributes, ofItemAtPath: destinationURL.path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return values?.isDirectory == true
    }

    private func runDittoCopy(_ arguments: [String], context: String) throws {
        try checkCancellation()
        let executable = AcquisitionMethod.ditto.executablePath
        let command = ([executable] + arguments).joined(separator: " ")
        commandLog.append(command)
        log("$ \(command)")
        let result = try CommandRunner.run(
            executable,
            arguments: arguments,
            cancellationToken: cancellationToken
        )
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty {
            log(summarizedCommandOutput(output, label: "ditto \(context)"))
        }
        if result.exitCode != 0 {
            let warning = "ditto exited with \(result.exitCode) while copying \(context); continuing so remaining source items can still be acquired. Review copy warnings and the runtime log."
            copyWarnings.append(warning)
            failedCopies.append(failedCopyEntry(context: context, exitCode: result.exitCode, output: output))
            writeFailedCopiesSnapshotIfNeeded()
            if plan.createFailedFilePlaceholders,
               arguments.count >= 3,
               let sourcePath = arguments.dropFirst().dropLast().last,
               let destinationPath = arguments.last {
                createFailedFilePlaceholder(
                    at: URL(fileURLWithPath: destinationPath),
                    placeholder: FailedCopyPlaceholder(
                        tool: "ditto",
                        relativePath: context,
                        sourcePath: sourcePath,
                        reason: copyFailureClassification(output),
                        rawLine: output.isEmpty ? "ditto exited with \(result.exitCode)" : output
                    ),
                    context: context
                )
            }
            log("[warning] \(warning)")
        }
        try checkCancellation()
    }

    private func writeFailedCopiesSnapshotIfNeeded() {
        guard !failedCopies.isEmpty else { return }
        do {
            try AcquisitionManifestWriter(
                plan: plan,
                startedAt: startedAt,
                timeline: timelineEntries,
                copyWarnings: copyWarnings,
                failedCopies: failedCopies,
                commandLog: commandLog,
                toolVersions: toolVersions,
                log: log
            ).writeFailedCopiesOnly(outputDirectory: plan.outputDirectoryURL)
        } catch {
            let warning = "Could not write failed copy log before hashing: \(error.localizedDescription)"
            copyWarnings.append(warning)
            log("[warning] \(warning)")
        }
    }

    private func createFailedFilePlaceholdersIfRequested(output: String, sourceURL: URL, destinationRoot: URL, context: String) {
        guard plan.createFailedFilePlaceholders else { return }
        let placeholders = failedCopyPlaceholders(from: output, sourceURL: sourceURL)
        guard !placeholders.isEmpty else { return }
        var created = 0
        for placeholder in placeholders {
            let destination = destinationRoot.appendingPathComponent(placeholder.relativePath)
            if createFailedFilePlaceholder(at: destination, placeholder: placeholder, context: context) {
                created += 1
            }
        }
        let warning = "Created \(created) placeholder file(s) for failed copy items."
        copyWarnings.append(warning)
        log("[placeholder] \(warning)")
    }

    @discardableResult
    private func createFailedFilePlaceholder(at destination: URL, placeholder: FailedCopyPlaceholder, context: String) -> Bool {
        do {
            let manager = FileManager.default
            let target: URL
            if isDirectory(destination) {
                target = destination.appendingPathComponent("macCollect_failed_placeholder.txt")
            } else {
                target = destination
                if manager.fileExists(atPath: target.path) {
                    try manager.removeItem(at: target)
                }
            }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try failedFilePlaceholderText()
                .write(to: target, atomically: true, encoding: .utf8)
            writePlaceholderMarkerXattr(to: target)
            writePlaceholderFinderTag(to: target)
            logPlaceholderHashIfNeeded()
            log("[placeholder] \(target.path)")
            return true
        } catch {
            let warning = "Could not create failed-file placeholder for \(placeholder.relativePath): \(error.localizedDescription)"
            copyWarnings.append(warning)
            log("[warning] \(warning)")
            return false
        }
    }

    private func failedFilePlaceholderText() -> String {
        FailedCopyPlaceholder.content + "\n"
    }

    private func logPlaceholderHashIfNeeded() {
        guard !placeholderHashLogged else { return }
        placeholderHashLogged = true
        let data = Data(failedFilePlaceholderText().utf8)
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let message = "Failed-file placeholder hash: MD5 \(md5); SHA256 \(sha256). All MCFFP1 placeholder files are byte-identical."
        copyWarnings.append(message)
        log("[placeholder] \(message)")
    }

    private func writePlaceholderMarkerXattr(to url: URL) {
        let markerData = Array(FailedCopyPlaceholder.marker.utf8)
        markerData.withUnsafeBufferPointer { buffer in
            _ = setxattr(url.path, FailedCopyPlaceholder.xattrName, buffer.baseAddress, buffer.count, 0, 0)
        }
    }

    private func writePlaceholderFinderTag(to url: URL) {
        writePlaceholderFinderTagResourceValue(to: url)
        do {
            let tags = ["\(FailedCopyPlaceholder.finderTagName)\n0"]
            let data = try PropertyListSerialization.data(
                fromPropertyList: tags,
                format: .binary,
                options: 0
            )
            data.withUnsafeBytes { buffer in
                _ = setxattr(
                    url.path,
                    FailedCopyPlaceholder.finderTagsXattrName,
                    buffer.baseAddress,
                    data.count,
                    0,
                    0
                )
            }
        } catch {
            log("[warning] Could not set Finder tag on failed-file placeholder \(url.path): \(error.localizedDescription)")
        }
    }

    private func writePlaceholderFinderTagResourceValue(to url: URL) {
        guard #available(macOS 26.0, *) else { return }
        do {
            var taggedURL = url
            var currentTags = (try? taggedURL.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
            if !currentTags.contains(FailedCopyPlaceholder.finderTagName) {
                currentTags.append(FailedCopyPlaceholder.finderTagName)
            }
            var values = URLResourceValues()
            values.tagNames = currentTags
            try taggedURL.setResourceValues(values)
        } catch {
            // Keep the marker content and xattrs as the primary forensic indicator.
        }
    }

    private func failedCopyPlaceholders(from output: String, sourceURL: URL) -> [FailedCopyPlaceholder] {
        var placeholders: [FailedCopyPlaceholder] = []
        var seen = Set<String>()
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard let parsed = parseRsyncFailedLine(line, sourceURL: sourceURL) else { continue }
            guard seen.insert(parsed.relativePath).inserted else { continue }
            placeholders.append(parsed)
        }
        return placeholders
    }

    private func parseRsyncFailedLine(_ line: String, sourceURL: URL) -> FailedCopyPlaceholder? {
        parseRsyncReadErrorLine(line, sourceURL: sourceURL) ??
            parseRsyncVerificationLine(line, sourceURL: sourceURL)
    }

    private func parseRsyncReadErrorLine(_ line: String, sourceURL: URL) -> FailedCopyPlaceholder? {
        guard line.localizedCaseInsensitiveContains("rsync:"),
              line.localizedCaseInsensitiveContains("read errors mapping"),
              let firstQuote = line.firstIndex(of: "\""),
              let secondQuote = line[line.index(after: firstQuote)...].firstIndex(of: "\"") else {
            return nil
        }
        let encodedSourcePath = String(line[line.index(after: firstQuote)..<secondQuote])
        let sourcePath = decodeRsyncPath(encodedSourcePath)
        guard let relative = relativeImagePath(forSourcePath: sourcePath, sourceURL: sourceURL) else { return nil }
        let suffix = String(line[line.index(after: secondQuote)...])
        let reason = suffix.trimmingCharacters(in: CharacterSet(charactersIn: ": \t"))
        return FailedCopyPlaceholder(
            tool: "rsync",
            relativePath: relative,
            sourcePath: sourcePath,
            reason: reason.isEmpty ? "read errors mapping" : reason,
            rawLine: line
        )
    }

    private func parseRsyncVerificationLine(_ line: String, sourceURL: URL) -> FailedCopyPlaceholder? {
        guard line.hasPrefix("ERROR:"),
              let range = line.range(of: " failed verification -- update discarded") else {
            return nil
        }
        let encodedPath = String(line[line.index(line.startIndex, offsetBy: "ERROR:".count)..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let path = decodeRsyncPath(encodedPath)
        let relative = relativeImagePath(forRsyncPath: path, sourceURL: sourceURL)
        return FailedCopyPlaceholder(
            tool: "rsync",
            relativePath: relative,
            sourcePath: path.hasPrefix("/") ? path : sourceURL.appendingPathComponent(path).path,
            reason: "failed verification -- update discarded",
            rawLine: line
        )
    }

    private func relativeImagePath(forRsyncPath path: String, sourceURL: URL) -> String {
        if let relative = relativeImagePath(forSourcePath: path, sourceURL: sourceURL) {
            return relative
        }
        return sanitizeRelativePlaceholderPath(path)
    }

    private func relativeImagePath(forSourcePath sourcePath: String, sourceURL: URL) -> String? {
        let normalizedSourceRoot = sourceURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedSource = sourcePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedSource.hasPrefix(normalizedSourceRoot + "/") {
            return sanitizeRelativePlaceholderPath(String(normalizedSource.dropFirst(normalizedSourceRoot.count + 1)))
        }
        return nil
    }

    private func sanitizeRelativePlaceholderPath(_ value: String) -> String {
        let components = value.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
        return components.isEmpty ? "macCollect_failed_placeholder.txt" : components.joined(separator: "/")
    }

    private func decodeRsyncPath(_ path: String) -> String {
        var bytes: [UInt8] = []
        let scalars = Array(path.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "\\",
               index + 3 < scalars.count,
               scalars[index + 1].value >= 48, scalars[index + 1].value <= 55,
               scalars[index + 2].value >= 48, scalars[index + 2].value <= 55,
               scalars[index + 3].value >= 48, scalars[index + 3].value <= 55 {
                let octal = String(String.UnicodeScalarView([scalars[index + 1], scalars[index + 2], scalars[index + 3]]))
                if let value = UInt8(octal, radix: 8) {
                    bytes.append(value)
                    index += 4
                    continue
                }
            }
            bytes.append(contentsOf: String(scalars[index]).utf8)
            index += 1
        }
        return String(data: Data(bytes), encoding: .utf8) ?? path
    }

    private func failedCopyEntry(context: String, exitCode: Int32, output: String) -> String {
        let classification = copyFailureClassification(output)
        let relevantLines = output
            .components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                return !trimmed.isEmpty && (
                    trimmed.localizedCaseInsensitiveContains("error") ||
                    trimmed.localizedCaseInsensitiveContains("failed verification") ||
                    trimmed.localizedCaseInsensitiveContains("read errors mapping") ||
                    trimmed.localizedCaseInsensitiveContains("input/output") ||
                    trimmed.localizedCaseInsensitiveContains("resource deadlock") ||
                    trimmed.localizedCaseInsensitiveContains("permission") ||
                    trimmed.localizedCaseInsensitiveContains("denied") ||
                    trimmed.localizedCaseInsensitiveContains("no such file") ||
                    trimmed.localizedCaseInsensitiveContains("ditto:")
                )
            }
        let details = relevantLines.isEmpty
            ? output.components(separatedBy: .newlines).suffix(12).joined(separator: "\n")
            : relevantLines.joined(separator: "\n")
        return [
            "Context: \(context)",
            "Exit code: \(exitCode)",
            "Classification: \(classification)",
            "Details:",
            details.isEmpty ? "No command output captured." : details
        ].joined(separator: "\n")
    }

    private func copyFailureClassification(_ output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("resource deadlock avoided") || lower.contains("resource deadlock") {
            return "Likely cloud-only or provider-backed placeholder item. The item exists in the namespace but could not be materialized locally during acquisition."
        }
        if lower.contains("operation not permitted") {
            return "macOS permission/TCC or protected system asset denial. This is common for selected Apple-managed system asset paths."
        }
        if lower.contains("no such file") || lower.contains("vanished") {
            return "Item changed or vanished while copying."
        }
        if lower.contains("permission") || lower.contains("denied") {
            return "Permission denied."
        }
        return "Copy tool reported a partial transfer."
    }

    private func summarizedCommandOutput(_ output: String, label: String) -> String {
        let lines = output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard lines.count > 36 else { return output }
        let head = lines.prefix(20)
        let tail = lines.suffix(10)
        return (["[\(label)] Output truncated: \(lines.count) lines. Showing first 20 and last 10."] + head + ["..."] + tail).joined(separator: "\n")
    }

    private func detach(_ image: MountedImage) throws {
        log("Detaching \(image.volume)")
        do {
            try runLogged("/usr/bin/hdiutil", ["detach", image.volume])
        } catch {
            log("Normal detach failed, trying force detach for \(image.container)")
            try runLogged("/usr/bin/hdiutil", ["detach", "-force", image.container])
        }
    }

    private func estimateImageSizeArgument(sourcePath: String) throws -> String {
        let result = try CommandRunner.run("/bin/df", arguments: ["-k", sourcePath])
        let lines = result.stdout.split(separator: "\n")
        if lines.count >= 2 {
            let parts = lines[1].split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 3,
               let usedKB = Int64(parts[2]) {
                let extraKB: Int64 = 2 * 1024 * 1024
                let baseKB = usedKB
                estimatedCopyBytes = baseKB * 1024
                let padded = Int64(Double(baseKB) * 1.15) + extraKB
                log("Estimated image size: \(ByteCount.string(from: padded * 1024))")
                return "\(padded)k"
            }
        }
        log("Could not estimate source usage, falling back to 64g image.")
        estimatedCopyBytes = nil
        return "64g"
    }

    private func fileSizeBytes(_ url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    @discardableResult
    private func runLogged(_ executable: String, _ arguments: [String], allowedExitCodes: Set<Int32> = [0]) throws -> CommandResult {
        try checkCancellation()
        let command = ([executable] + arguments).joined(separator: " ")
        commandLog.append(command)
        log("$ \(command)")
        let result = try CommandRunner.runStreaming(
            executable,
            arguments: arguments,
            cancellationToken: cancellationToken
        ) { chunk in
            let text = chunk.trimmingCharacters(in: .newlines)
            if !text.isEmpty {
                self.log(text)
            }
        }
        let combinedOutput = (result.stdout + result.stderr)
        guard allowedExitCodes.contains(result.exitCode) else {
            throw AcquisitionError.command(commandFailureMessage(executable: executable, exitCode: result.exitCode, output: combinedOutput))
        }
        if result.exitCode != 0 {
            let warning: String
            if URL(fileURLWithPath: executable).lastPathComponent == "rsync", result.exitCode == 12 {
                warning = "rsync exited with 12 (protocol data stream error); macCollect will continue only if the caller has a fallback path."
            } else {
                warning = "\(executable) exited with \(result.exitCode); continuing because this indicates partial transfer or vanished files. Review raw log."
            }
            copyWarnings.append(warning)
            log("[warning] \(warning)")
        }
        try checkCancellation()
        return result
    }

    private func commandFailureMessage(executable: String, exitCode: Int32, output: String) -> String {
        let summary = outputExcerpt(from: output)
        if summary.isEmpty {
            return "\(executable) exited with \(exitCode). No stderr/stdout was captured."
        }
        return "\(executable) exited with \(exitCode): \(summary)"
    }

    private func outputExcerpt(from output: String, maxLines: Int = 8) -> String {
        let lines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return "" }

        let important = lines.filter { line in
            let lower = line.lowercased()
            return lower.contains("error") ||
                lower.contains("failed") ||
                lower.contains("cannot") ||
                lower.contains("can not") ||
                lower.contains("could not") ||
                lower.contains("denied") ||
                lower.contains("no such") ||
                lower.contains("read-only") ||
                lower.contains("not permitted") ||
                lower.contains("invalid") ||
                lower.contains("bad file descriptor") ||
                lower.contains("49321")
        }

        let selected = important.isEmpty ? Array(lines.suffix(maxLines)) : Array(important.suffix(maxLines))
        return selected.joined(separator: " | ")
    }

    private func checkCancellation() throws {
        if cancellationToken?.isCancelled == true {
            throw AcquisitionError.cancelled
        }
    }

    private func collectToolVersions() -> [String: String] {
        var tools: [(String, String, [String])] = [
            ("hdiutil", "/usr/bin/hdiutil", ["version"]),
            ("ditto", "/usr/bin/ditto", []),
        ]
        if ForensicToolLocator.resolve("rsync") != nil {
            tools.append(("rsync", AcquisitionMethod.rsync.executablePath, ["--version"]))
        }

        var versions: [String: String] = ["hashing": "CryptoKit streaming hashes"]
        for (name, executable, arguments) in tools {
            guard let result = try? CommandRunner.run(executable, arguments: arguments, timeoutSeconds: 4) else {
                versions[name] = "Unavailable"
                continue
            }
            let combined = (result.stdout + result.stderr)
                .split(separator: "\n")
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode == 0 {
                versions[name] = combined?.isEmpty == false ? combined! : "Present"
            } else {
                versions[name] = combined?.isEmpty == false ? "Unavailable (\(combined!))" : "Unavailable"
            }
        }
        return versions
    }

}

public enum AcquisitionError: LocalizedError {
    case validation(String)
    case command(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .validation(let message), .command(let message):
            return message
        case .cancelled:
            return "Acquisition cancelled."
        }
    }
}
