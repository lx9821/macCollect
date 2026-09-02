import Foundation

public struct VolumeInfo: Identifiable {
    public let id = UUID()
    public let identifier: String
    public let type: String
    public let name: String
    public let size: String
    public let path: String
    public let status: String
    public let isReadOnly: Bool?
    public let indentLevel: Int
    public let totalBytes: Int64?
    public let usedBytes: Int64?
    public let availableBytes: Int64?

    public var isMacCollectVolume: Bool {
        let lowerName = name.lowercased()
        let lowerPath = path.lowercased()
        return lowerName == "maccollect" ||
            lowerName == "maccollect_evidence" ||
            lowerName == "maccollecte" ||
            lowerName.hasPrefix("maccollect-") ||
            lowerName.hasPrefix("maccollect_evidence") ||
            lowerPath == "/volumes/maccollect" ||
            lowerPath == "/volumes/maccollect_evidence" ||
            lowerPath == "/volumes/maccollecte" ||
            lowerPath.hasPrefix("/volumes/maccollect-") ||
            lowerPath.hasPrefix("/volumes/maccollect_evidence")
    }

    public func isMacCollectSyntheticContainer(in volumes: [VolumeInfo]) -> Bool {
        guard status.localizedCaseInsensitiveContains("synthesized from") else { return false }
        let stores = containerPhysicalStores
        guard !stores.isEmpty else { return false }
        return volumes.contains { volume in
            stores.contains(volume.identifier) && volume.isMacCollectVolume
        }
    }

    private var containerPhysicalStores: [String] {
        guard let range = status.range(of: " synthesized from ") else { return [] }
        return status[range.upperBound...]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public struct SecurityUnlockInfo {
    public let state: String
    public let detail: String
    public let evidence: String
    public let note: String
    public let source: String

    public var isAvailable: Bool {
        state.localizedCaseInsensitiveContains("unlocked") ||
            state.localizedCaseInsensitiveContains("not filevault") ||
            state.localizedCaseInsensitiveContains("encrypted")
    }
}

public struct SystemProfile {
    public let computerName: String
    public let hostName: String
    public let osVersion: String
    public let kernelVersion: String
    public let architecture: String
    public let modelIdentifier: String?
    public let modelName: String?
    public let modelNumber: String?
    public let appleModelNumber: String?
    public let processorName: String?
    public let cpuCoreSummary: String
    public let physicalMemoryBytes: UInt64
    public let serialNumber: String?
    public let systemInstallDate: Date?
    public let lastBootTime: Date?
    public let bootContext: String
    public let rootVolumeReadOnly: Bool?
    public let unlockState: SecurityUnlockInfo
    public let collectedAt: Date
    public let volumes: [VolumeInfo]

    public func replacing(volumes: [VolumeInfo], unlockState: SecurityUnlockInfo) -> SystemProfile {
        SystemProfile(
            computerName: computerName,
            hostName: hostName,
            osVersion: osVersion,
            kernelVersion: kernelVersion,
            architecture: architecture,
            modelIdentifier: modelIdentifier,
            modelName: modelName,
            modelNumber: modelNumber,
            appleModelNumber: appleModelNumber,
            processorName: processorName,
            cpuCoreSummary: cpuCoreSummary,
            physicalMemoryBytes: physicalMemoryBytes,
            serialNumber: serialNumber,
            systemInstallDate: systemInstallDate,
            lastBootTime: lastBootTime,
            bootContext: bootContext,
            rootVolumeReadOnly: rootVolumeReadOnly,
            unlockState: unlockState,
            collectedAt: Date(),
            volumes: volumes
        )
    }
}

public enum SystemProfiler {
    public static func collectVolumes() -> [VolumeInfo] {
        diskutilVolumes()
    }

    public static func collectUnlockState() -> SecurityUnlockInfo {
        unlockState()
    }

    public static func collectBasic() -> SystemProfile {
        let processInfo = ProcessInfo.processInfo
        let modelID = modelIdentifier()
        let hardware = hardwareValues()
        let processor = processorName(from: hardware)
        let computerName = systemConfigurationComputerName() ?? Host.current().localizedName ?? "Unknown"
        let appleNumber = appleModelNumber(for: modelID)
        let orderNumber = orderModelNumber(
            candidates: [hardware["Model Number"], ioPlatformStringValue("model-number")],
            appleModelNumber: appleNumber
        )

        return SystemProfile(
            computerName: computerName,
            hostName: hostName() ?? systemConfigurationHostName() ?? computerName,
            osVersion: processInfo.operatingSystemVersionString,
            kernelVersion: commandText("/usr/bin/uname", ["-r"]) ?? "Unknown",
            architecture: commandText("/usr/bin/uname", ["-m"]) ?? "Unknown",
            modelIdentifier: modelID,
            modelName: firstNonEmpty([retailModelName(for: modelID), hardware["Model Name"], recoveryModelName(for: modelID)]),
            modelNumber: orderNumber,
            appleModelNumber: appleNumber,
            processorName: processor,
            cpuCoreSummary: cpuCoreSummary(hardware: hardware),
            physicalMemoryBytes: processInfo.physicalMemory,
            serialNumber: serialNumber(),
            systemInstallDate: systemInstallDate(),
            lastBootTime: lastBootTime(),
            bootContext: ForensicDataRoot.isRecoveryEnvironment ? "Recovery" : "Normal live system",
            rootVolumeReadOnly: rootVolumeReadOnly(),
            unlockState: unlockState(),
            collectedAt: Date(),
            volumes: diskutilVolumes()
        )
    }

    private static func commandText(_ executable: String, _ arguments: [String] = [], timeout: TimeInterval = 2) -> String? {
        let value = try? CommandRunner.run(executable, arguments: arguments, timeoutSeconds: timeout).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value : nil
    }

    private static func hostName() -> String? {
        commandText("/bin/hostname")
    }

    private static func modelIdentifier() -> String? {
        firstNonEmpty([
            commandText("/usr/sbin/sysctl", ["-n", "hw.model"]),
            systemConfigurationModelIdentifier()
        ])
    }

    private static func processorName(from hardware: [String: String]) -> String? {
        firstNonEmpty([hardware["Chip"], hardware["Processor Name"], commandText("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])])
    }

    private static func cpuCoreSummary(hardware: [String: String]) -> String {
        if let total = hardware["Total Number of Cores"], !total.isEmpty {
            return "\(total) cores"
        }
        return commandText("/usr/sbin/sysctl", ["-n", "hw.physicalcpu"]).map { "\($0) cores" } ?? "Unknown"
    }

    private static func hardwareValues() -> [String: String] {
        if ForensicDataRoot.isRecoveryEnvironment { return [:] }
        guard let result = try? CommandRunner.run("/usr/sbin/system_profiler", arguments: ["SPHardwareDataType", "-detailLevel", "mini"], timeoutSeconds: 6) else {
            return [:]
        }
        var values: [String: String] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    private static func appleModelNumber(for identifier: String?) -> String? {
        let ioRegistryModelNumber = ioPlatformStringValue("regulatory-model-number")
        guard let identifier else { return ioRegistryModelNumber }
        let known: [String: String] = [
            "MacBookAir10,1": "A2337", "MacBookPro17,1": "A2338", "Macmini9,1": "A2348",
            "iMac21,1": "A2438/A2439", "iMac21,2": "A2438/A2439",
            "Mac13,1": "A2615", "Mac13,2": "A2686", "Mac14,2": "A2681", "Mac14,3": "A2779",
            "Mac14,5": "A2779", "Mac14,6": "A2780", "Mac14,7": "A2681", "Mac14,8": "A2816",
            "Mac14,9": "A2816", "Mac14,10": "A2816", "Mac14,12": "A2933", "Mac14,13": "A2934",
            "Mac14,14": "A2934", "Mac15,3": "A3113", "Mac15,4": "A3113", "Mac15,5": "A2918",
            "Mac15,6": "A2918", "Mac15,7": "A2918", "Mac15,8": "A2991", "Mac15,9": "A2991",
            "Mac15,10": "A2991", "Mac15,11": "A3114", "Mac15,12": "A3114", "Mac15,13": "A3114",
            "Mac16,1": "A3112", "Mac16,5": "A3186", "Mac16,6": "A3185", "Mac16,7": "A3403",
            "Mac16,8": "A3401", "Mac16,10": "A3238", "Mac16,11": "A3239", "Mac16,12": "A3240",
            "Mac16,13": "A3241", "Mac16,15": "A3239", "Mac17,5": "A3404"
        ]
        return firstNonEmpty([ioRegistryModelNumber, known[identifier]])
    }

    private static func orderModelNumber(candidates: [String?], appleModelNumber: String?) -> String? {
        guard let value = firstNonEmpty(candidates) else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if let appleModelNumber,
           normalized.localizedCaseInsensitiveCompare(appleModelNumber) == .orderedSame {
            return nil
        }
        if normalized.range(of: #"^A[0-9]{4}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        return normalized
    }

    private static func ioPlatformStringValue(_ key: String) -> String? {
        guard let result = try? CommandRunner.run("/usr/sbin/ioreg", arguments: ["-rd1", "-c", "IOPlatformExpertDevice"], timeoutSeconds: 3) else {
            return nil
        }
        if let value = ioPlatformStringValue(key, in: result.stdout) {
            return value
        }
        return nil
    }

    private static func ioPlatformStringValue(_ key: String, in output: String) -> String? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("\"\(key)\"") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count == 2 else { continue }
            if parts[1].hasPrefix("<"), parts[1].hasSuffix(">") {
                return stringFromHexData(
                    String(parts[1].dropFirst().dropLast())
                )
            }
            if parts[1].hasPrefix("\""), parts[1].hasSuffix("\"") {
                return firstNonEmpty([
                    String(parts[1].dropFirst().dropLast())
                ])
            }
        }

        let pattern = #""# + NSRegularExpression.escapedPattern(for: key) + #""\s*=\s*(?:"([^"]*)"|<([0-9A-Fa-f]+)>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..<output.endIndex, in: output)) else {
            return nil
        }
        if let quotedRange = Range(match.range(at: 1), in: output) {
            return firstNonEmpty([String(output[quotedRange])])
        }
        if let hexRange = Range(match.range(at: 2), in: output) {
            return stringFromHexData(String(output[hexRange]))
        }
        return nil
    }

    private static func stringFromHexData(_ hex: String) -> String? {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            guard next <= hex.endIndex,
                  let byte = UInt8(hex[index..<next], radix: 16) else {
                break
            }
            if byte == 0 { break }
            bytes.append(byte)
            index = next
        }
        guard !bytes.isEmpty, let value = String(bytes: bytes, encoding: .utf8) else { return nil }
        return firstNonEmpty([value])
    }

    private static func retailModelName(for identifier: String?) -> String? {
        guard let identifier else { return nil }
        let known: [String: String] = [

            "MacBookAir10,1": "MacBook Air (M1, 2020)",

            "Mac17,4": "MacBook Air (15-inch, M5)",
            "Mac17,3": "MacBook Air (13-inch, M5)",
            "Mac17,5": "MacBook Neo (13-inch, A18 Pro, 2026)",
            "Mac16,13": "MacBook Air (15-inch, M4, 2025)",
            "Mac16,12": "MacBook Air (13-inch, M4, 2025)",
            "Mac15,13": "MacBook Air (15-inch, M3, 2024)",
            "Mac15,12": "MacBook Air (13-inch, M3, 2024)",
            "Mac14,15": "MacBook Air (15-inch, M2, 2023)",
            "Mac14,2": "MacBook Air (M2, 2022)",

            "MacBookPro17,1": "MacBook Pro (13-inch, M1, 2020)",

            "Mac17,2": "MacBook Pro (14-inch, M5, 2025)",
            "Mac17,9": "MacBook Pro (14-inch, M5 Pro or M5 Max)",
            "Mac17,8": "MacBook Pro (16-inch, M5 Pro or M5 Max)",
            "Mac17,7": "MacBook Pro (14-inch, M5 Pro or M5 Max)",
            "Mac17,6": "MacBook Pro (16-inch, M5 Pro or M5 Max)",
            "Mac16,8": "MacBook Pro (14-inch, 2024)",
            "Mac16,7": "MacBook Pro (16-inch, 2024)",
            "Mac16,6": "MacBook Pro (14-inch, 2024)",
            "Mac16,5": "MacBook Pro (16-inch, 2024)",
            "Mac16,1": "MacBook Pro (14-inch, 2024)",
            "Mac15,11": "MacBook Pro (16-inch, Nov 2023)",
            "Mac15,10": "MacBook Pro (14-inch, Nov 2023)",
            "Mac15,9": "MacBook Pro (16-inch, Nov 2023)",
            "Mac15,8": "MacBook Pro (14-inch, Nov 2023)",
            "Mac15,7": "MacBook Pro (16-inch, Nov 2023)",
            "Mac15,6": "MacBook Pro (14-inch, Nov 2023)",
            "Mac15,3": "MacBook Pro (14-inch, Nov 2023)",
            "Mac14,10": "MacBook Pro (16-inch, 2023)",
            "Mac14,9": "MacBook Pro (14-inch, 2023)",
            "Mac14,7": "MacBook Pro (13-inch, M2, 2022)",
            "Mac14,6": "MacBook Pro (16-inch, 2023)",
            "Mac14,5": "MacBook Pro (14-inch, 2023)",
            "MacBookPro18,4": "MacBook Pro (14-inch, 2021)",
            "MacBookPro18,3": "MacBook Pro (14-inch, 2021)",
            "MacBookPro18,2": "MacBook Pro (16-inch, 2021)",
            "MacBookPro18,1": "MacBook Pro (16-inch, 2021)"
        ]
        return known[identifier]
    }

    private static func systemConfigurationModelIdentifier() -> String? {
        systemConfigurationString(keyPath: ["Model"]) { value in
            value.range(of: #"^(Mac|MacBook|iMac|Macmini|MacPro)[0-9A-Za-z,]+$"#, options: .regularExpression) != nil
        }?.value
    }

    private static func systemConfigurationComputerName() -> String? {
        systemConfigurationString(keyPath: ["System", "System", "ComputerName"])?.value
    }

    private static func systemConfigurationHostName() -> String? {
        firstNonEmpty([
            systemConfigurationString(keyPath: ["System", "Network", "HostNames", "LocalHostName"])?.value,
            systemConfigurationString(keyPath: ["System", "Network", "HostNames", "HostName"])?.value
        ])
    }

    private static func recoveryModelName(for identifier: String?) -> String? {
        guard ForensicDataRoot.isRecoveryEnvironment else { return nil }
        return identifier
    }

    private static func systemConfigurationString(
        keyPath: [String],
        validator: (String) -> Bool = { !$0.isEmpty }
    ) -> (value: String, path: String)? {
        let candidatePaths = systemConfigurationPreferencePaths()
        for path in candidatePaths {
            if let value = plistString(at: path, keyPath: keyPath), validator(value) {
                return (value, path)
            }
        }
        return nil
    }

    private static func systemConfigurationPreferencePaths() -> [String] {
        let fileManager = FileManager.default
        var paths: [String] = []

        if ForensicDataRoot.isRecoveryEnvironment,
           let mountedVolumes = fileManager.mountedVolumeURLs(includingResourceValuesForKeys: [.isDirectoryKey], options: []) {
            for volume in mountedVolumes {
                paths.append(volume.appendingPathComponent("Library/Preferences/SystemConfiguration/preferences.plist").path)
            }
        }

        paths.append(contentsOf: [
            ForensicDataRoot.resolve("/Library/Preferences/SystemConfiguration/preferences.plist").path,
            "/Volumes/Macintosh HD/Library/Preferences/SystemConfiguration/preferences.plist",
            "/Volumes/Data/Library/Preferences/SystemConfiguration/preferences.plist",
            "/System/Volumes/Data/Library/Preferences/SystemConfiguration/preferences.plist",
            "/Library/Preferences/SystemConfiguration/preferences.plist"
        ])

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func plistString(at path: String, keyPath: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        var current: Any = plist
        for key in keyPath {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            current = next
        }
        return firstNonEmpty([plistScalarString(current)])
    }

    private static func plistScalarString(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func serialNumber() -> String? {
        guard let result = try? CommandRunner.run("/usr/sbin/ioreg", arguments: ["-rd1", "-c", "IOPlatformExpertDevice"], timeoutSeconds: 3) else {
            return nil
        }
        for line in result.stdout.split(separator: "\n") where line.contains("IOPlatformSerialNumber") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"<>"))
        }
        return nil
    }

    private static func systemInstallDate() -> Date? {
        let setupDone = ForensicDataRoot.resolve("/var/db/.AppleSetupDone")
        guard let seconds = commandText("/usr/bin/stat", ["-f", "%B", setupDone.path], timeout: 3).flatMap(TimeInterval.init), seconds > 0 else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func lastBootTime() -> Date? {
        guard let text = commandText("/usr/sbin/sysctl", ["kern.boottime"]),
              let range = text.range(of: #"sec = [0-9]+"#, options: .regularExpression),
              let seconds = Int(text[range].replacingOccurrences(of: "sec =", with: "").trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    private static func rootVolumeReadOnly() -> Bool? {
        mountedVolumeInfo().first { $0.value.path == "/" }?.value.isReadOnly
    }

    private static func unlockState() -> SecurityUnlockInfo {
        let source = "diskutil apfs list -plist; mount; macCollect inference"
        guard let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["apfs", "list", "-plist"], timeoutSeconds: 8),
              let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else {
            return SecurityUnlockInfo(state: "Unknown", detail: "APFS lock state could not be read.", evidence: "diskutil apfs list unavailable", note: unlockStateNote(), source: source)
        }
        let dataVolumes = containers.flatMap { ($0["Volumes"] as? [[String: Any]] ?? []) }.filter {
            let roles = $0["Roles"] as? [String] ?? []
            return roles.contains("Data") || (($0["Name"] as? String) ?? "").localizedCaseInsensitiveCompare("Data") == .orderedSame
        }
        guard !dataVolumes.isEmpty else {
            return SecurityUnlockInfo(state: "Unknown", detail: "No APFS Data volume was identified.", evidence: "No Data role in APFS plist", note: unlockStateNote(), source: source)
        }
        let evidence = dataVolumes.map { volume -> String in
            let device = volume["DeviceIdentifier"] as? String ?? "unknown"
            let name = volume["Name"] as? String ?? "Data"
            return "\(device) \(name): FileVault=\(boolText(boolValue(volume["FileVault"]))), Encryption=\(boolText(boolValue(volume["Encryption"]))), Locked=\(boolText(boolValue(volume["Locked"])))"
        }.joined(separator: "; ")
        if dataVolumes.contains(where: { boolValue($0["Locked"]) == true }) {
            return SecurityUnlockInfo(state: "Locked", detail: "At least one FileVault/Data volume is still locked.", evidence: evidence, note: unlockStateNote(), source: source)
        }
        let encrypted = dataVolumes.contains { boolValue($0["FileVault"]) == true || boolValue($0["Encryption"]) == true }
        let mountedData = mountedVolumeInfo().contains { _, info in info.path == "/System/Volumes/Data" || info.path.hasSuffix("/Data") }
        if encrypted && mountedData {
            return SecurityUnlockInfo(state: "Unlocked", detail: "Encrypted Data volume is unlocked and mounted.", evidence: evidence, note: unlockStateNote(), source: source)
        }
        return SecurityUnlockInfo(
            state: encrypted ? "Unlocked" : "Not FileVault locked",
            detail: encrypted ? "Encrypted Data volume is unlocked but not mounted." : "Data volume is not reported as encrypted.",
            evidence: evidence,
            note: unlockStateNote(),
            source: source
        )
    }

    private static func unlockStateNote() -> String {
        "State is inferred from APFS lock and mount information."
    }

    private static func diskutilVolumes() -> [VolumeInfo] {
        let mountInfo = mountedVolumeInfo()
        guard let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["list"], timeoutSeconds: 8) else {
            return mountedVolumesFallback()
        }
        let parsed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n").flatMap {
            parseDiskutilStanza($0, mountInfo: mountInfo)
        }
        let filtered = parsed.filter { !$0.isMacCollectVolume && !$0.isMacCollectSyntheticContainer(in: parsed) }
        return filtered.isEmpty ? mountedVolumesFallback().filter { !$0.isMacCollectVolume } : filtered
    }

    private struct MountInfo {
        let path: String
        let totalBytes: Int64?
        let usedBytes: Int64?
        let availableBytes: Int64?
        let isReadOnly: Bool?
    }

    private static func mountedVolumeInfo() -> [String: MountInfo] {
        let mountOptions = mountReadOnlyOptions()
        guard let result = try? CommandRunner.run("/bin/df", arguments: ["-k"], timeoutSeconds: 5) else { return [:] }
        var info: [String: MountInfo] = [:]
        for line in result.stdout.split(separator: "\n") {
            guard line.hasPrefix("/dev/disk") else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 9 else { continue }
            let device = String(parts[0]).replacingOccurrences(of: "/dev/", with: "")
            let mountPath = parts[8...].joined(separator: " ")
            info[device] = MountInfo(
                path: mountPath,
                totalBytes: Int64(parts[1]).map { $0 * 1024 },
                usedBytes: Int64(parts[2]).map { $0 * 1024 },
                availableBytes: Int64(parts[3]).map { $0 * 1024 },
                isReadOnly: mountOptions[mountPath]
            )
        }
        return info
    }

    private static func mountReadOnlyOptions() -> [String: Bool] {
        guard let result = try? CommandRunner.run("/sbin/mount", timeoutSeconds: 3) else { return [:] }
        var options: [String: Bool] = [:]
        for line in result.stdout.split(separator: "\n").map(String.init) {
            guard let onRange = line.range(of: " on "), let optionsRange = line.range(of: " (", options: .backwards) else { continue }
            let path = String(line[onRange.upperBound..<optionsRange.lowerBound])
            let optionText = String(line[optionsRange.upperBound...].dropLast())
            options[path] = optionText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains("read-only")
        }
        return options
    }

    private static func parseDiskutilStanza(_ stanza: String, mountInfo: [String: MountInfo]) -> [VolumeInfo] {
        let lines = stanza.split(separator: "\n").map(String.init)
        guard lines.count >= 3 else { return [] }
        let stanzaDevice = lines[0].split(separator: " ").first.map(String.init)?.replacingOccurrences(of: "/dev/", with: "") ?? ""
        let baseStatus = lines[0].components(separatedBy: "(").dropFirst().first?.components(separatedBy: ")").first ?? ""
        let physicalStores = lines.compactMap { physicalStoreIdentifier(in: $0) }
        let status = baseStatus.localizedCaseInsensitiveContains("synthesized") && !stanzaDevice.isEmpty && !physicalStores.isEmpty
            ? "\(stanzaDevice) synthesized from \(physicalStores.joined(separator: ", "))"
            : baseStatus
        let header = lines[1]
        guard let indexSeparator = header.firstIndex(of: ":"), let nameRange = header.range(of: "NAME"), let sizeRange = header.range(of: "SIZE"), let identifierRange = header.range(of: "IDENTIFIER") else {
            return []
        }
        let typeOffset = header.distance(from: header.startIndex, to: header.index(after: indexSeparator))
        let nameOffset = header.distance(from: header.startIndex, to: nameRange.lowerBound)
        let sizeOffset = header.distance(from: header.startIndex, to: sizeRange.lowerBound)
        let identifierOffset = header.distance(from: header.startIndex, to: identifierRange.lowerBound)
        return lines.dropFirst(2).compactMap { line in
            guard !line.localizedCaseInsensitiveContains("Physical Store") else { return nil }
            let identifier = slice(line, from: identifierOffset, to: nil).trimmingCharacters(in: .whitespaces)
            guard !identifier.isEmpty, identifier != "-" else { return nil }
            let mount = mountInfo[identifier]
            return VolumeInfo(
                identifier: identifier,
                type: slice(line, from: typeOffset, to: nameOffset).trimmingCharacters(in: .whitespaces),
                name: slice(line, from: nameOffset, to: sizeOffset).trimmingCharacters(in: .whitespaces),
                size: slice(line, from: sizeOffset, to: identifierOffset).trimmingCharacters(in: .whitespaces),
                path: mount?.path ?? "",
                status: status,
                isReadOnly: mount?.isReadOnly,
                indentLevel: max(identifier.dropFirst(4).filter { $0 == "s" }.count, 0),
                totalBytes: mount?.totalBytes,
                usedBytes: mount?.usedBytes,
                availableBytes: mount?.availableBytes
            )
        }
    }

    private static func physicalStoreIdentifier(in line: String) -> String? {
        guard let range = line.range(of: #"Physical Store\s+(disk\S+)"#, options: .regularExpression) else { return nil }
        return String(line[range]).split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    private static func slice(_ line: String, from startOffset: Int, to endOffset: Int?) -> String {
        guard startOffset < line.count else { return "" }
        let start = line.index(line.startIndex, offsetBy: startOffset)
        let end = endOffset.map { $0 < line.count ? line.index(line.startIndex, offsetBy: $0) : line.endIndex } ?? line.endIndex
        return String(line[start..<end])
    }

    private static func mountedVolumesFallback() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: []) else { return [] }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return VolumeInfo(
                identifier: "",
                type: "Mounted Volume",
                name: values?.volumeName ?? url.lastPathComponent,
                size: values?.volumeTotalCapacity.map { ByteCount.string(from: Int64($0)) } ?? "Unknown",
                path: url.path,
                status: "",
                isReadOnly: nil,
                indentLevel: 0,
                totalBytes: values?.volumeTotalCapacity.map(Int64.init),
                usedBytes: nil,
                availableBytes: values?.volumeAvailableCapacityForImportantUsage
            )
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? Int { return value != 0 }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func boolText(_ value: Bool?) -> String {
        value.map { $0 ? "Yes" : "No" } ?? "Unknown"
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        values.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }
}
