import Foundation

public enum PreflightSeverity: String {
    case pass = "Pass"
    case warning = "Warning"
    case fail = "Fail"
    case info = "Info"
}

public struct PreflightCheck: Identifiable {
    public let id = UUID()
    public let severity: PreflightSeverity
    public let title: String
    public let detail: String
}

public enum AcquisitionPreflight {
    public static func run(plan: AcquisitionPlan) -> [PreflightCheck] {
        var checks: [PreflightCheck] = []
        let fm = FileManager.default

        if fm.fileExists(atPath: plan.sourcePath) {
            checks.append(.init(severity: .pass, title: "Source exists", detail: plan.sourcePath))
        } else {
            checks.append(.init(severity: .fail, title: "Source missing", detail: plan.sourcePath))
        }

        var destinationIsDirectory = ObjCBool(false)
        if fm.fileExists(atPath: plan.destinationPath, isDirectory: &destinationIsDirectory), destinationIsDirectory.boolValue {
            checks.append(.init(severity: .pass, title: "Destination exists", detail: plan.destinationPath))
            let conflicts = plan.existingOutputConflicts(fileManager: fm)
            if conflicts.isEmpty {
                checks.append(.init(
                    severity: .pass,
                    title: "Image name available",
                    detail: plan.expectedFinalImageURL.path
                ))
            } else {
                checks.append(.init(
                    severity: .fail,
                    title: "Image name already exists",
                    detail: conflicts.map(\.path).joined(separator: "\n")
                ))
            }
        } else {
            checks.append(.init(severity: .fail, title: "Destination missing", detail: plan.destinationPath))
        }

        let sourceMount = mountPoint(containing: plan.sourcePath)
        let destinationMount = mountPoint(containing: plan.destinationPath)
        if let sourceMount, let destinationMount, sourceMount == destinationMount {
            checks.append(.init(severity: .fail, title: "Source and destination share a mount", detail: sourceMount))
        } else {
            checks.append(.init(severity: .pass, title: "Destination separate from source", detail: "Source: \(sourceMount ?? "unknown"), destination: \(destinationMount ?? "unknown")"))
        }

        if let destinationMount, destinationMount.hasPrefix("/Volumes/") {
            checks.append(.init(severity: .pass, title: "Destination appears external", detail: destinationMount))
        } else {
            checks.append(.init(severity: .warning, title: "Destination may be internal", detail: destinationMount ?? "Unknown mount point"))
        }

        checks.append(methodExecutableCheck(plan.method))
        checks.append(contentsOf: streamingHashChecks(methods: plan.hashMethods, purpose: "Output image hashing"))

        if methodRequiresRoot(plan), RuntimePrivilege.isRunningAsRoot {
            checks.append(.init(
                severity: .pass,
                title: "Root privileges",
                detail: "Running as \(RuntimePrivilege.statusText)."
            ))
        } else if methodRequiresRoot(plan) {
            let reason = "\(plan.method.label) needs root access for raw device reads."
            checks.append(.init(
                severity: .fail,
                title: "Root privileges required",
                detail: "\(reason) Restart macCollect as root before acquisition. Current identity: \(RuntimePrivilege.statusText)."
            ))
        }

        if !ForensicDataRoot.isRecoveryEnvironment {
            checks.append(fullDiskAccessCheck())
        }

        if plan.requireReadOnly {
            if let readOnly = plan.sourceReadOnlyHint {
                checks.append(.init(
                    severity: readOnly ? .pass : .fail,
                    title: readOnly ? "Source is read-only" : "Source is write-mounted",
                    detail: "\(plan.sourcePath) (APFS scanner\(plan.sourceDeviceIdentifier.map { ": \($0)" } ?? ""))"
                ))
            } else if let readOnly = readOnlyState(forMountContaining: plan.sourcePath) {
                checks.append(.init(
                    severity: readOnly ? .pass : .fail,
                    title: readOnly ? "Source is read-only" : "Source is write-mounted",
                    detail: plan.sourcePath
                ))
            } else {
                checks.append(.init(severity: .warning, title: "Source read-only state unknown", detail: plan.sourcePath))
            }
        } else if !plan.readOnlyCheckNotApplicable {
            checks.append(.init(severity: .warning, title: "Read-only enforcement disabled", detail: "Use only when intentionally collecting from a write-mounted source."))
        }

        let sourceUsed = usedBytes(forPath: plan.sourcePath)
        let destinationFree = freeBytes(forPath: plan.destinationPath)
        if let sourceUsed, let destinationFree {
            let required = requiredDestinationBytes(sourceUsed: sourceUsed, plan: plan)
            let enoughSpace = destinationFree > required
            let overridden = plan.skipDestinationSizeCheck && !enoughSpace
            checks.append(.init(
                severity: enoughSpace ? .pass : overridden ? .warning : .fail,
                title: enoughSpace ? "Destination free space sufficient" : overridden ? "Destination free space override enabled" : "Destination free space too small",
                detail: "Required about \(ByteCount.string(from: required)), available \(ByteCount.string(from: destinationFree)) (estimate uses currently used source data)\(sizeEstimateNote(for: plan))"
            ))
        } else {
            checks.append(.init(
                severity: plan.skipDestinationSizeCheck ? .warning : .warning,
                title: plan.skipDestinationSizeCheck ? "Destination size check override enabled" : "Could not estimate free space",
                detail: "Source or destination usage was unavailable. Verify destination capacity manually before starting."
            ))
        }

        return checks
    }

    public static func hasFailures(_ checks: [PreflightCheck]) -> Bool {
        checks.contains { $0.severity == .fail }
    }

    public static func mountPoint(containing path: String) -> String? {
        guard let result = try? CommandRunner.run("/sbin/mount", timeoutSeconds: 3) else { return nil }
        var best: String?
        for line in result.stdout.split(separator: "\n").map(String.init) {
            guard let onRange = line.range(of: " on "),
                  let optionsRange = line.range(of: " (", options: .backwards) else { continue }
            let mountPath = String(line[onRange.upperBound..<optionsRange.lowerBound])
            guard pathIsContained(path, inMountPoint: mountPath) else { continue }
            if best == nil || mountPath.count > best!.count {
                best = mountPath
            }
        }
        return best
    }

    public static func readOnlyState(forMountContaining path: String) -> Bool? {
        guard let result = try? CommandRunner.run("/sbin/mount", timeoutSeconds: 3) else { return nil }
        var bestMatch: (path: String, device: String, readOnly: Bool)?
        for line in result.stdout.split(separator: "\n").map(String.init) {
            guard let onRange = line.range(of: " on "),
                  let optionsRange = line.range(of: " (", options: .backwards) else { continue }
            let device = String(line[..<onRange.lowerBound])
            let mountPath = String(line[onRange.upperBound..<optionsRange.lowerBound])
            guard pathIsContained(path, inMountPoint: mountPath) else { continue }
            let options = String(line[optionsRange.upperBound...].dropLast())
            let mountOptions = Set(options.split(separator: ",").map(String.init))
            let readOnly = mountOptions.contains("read-only") || mountOptions.contains("ro")
            if bestMatch == nil || mountPath.count > bestMatch!.path.count {
                bestMatch = (mountPath, device, readOnly)
            }
        }
        guard let bestMatch else { return nil }
        if bestMatch.readOnly { return true }
        if let diskutilReadOnly = diskutilReadOnlyState(devicePath: bestMatch.device) {
            return diskutilReadOnly
        }
        return bestMatch.readOnly
    }

    private static func diskutilReadOnlyState(devicePath: String) -> Bool? {
        let device = devicePath.replacingOccurrences(of: "/dev/", with: "")
        guard !device.isEmpty,
              let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", device], timeoutSeconds: 4),
              let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        if let readOnly = boolValue(plist["ReadOnlyVolume"] ?? plist["ReadOnly"] ?? plist["ReadOnlyMedia"]) {
            return readOnly
        }
        if let writable = boolValue(plist["WritableVolume"] ?? plist["Writable"]) {
            return !writable
        }
        return nil
    }

    private static func pathIsContained(_ path: String, inMountPoint mountPath: String) -> Bool {
        let normalizedPath = path.isEmpty ? "/" : path
        let normalizedMount = mountPath.isEmpty ? "/" : mountPath
        if normalizedMount == "/" {
            return normalizedPath.hasPrefix("/")
        }
        return normalizedPath == normalizedMount || normalizedPath.hasPrefix(normalizedMount + "/")
    }

    private static func methodExecutableCheck(_ method: AcquisitionMethod) -> PreflightCheck {
        if FileManager.default.isExecutableFile(atPath: method.executablePath) {
            return .init(
                severity: .pass,
                title: "\(method.executableName) found",
                detail: "\(method.executablePath) for \(method.label)"
            )
        }
        let suggestion = method == .rsync
            ? "rsync is intended for normal live macOS runs. Use ditto in Recovery."
            : "The selected acquisition method cannot run in this environment."
        return .init(
            severity: .fail,
            title: "\(method.executableName) missing",
            detail: "\(method.executablePath) not found. \(suggestion)"
        )
    }

    private static func methodRequiresRoot(_ plan: AcquisitionPlan) -> Bool {
        plan.sourcePath.hasPrefix("/dev/")
    }

    private static func fullDiskAccessCheck() -> PreflightCheck {
        let status = FullDiskAccessChecker.currentStatus()
        if status.isGranted {
            return .init(
                severity: .pass,
                title: "Full Disk Access granted",
                detail: "\(status.bundleIdentifier) is allowed for protected live-system data."
            )
        }

        return .init(
            severity: .fail,
            title: "Full Disk Access not granted",
            detail: "Live acquisition needs Full Disk Access for protected macOS evidence paths. Current TCC state: \(status.state.label)."
        )
    }

    private static func streamingHashChecks(methods: [AcquisitionHashMethod], purpose: String) -> [PreflightCheck] {
        var seen = Set<AcquisitionHashMethod>()
        return methods.compactMap { method in
            guard seen.insert(method).inserted else { return nil }
            return .init(
                severity: .pass,
                title: "\(method.label) streaming hash available",
                detail: "\(purpose) uses CryptoKit and reads the image directly, so no external hash executable is required."
            )
        }
    }

    private static func usedBytes(forPath path: String) -> Int64? {
        guard let result = try? CommandRunner.run("/bin/df", arguments: ["-k", path], timeoutSeconds: 5) else { return nil }
        let lines = result.stdout.split(separator: "\n")
        guard lines.count >= 2 else { return nil }
        let parts = lines[1].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3, let usedKB = Int64(parts[2]) else { return nil }
        return usedKB * 1024
    }

    private static func requiredDestinationBytes(sourceUsed: Int64, plan: AcquisitionPlan) -> Int64 {
        let gib: Int64 = 1024 * 1024 * 1024
        switch plan.outputFormat {
        case .sparseImage:
            return Int64(Double(sourceUsed) * 1.15) + (2 * gib)
        case .compressedDMG:
            return Int64(Double(sourceUsed) * 1.55) + (3 * gib)
        case .uncompressedDMG:
            return Int64(Double(sourceUsed) * 2.20) + (3 * gib)
        }
    }

    private static func sizeEstimateNote(for plan: AcquisitionPlan) -> String {
        switch plan.outputFormat {
        case .sparseImage:
            return " (sparseimage keeps only the staged image)"
        case .compressedDMG:
            return " (compressed DMG keeps staged sparseimage plus compressed output reserve)"
        case .uncompressedDMG:
            return " (uncompressed DMG keeps staged sparseimage plus full-size output reserve)"
        }
    }

    private static func enumeratedDirectoryBytes(forPath path: String) -> Int64? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attributes[.size] as? NSNumber else { return nil }
            return size.int64Value
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return nil
        }
        var bytes: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)),
                  values.isDirectory != true else { continue }
            if let allocated = values.totalFileAllocatedSize {
                bytes += Int64(allocated)
            } else if let size = values.fileSize {
                bytes += Int64(size)
            }
        }
        return max(bytes, 1024 * 1024)
    }

    private static func freeBytes(forPath path: String) -> Int64? {
        guard let result = try? CommandRunner.run("/bin/df", arguments: ["-k", path], timeoutSeconds: 5) else { return nil }
        let lines = result.stdout.split(separator: "\n")
        guard lines.count >= 2 else { return nil }
        let parts = lines[1].split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 4, let freeKB = Int64(parts[3]) else { return nil }
        return freeKB * 1024
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["yes", "true", "1"].contains(lower) { return true }
            if ["no", "false", "0"].contains(lower) { return false }
        }
        return nil
    }

}
