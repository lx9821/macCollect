import Foundation

public struct SourceCandidate: Identifiable, Hashable {
    public let id: String
    public let deviceIdentifier: String
    public let name: String
    public let roles: [String]
    public let mountPoint: String?
    public let sizeBytes: Int64?
    public let usedBytes: Int64?
    public let encrypted: Bool?
    public let fileVault: Bool?
    public let locked: Bool?
    public let writable: Bool?
    public let readOnly: Bool?
    public let internalDisk: Bool?
    public let sealed: Bool?
    public let sealStatus: String?
    public let containerReference: String?
    public let volumeUUID: String?
    public let source: String
    public let synthesisDetail: String?

    public var displayName: String {
        let roleText = roles.isEmpty ? "No role" : roles.joined(separator: ", ")
        return "\(deviceIdentifier) - \(name) (\(roleText))"
    }

    public var isMounted: Bool {
        mountPoint?.isEmpty == false
    }

    public var isKnownAuxiliaryVolume: Bool {
        let lowerName = name.lowercased()
        let lowerMount = mountPoint?.lowercased() ?? ""
        if lowerName == "maccollect" ||
            lowerName == "maccollect_evidence" ||
            lowerName == "maccollecte" ||
            lowerName.hasPrefix("maccollect-") ||
            lowerName.hasPrefix("maccollect_evidence") ||
            lowerName.hasPrefix("asrdatavolume") ||
            lowerMount == "/volumes/maccollect" ||
            lowerMount == "/volumes/maccollect_evidence" ||
            lowerMount == "/volumes/maccollecte" ||
            lowerMount.hasPrefix("/volumes/maccollect-") ||
            lowerMount.hasPrefix("/volumes/maccollect_evidence") {
            return true
        }
        let auxiliaryNames = ["xart", "xarts", "hardware", "update", "preboot", "iscpreboot", "vm", "recovery"]
        if roles.contains(where: { ["Recovery", "Preboot", "VM"].contains($0) }) { return true }
        if auxiliaryNames.contains(lowerName) { return true }
        return auxiliaryNames.contains { lowerMount == "/system/volumes/\($0)" || lowerMount.hasSuffix("/\($0)") }
    }

    public var hasBrokenSeal: Bool {
        roles.contains("System") && sealed == false
    }
}

public struct APFSCryptoUser: Identifiable, Hashable {
    public let id: String
    public let uuid: String
    public let type: String
    public let description: String

    public var displayName: String {
        let typeText = type.isEmpty ? "Crypto user" : type
        return "\(typeText) - \(uuid)"
    }

    public var isRecoveryUser: Bool {
        let combined = "\(type) \(description)".lowercased()
        return combined.contains("recovery")
    }
}

public enum RecoverySourceScanner {
    public static func scan() -> [SourceCandidate] {
        var candidates = apfsCandidates()
        if candidates.isEmpty {
            candidates = mountedVolumeCandidates()
        }
        return candidates.sorted { lhs, rhs in
            score(lhs) > score(rhs)
        }
    }

    public static func unlockVolume(deviceIdentifier: String, passphrase: String, userUUID: String? = nil) throws -> CommandResult {
        var arguments = ["apfs", "unlockVolume", deviceIdentifier]
        if let userUUID, !userUUID.isEmpty {
            arguments.append(contentsOf: ["-user", userUUID])
        }
        arguments.append(contentsOf: ["-nomount", "-stdinpassphrase"])
        return try CommandRunner.run(
            "/usr/sbin/diskutil",
            arguments: arguments,
            standardInput: passphrase + "\n"
        )
    }

    public static func mountReadOnly(deviceIdentifier: String) -> CommandResult {
        MacCollectGuard.shared.withTemporaryAllowance(
            deviceIdentifier: deviceIdentifier,
            operations: [.mount, .unmount]
        ) {
            let unmount = (try? CommandRunner.run(
                "/usr/sbin/diskutil",
                arguments: ["unmount", deviceIdentifier]
            )) ?? CommandResult(exitCode: 1, stdout: "", stderr: "diskutil unmount could not be started")

            if unmount.exitCode != 0 {
                _ = try? CommandRunner.run(
                    "/usr/sbin/diskutil",
                    arguments: ["unmount", "force", deviceIdentifier]
                )
            }

            let mount = (try? CommandRunner.run(
                "/usr/sbin/diskutil",
                arguments: ["mount", "readOnly", deviceIdentifier]
            )) ?? CommandResult(exitCode: 1, stdout: "", stderr: "diskutil mount readOnly could not be started")

            return CommandResult(
                exitCode: mount.exitCode,
                stdout: unmount.stdout + mount.stdout,
                stderr: unmount.stderr + mount.stderr
            )
        }
    }

    public static func mountWritable(deviceIdentifier: String) -> CommandResult {
        MacCollectGuard.shared.withTemporaryAllowance(
            deviceIdentifier: deviceIdentifier,
            operations: [.mount, .unmount]
        ) {
            let unmount = (try? CommandRunner.run(
                "/usr/sbin/diskutil",
                arguments: ["unmount", deviceIdentifier]
            )) ?? CommandResult(exitCode: 1, stdout: "", stderr: "diskutil unmount could not be started")

            if unmount.exitCode != 0 {
                _ = try? CommandRunner.run(
                    "/usr/sbin/diskutil",
                    arguments: ["unmount", "force", deviceIdentifier]
                )
            }

            let mount = (try? CommandRunner.run(
                "/usr/sbin/diskutil",
                arguments: ["mount", deviceIdentifier]
            )) ?? CommandResult(exitCode: 1, stdout: "", stderr: "diskutil mount could not be started")

            return CommandResult(
                exitCode: mount.exitCode,
                stdout: unmount.stdout + mount.stdout,
                stderr: unmount.stderr + mount.stderr
            )
        }
    }

    public static func unmount(deviceIdentifier: String, force: Bool = false) -> CommandResult {
        MacCollectGuard.shared.withTemporaryAllowance(
            deviceIdentifier: deviceIdentifier,
            operations: [.unmount]
        ) {
            var arguments = ["unmount"]
            if force {
                arguments.append("force")
            }
            arguments.append(deviceIdentifier)
            return (try? CommandRunner.run(
                "/usr/sbin/diskutil",
                arguments: arguments
            )) ?? CommandResult(exitCode: 1, stdout: "", stderr: "diskutil unmount could not be started")
        }
    }

    public static func cryptoUsers(deviceIdentifier: String) -> [APFSCryptoUser] {
        if let result = try? CommandRunner.run(
            "/usr/sbin/diskutil",
            arguments: ["apfs", "listCryptoUsers", "-plist", deviceIdentifier]
        ),
           result.exitCode == 0,
           let data = result.stdout.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) {
            let users = parseCryptoUsers(from: plist)
            if !users.isEmpty { return users }
        }

        guard let result = try? CommandRunner.run(
            "/usr/sbin/diskutil",
            arguments: ["apfs", "listCryptoUsers", deviceIdentifier]
        ),
              result.exitCode == 0 else {
            return []
        }
        return parseCryptoUsers(fromText: result.stdout)
    }

    private static func apfsCandidates() -> [SourceCandidate] {
        guard let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["apfs", "list", "-plist"], timeoutSeconds: 5),
              let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let containers = plist["Containers"] as? [[String: Any]] else {
            return []
        }

        let mounts = mountReadOnlyOptions()
        var candidates: [SourceCandidate] = []
        for container in containers {
            if let containerDevice = firstNonEmpty([
                stringValue(container["ContainerReference"]),
                stringValue(container["DeviceIdentifier"])
            ]) {
                candidates.append(SourceCandidate(
                    id: containerDevice,
                    deviceIdentifier: containerDevice,
                    name: "APFS Container \(containerDevice)",
                    roles: ["APFS Container"],
                    mountPoint: nil,
                    sizeBytes: int64Value(container["CapacityCeiling"] ?? container["Size"] ?? container["TotalSize"] ?? container["APFSContainerSize"]),
                    usedBytes: int64Value(container["CapacityInUse"] ?? container["Used"]),
                    encrypted: nil,
                    fileVault: nil,
                    locked: nil,
                    writable: nil,
                    readOnly: nil,
                    internalDisk: nil,
                    sealed: nil,
                    sealStatus: nil,
                    containerReference: containerDevice,
                    volumeUUID: nil,
                    source: "diskutil apfs list -plist",
                    synthesisDetail: "Synthesized APFS container \(containerDevice)"
                ))
            }
            let volumes = container["Volumes"] as? [[String: Any]] ?? []
            for volume in volumes {
                guard let device = volume["DeviceIdentifier"] as? String else { continue }
                let info = diskInfo(device)
                let mountPoint = (info["MountPoint"] as? String) ?? (volume["MountPoint"] as? String)
                let readOnly = mountPoint.flatMap { mounts[$0] } ?? (boolValue(info["WritableVolume"]).map { !$0 })
                let sealed = sealedState(volume: volume, info: info)
                candidates.append(SourceCandidate(
                    id: device,
                    deviceIdentifier: device,
                    name: (volume["Name"] as? String) ?? (info["VolumeName"] as? String) ?? device,
                    roles: volume["Roles"] as? [String] ?? [],
                    mountPoint: mountPoint,
                    sizeBytes: int64Value(volume["Size"] ?? info["TotalSize"] ?? info["Size"]),
                    usedBytes: int64Value(volume["CapacityInUse"] ?? info["CapacityInUse"]),
                    encrypted: boolValue(volume["Encryption"] ?? info["Encryption"]),
                    fileVault: boolValue(volume["FileVault"] ?? info["FileVault"]),
                    locked: boolValue(volume["Locked"] ?? info["Locked"]),
                    writable: boolValue(info["WritableVolume"] ?? info["Writable"]),
                    readOnly: readOnly,
                    internalDisk: boolValue(info["Internal"]),
                    sealed: sealed,
                    sealStatus: sealStatusText(roles: volume["Roles"] as? [String] ?? [], sealed: sealed),
                    containerReference: containerReference(volume: volume, info: info, container: container),
                    volumeUUID: volumeUUID(volume: volume, info: info),
                    source: "diskutil apfs list -plist; diskutil info -plist \(device)",
                    synthesisDetail: synthesisDetail(device: device, volume: volume, info: info, container: container)
                ))
            }
        }
        return candidates
    }

    private static func mountedVolumeCandidates() -> [SourceCandidate] {
        FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey, .volumeTotalCapacityKey], options: [])?.map { url in
            let values = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey])
            return SourceCandidate(
                id: url.path,
                deviceIdentifier: "",
                name: values?.volumeName ?? url.lastPathComponent,
                roles: [],
                mountPoint: url.path,
                sizeBytes: values?.volumeTotalCapacity.map(Int64.init),
                usedBytes: nil,
                encrypted: nil,
                fileVault: nil,
                locked: nil,
                writable: nil,
                readOnly: nil,
                internalDisk: nil,
                sealed: nil,
                sealStatus: nil,
                containerReference: nil,
                volumeUUID: nil,
                source: "FileManager.mountedVolumeURLs",
                synthesisDetail: "Mounted volume reported by FileManager.mountedVolumeURLs"
            )
        } ?? []
    }

    private static func synthesisDetail(device: String, volume: [String: Any], info: [String: Any], container: [String: Any]) -> String {
        var parts = ["APFS volume \(device)"]
        if let containerReference = containerReference(volume: volume, info: info, container: container) {
            parts.append("container \(containerReference)")
        }
        if let wholeDisk = firstNonEmpty([
            stringValue(info["ParentWholeDisk"]),
            stringValue(info["PartOfWholeDisk"]),
            stringValue(info["DeviceIdentifier"])
        ]), wholeDisk != device {
            parts.append("whole disk \(wholeDisk)")
        }
        if let containerUUID = firstNonEmpty([
            stringValue(info["APFSContainerUUID"]),
            stringValue(volume["APFSContainerUUID"]),
            stringValue(container["APFSContainerUUID"])
        ]) {
            parts.append("container UUID \(containerUUID)")
        }
        return parts.joined(separator: " | ")
    }

    private static func containerReference(volume: [String: Any], info: [String: Any], container: [String: Any]) -> String? {
        firstNonEmpty([
            stringValue(info["APFSContainerReference"]),
            stringValue(info["ContainerReference"]),
            stringValue(volume["APFSContainerReference"]),
            stringValue(container["ContainerReference"]),
            stringValue(container["DeviceIdentifier"])
        ])
    }

    private static func volumeUUID(volume: [String: Any], info: [String: Any]) -> String? {
        firstNonEmpty([
            stringValue(info["APFSVolumeUUID"]),
            stringValue(info["VolumeUUID"]),
            stringValue(info["UUID"]),
            stringValue(volume["APFSVolumeUUID"]),
            stringValue(volume["VolumeUUID"]),
            stringValue(volume["UUID"])
        ])
    }

    private static func diskInfo(_ device: String) -> [String: Any] {
        guard let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", device], timeoutSeconds: 2),
              let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return [:]
        }
        return plist
    }

    private static func sealedState(volume: [String: Any], info: [String: Any]) -> Bool? {
        if let direct = boolValue(
            firstExistingValue([
                volume["Sealed"],
                volume["APFSVolumeSealed"],
                volume["APFSSealed"],
                volume["SignedSystemVolume"],
                invertedBoolValue(volume["SealBroken"]),
                info["Sealed"],
                info["APFSVolumeSealed"],
                info["APFSSealed"],
                info["SignedSystemVolume"],
                invertedBoolValue(info["SealBroken"])
            ])
        ) {
            return direct
        }
        let combined = "\(volume) \(info)".lowercased()
        if combined.contains("seal broken") || combined.contains("sealed: no") || combined.contains("sealed = 0") {
            return false
        }
        if combined.contains("seal intact") || combined.contains("sealed: yes") || combined.contains("sealed = 1") {
            return true
        }
        return nil
    }

    private static func sealStatusText(roles: [String], sealed: Bool?) -> String? {
        guard roles.contains("System") else { return nil }
        guard let sealed else { return "System seal unknown" }
        return sealed ? "System seal intact" : "System seal broken"
    }

    private static func mountReadOnlyOptions() -> [String: Bool] {
        guard let result = try? CommandRunner.run("/sbin/mount", timeoutSeconds: 2) else { return [:] }
        var options: [String: Bool] = [:]
        for line in result.stdout.split(separator: "\n").map(String.init) {
            guard let onRange = line.range(of: " on "),
                  let optionsRange = line.range(of: " (", options: .backwards) else { continue }
            let path = String(line[onRange.upperBound..<optionsRange.lowerBound])
            let optionText = String(line[optionsRange.upperBound...].dropLast())
            let parts = optionText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            options[path] = parts.contains("read-only")
        }
        return options
    }

    private static func score(_ candidate: SourceCandidate) -> Int {
        var value = 0
        if candidate.roles.contains("Data") { value += 100 }
        if candidate.isMounted { value += 20 }
        if candidate.fileVault == true { value += 5 }
        if candidate.locked == true { value -= 50 }
        if candidate.roles.contains("Recovery") || candidate.roles.contains("Preboot") || candidate.roles.contains("VM") { value -= 30 }
        return value
    }

    private static func parseCryptoUsers(from value: Any) -> [APFSCryptoUser] {
        var users: [APFSCryptoUser] = []
        collectCryptoUsers(from: value, into: &users)
        return Array(Dictionary(grouping: users, by: \.uuid).compactMap { $0.value.first })
            .sorted { lhs, rhs in
                if lhs.isRecoveryUser != rhs.isRecoveryUser { return lhs.isRecoveryUser }
                return lhs.displayName < rhs.displayName
            }
    }

    private static func collectCryptoUsers(from value: Any, into users: inout [APFSCryptoUser]) {
        if let dictionary = value as? [String: Any] {
            for (key, value) in dictionary where isUUID(key) {
                users.append(APFSCryptoUser(
                    id: key,
                    uuid: key,
                    type: stringValue(value) ?? "",
                    description: "\(key) \(stringValue(value) ?? "")"
                ))
            }

            if let uuid = firstNonEmpty([
                stringValue(dictionary["UUID"]),
                stringValue(dictionary["APFSCryptoUserUUID"]),
                stringValue(dictionary["CryptoUserUUID"]),
                stringValue(dictionary["CryptographicUserUUID"]),
                stringValue(dictionary["UserUUID"])
            ]) {
                let type = firstNonEmpty([
                    stringValue(dictionary["Type"]),
                    stringValue(dictionary["APFSCryptoUserType"]),
                    stringValue(dictionary["CryptoUserType"]),
                    stringValue(dictionary["UserType"])
                ]) ?? ""
                let description = firstNonEmpty([
                    stringValue(dictionary["Description"]),
                    stringValue(dictionary["APFSCryptoUserDescription"]),
                    stringValue(dictionary["Hint"]),
                    stringValue(dictionary["UserName"])
                ]) ?? ""
                users.append(APFSCryptoUser(id: uuid, uuid: uuid, type: type, description: description))
            }

            for child in dictionary.values {
                collectCryptoUsers(from: child, into: &users)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectCryptoUsers(from: child, into: &users)
            }
        }
    }

    private static func parseCryptoUsers(fromText text: String) -> [APFSCryptoUser] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var users: [APFSCryptoUser] = []
        let uuidPattern = #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#
        guard let regex = try? NSRegularExpression(pattern: uuidPattern) else { return [] }

        for (index, line) in lines.enumerated() {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  let swiftRange = Range(match.range, in: line) else { continue }
            let uuid = String(line[swiftRange])
            let nearby = lines[index..<min(lines.count, index + 5)].joined(separator: " ")
            let type = firstRegexValue(in: nearby, pattern: #"Type:\s*([^,]+?)(?:\s{2,}|$)"#) ?? ""
            users.append(APFSCryptoUser(id: uuid, uuid: uuid, type: type, description: nearby))
        }

        return Array(Dictionary(grouping: users, by: \.uuid).compactMap { $0.value.first })
            .sorted { lhs, rhs in
                if lhs.isRecoveryUser != rhs.isRecoveryUser { return lhs.isRecoveryUser }
                return lhs.displayName < rhs.displayName
            }
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { continue }
            return trimmed
        }
        return nil
    }

    private static func firstExistingValue(_ values: [Any?]) -> Any? {
        for value in values {
            if let value { return value }
        }
        return nil
    }

    private static func invertedBoolValue(_ value: Any?) -> Bool? {
        boolValue(value).map { !$0 }
    }

    private static func firstRegexValue(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        guard let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isUUID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
            options: .regularExpression
        ) != nil
    }
}

public func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? Int { return value != 0 }
    if let value = value as? NSNumber { return value.boolValue }
    if let value = value as? String {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["yes", "true", "1", "sealed", "intact"].contains(lower) { return true }
        if ["no", "false", "0", "broken", "not sealed"].contains(lower) { return false }
    }
    return nil
}

public func int64Value(_ value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? NSNumber { return value.int64Value }
    if let value = value as? String { return Int64(value) }
    return nil
}
