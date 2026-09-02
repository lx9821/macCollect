import Foundation

public enum DestinationDiskFormat: String, CaseIterable, Identifiable {
    case apfs = "APFS"
    case exfat = "ExFAT"

    public var id: String { rawValue }
    public var label: String { rawValue }
    public var diskutilFileSystem: String { rawValue }
}

public struct ExternalDisk: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let size: String
    public let sizeBytes: Int64?
    public let protocolName: String
    public let removable: String
    public let wholeDisk: Bool
    public let isInternal: Bool
    public let isDiskImage: Bool
    public let safeToFlash: Bool

    public var displayName: String {
        "\(id) - \(name) - \(size)"
    }

    public var safetySummary: String {
        if safeToFlash { return "Flash target allowed" }
        if isInternal { return "Blocked: internal disk" }
        if isDiskImage { return "Blocked: disk image or virtual disk" }
        if !wholeDisk { return "Blocked: select a whole disk, not a partition" }
        return "Blocked by safety policy"
    }
}

public enum USBImageBuilder {
    public static func bundledAppPath() -> String {
        Bundle.main.bundlePath.hasSuffix(".app") ? Bundle.main.bundlePath : ""
    }

    public static func externalDisks() -> [ExternalDisk] {
        guard let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["list", "-plist"]),
              let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else {
            return []
        }

        let wholeDisks = Set((plist["WholeDisks"] as? [String]) ?? [])
        let usbIdentities = usbDiskIdentitiesByDevice()

        return disks.compactMap { disk in
            guard let id = disk["DeviceIdentifier"] as? String else { return nil }
            let info = diskInfo(id)
            let usbIdentity = usbIdentities[id]
            let isInternal = boolValue(info["Internal"] ?? disk["Internal"]) ?? (usbIdentity == nil)
            guard !isInternal else { return nil }
            let wholeDisk = boolValue(info["WholeDisk"] ?? disk["WholeDisk"]) ??
                (wholeDisks.contains(id) || id.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil)
            let sizeBytes = int64Value(info["TotalSize"] ?? info["Size"] ?? disk["Size"])
            let size = sizeBytes.map(ByteCount.string(from:)) ?? "Unknown"
            let protocolName = stringValue(info["BusProtocol"]) ?? stringValue(disk["BusProtocol"]) ?? usbIdentity?.protocolName ?? "External"
            let virtualState = (info["VirtualOrPhysical"] as? String)?.lowercased() ?? ""
            let mediaName = ((info["MediaName"] as? String) ?? (info["DeviceTreePath"] as? String) ?? "").lowercased()
            let isDiskImage = virtualState.contains("virtual") ||
                protocolName.localizedCaseInsensitiveContains("disk image") ||
                mediaName.contains("disk image")
            let safeToFlash = wholeDisk && !isInternal && !isDiskImage && id.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil
            return ExternalDisk(
                id: id,
                name: firstNonEmpty([
                    stringValue(info["VolumeName"]),
                    stringValue(info["MediaName"]),
                    stringValue(info["DeviceName"]),
                    usbIdentity?.name,
                    volumeNameSummary(in: disk),
                    stringValue(disk["Content"])?.localizedCaseInsensitiveContains("partition_scheme") == true ? nil : stringValue(disk["Content"])
                ]) ?? "External disk",
                size: size,
                sizeBytes: sizeBytes,
                protocolName: protocolName,
                removable: (boolValue(info["Removable"] ?? disk["Removable"])).map { $0 ? "Yes" : "No" } ??
                    (usbIdentity?.removable == true ? "Yes" : "Unknown"),
                wholeDisk: wholeDisk,
                isInternal: isInternal,
                isDiskImage: isDiskImage,
                safeToFlash: safeToFlash
            )
        }
        .filter(\.safeToFlash)
    }

    public static func caseDriveCommand(
        diskID: String,
        bootSizeMegabytes: Int,
        destinationFormat: DestinationDiskFormat,
        destinationVolumeName: String,
        includeEvidencePartition: Bool = true
    ) -> String {
        let safeBootSize = sanitizedBootSizeMegabytes(bootSizeMegabytes)
        let safeDestinationName = sanitizedCaseDestinationName(destinationVolumeName, format: destinationFormat)
        var parts = [
            "/usr/sbin/diskutil",
            "partitionDisk",
            "/dev/\(diskID)",
            "GPT",
            "JHFS+",
            shellQuote("macCollect"),
            includeEvidencePartition ? "\(safeBootSize)M" : "R"
        ]
        if includeEvidencePartition {
            parts.append(contentsOf: [
                destinationFormat.diskutilFileSystem,
                shellQuote(safeDestinationName),
                "R"
            ])
        }
        return parts.joined(separator: " ")
    }

    public static func prepareCaseDrive(
        diskID: String,
        bootSizeMegabytes: Int,
        destinationFormat: DestinationDiskFormat,
        destinationVolumeName: String,
        includeEvidencePartition: Bool = true,
        log: (String) -> Void
    ) throws -> URL {
        try validateExternalWholeDisk(diskID: diskID)
        let payloadPath = try stagePayloadForPrivilegedInstall(log: log)
        defer { try? FileManager.default.removeItem(atPath: payloadPath) }

        let safeDestinationName = sanitizedCaseDestinationName(destinationVolumeName, format: destinationFormat)
        let command = caseDriveCommand(
            diskID: diskID,
            bootSizeMegabytes: bootSizeMegabytes,
            destinationFormat: destinationFormat,
            destinationVolumeName: safeDestinationName,
            includeEvidencePartition: includeEvidencePartition
        )
        log("Partitioning case drive")
        log("$ \(command)")
        if isRunningAsRoot() {
            _ = try runLogged("/usr/sbin/diskutil", partitionDiskArguments(
                diskID: diskID,
                bootSizeMegabytes: bootSizeMegabytes,
                destinationFormat: destinationFormat,
                destinationVolumeName: safeDestinationName,
                includeEvidencePartition: includeEvidencePartition
            ), log: log)
        } else {
            log("Requesting administrator privileges for case drive erase")
            let script = "do shell script \(appleScriptQuote(command)) with administrator privileges"
            _ = try runLogged("/usr/bin/osascript", ["-e", script], log: log)
        }

        mountDiskIfNeeded(diskID: diskID, log: log)

        let bootMountPoint = try waitForVolume(named: "macCollect", diskID: diskID, log: log)
        log("macOS may ask for Removable Volumes access now. Allow it so macCollect can copy launcher files.")
        log("Copying launcher payload to \(bootMountPoint.path)")
        do {
            try copyPayload(from: URL(fileURLWithPath: payloadPath, isDirectory: true), to: bootMountPoint, log: log)
        } catch {
            throw AcquisitionError.command("Case drive was partitioned, but macOS blocked copying launcher files to \(bootMountPoint.path). Grant macCollect Full Disk Access and Removable Volumes access, then try again. Underlying error: \(error.localizedDescription)")
        }

        guard includeEvidencePartition else {
            log("Case drive ready and left mounted: boot=macCollect, evidence partition=none")
            return bootMountPoint
        }

        let destinationMountPoint = try waitForVolume(named: safeDestinationName, diskID: diskID, log: log)
        log("Preparing destination volume \(destinationMountPoint.path)")
        try prepareDestinationVolume(at: destinationMountPoint, log: log)

        log("Case drive ready and left mounted: boot=macCollect, destination=\(safeDestinationName)")
        return destinationMountPoint
    }

    private static func partitionDiskArguments(
        diskID: String,
        bootSizeMegabytes: Int,
        destinationFormat: DestinationDiskFormat,
        destinationVolumeName: String,
        includeEvidencePartition: Bool
    ) -> [String] {
        var arguments = [
                "partitionDisk",
                "/dev/\(diskID)",
                "GPT",
                "JHFS+",
                "macCollect",
                includeEvidencePartition ? "\(sanitizedBootSizeMegabytes(bootSizeMegabytes))M" : "R"
        ]
        if includeEvidencePartition {
            arguments.append(contentsOf: [
                destinationFormat.diskutilFileSystem,
                destinationVolumeName,
                "R"
            ])
        }
        return arguments
    }

    private static func validateExternalWholeDisk(diskID: String) throws {
        guard diskID.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil else {
            throw AcquisitionError.validation("Target must be a whole disk such as disk4, not a partition.")
        }

        let info = diskInfo(diskID)
        let usbIdentity = usbDiskIdentitiesByDevice()[diskID]
        guard !info.isEmpty else {
            throw AcquisitionError.validation("Could not verify target disk /dev/\(diskID).")
        }
        let wholeDisk = boolValue(info["WholeDisk"]) ?? false
        guard wholeDisk else {
            throw AcquisitionError.validation("Target must be a verified whole disk, not a partition.")
        }
        let isInternal = boolValue(info["Internal"]) ?? (usbIdentity == nil)
        if isInternal {
            throw AcquisitionError.validation("Refusing to flash internal disk /dev/\(diskID).")
        }
        let protocolName = stringValue(info["BusProtocol"]) ?? usbIdentity?.protocolName ?? ""
        let virtualState = (info["VirtualOrPhysical"] as? String)?.lowercased() ?? ""
        let mediaName = ((info["MediaName"] as? String) ?? (info["DeviceTreePath"] as? String) ?? "").lowercased()
        if virtualState.contains("virtual") ||
            protocolName.localizedCaseInsensitiveContains("disk image") ||
            mediaName.contains("disk image") {
            throw AcquisitionError.validation("Refusing to flash a disk image or virtual disk target.")
        }
    }

    private static func stagePayloadForPrivilegedInstall(log: (String) -> Void) throws -> String {
        let appPath = bundledAppPath()
        guard !appPath.isEmpty else {
            throw AcquisitionError.validation("Format-and-copy fallback requires running macCollect from a .app bundle.")
        }

        let payloadURL = URL(fileURLWithPath: "/private/tmp/macCollect-usb-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: payloadURL, withIntermediateDirectories: true)
        log("Staging USB payload: \(payloadURL.path)")
        let payloadAppURL = payloadURL.appendingPathComponent("macCollect.app")
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: appPath),
            to: payloadAppURL
        )
        try writeAppRecoveryLocalization(to: payloadAppURL)
        try recoveryLaunchPlist(appName: "macCollect.app").write(
            to: payloadURL.appendingPathComponent(".IAPhysicalMedia"),
            atomically: true,
            encoding: .utf8
        )
        try writeRecoveryLaunchSupportFiles(to: payloadURL)
        return payloadURL.path
    }

    private static func waitForVolume(named volumeName: String, diskID: String, log: (String) -> Void) throws -> URL {
        for attempt in 0..<40 {
            if let mountPoint = volumeMountPoint(named: volumeName, diskID: diskID) {
                log("Volume \(volumeName) mounted at \(mountPoint.path)")
                return mountPoint
            }
            if attempt == 0 || attempt % 4 == 3 {
                mountVolumeIfNeeded(named: volumeName, diskID: diskID, log: log)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        let known = volumeDeviceIdentifiers(named: volumeName, diskID: diskID).joined(separator: ", ")
        throw AcquisitionError.command("Volume \(volumeName) was created, but it did not mount under /Volumes. Known matching device(s): \(known.isEmpty ? "none" : known). Try Disk Utility > Mount for the volume, or unplug/replug the case drive and run the builder again.")
    }

    private static func mountDiskIfNeeded(diskID: String, log: (String) -> Void) {
        log("Ensuring new case-drive volumes are mounted")
        if let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["mountDisk", "/dev/\(diskID)"]) {
            let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if output.localizedCaseInsensitiveContains("Disk Arbitrator is in charge") {
                log("[mount] macCollectGuard is waiting for /dev/\(diskID) to finish automatic mount handling.")
            } else if !output.isEmpty {
                log(output)
            }
            if result.exitCode != 0 {
                log("[mount] diskutil mountDisk exited \(result.exitCode); will retry individual volumes.")
            }
        } else {
            log("[mount] Could not start diskutil mountDisk; will retry individual volumes.")
        }
    }

    private static func mountVolumeIfNeeded(named volumeName: String, diskID: String, log: (String) -> Void) {
        let devices = volumeDeviceIdentifiers(named: volumeName, diskID: diskID)
        guard !devices.isEmpty else {
            log("[mount] Waiting for \(volumeName) device identifier on /dev/\(diskID)")
            return
        }
        for device in devices {
            if volumeMountPoint(named: volumeName, diskID: diskID) != nil { return }
            log("[mount] Trying to mount \(volumeName) from /dev/\(device)")
            if let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["mount", "/dev/\(device)"]) {
                let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                if output.localizedCaseInsensitiveContains("Disk Arbitrator is in charge") {
                    log("[mount] macCollectGuard is waiting for /dev/\(device) to appear under /Volumes.")
                } else if !output.isEmpty {
                    log(output)
                }
            }
        }
    }

    private static func volumeMountPoint(named volumeName: String, diskID: String) -> URL? {
        if let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["list", "-plist"]),
           let data = result.stdout.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let disks = plist["AllDisksAndPartitions"] as? [[String: Any]],
           let disk = disks.first(where: { ($0["DeviceIdentifier"] as? String) == diskID }) {
            for mountPoint in collectMountPoints(named: volumeName, in: disk) {
                if FileManager.default.fileExists(atPath: mountPoint) {
                    return URL(fileURLWithPath: mountPoint, isDirectory: true)
                }
            }
        }

        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        return children.first { $0.lastPathComponent == volumeName } ??
            children.first { $0.lastPathComponent.hasPrefix(volumeName) }
    }

    private static func collectMountPoints(named volumeName: String, in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            var matches: [String] = []
            let name = stringValue(dictionary["VolumeName"])
            if name == volumeName, let mountPoint = stringValue(dictionary["MountPoint"]) {
                matches.append(mountPoint)
            }
            for child in dictionary.values {
                matches.append(contentsOf: collectMountPoints(named: volumeName, in: child))
            }
            return matches
        }
        if let array = value as? [Any] {
            return array.flatMap { collectMountPoints(named: volumeName, in: $0) }
        }
        return []
    }

    private static func volumeDeviceIdentifiers(named volumeName: String, diskID: String) -> [String] {
        guard let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["list", "-plist"]),
              let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let disks = plist["AllDisksAndPartitions"] as? [[String: Any]],
              let disk = disks.first(where: { ($0["DeviceIdentifier"] as? String) == diskID }) else {
            return []
        }
        return collectDeviceIdentifiers(named: volumeName, in: disk)
    }

    private static func collectDeviceIdentifiers(named volumeName: String, in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            var matches: [String] = []
            let name = stringValue(dictionary["VolumeName"])
            if name == volumeName, let device = stringValue(dictionary["DeviceIdentifier"]) {
                matches.append(device)
            }
            for child in dictionary.values {
                matches.append(contentsOf: collectDeviceIdentifiers(named: volumeName, in: child))
            }
            return matches
        }
        if let array = value as? [Any] {
            return array.flatMap { collectDeviceIdentifiers(named: volumeName, in: $0) }
        }
        return []
    }

    private static func copyPayload(from payloadURL: URL, to mountPoint: URL, log: (String) -> Void) throws {
        let appSource = payloadURL.appendingPathComponent("macCollect.app", isDirectory: true)
        let appDestination = mountPoint.appendingPathComponent("macCollect.app", isDirectory: true)
        let recoveryLaunchSource = payloadURL.appendingPathComponent(".IAPhysicalMedia")
        let recoveryLaunchDestination = mountPoint.appendingPathComponent(".IAPhysicalMedia")
        let localizationSource = payloadURL.appendingPathComponent("en.lproj", isDirectory: true)
        let localizationDestination = mountPoint.appendingPathComponent("en.lproj", isDirectory: true)
        let startScriptSource = payloadURL.appendingPathComponent("start.sh")
        let startScriptDestination = mountPoint.appendingPathComponent("start.sh")

        try? FileManager.default.removeItem(at: appDestination)
        try? FileManager.default.removeItem(at: mountPoint.appendingPathComponent("Full Disk Access Settings.url"))
        try? FileManager.default.removeItem(at: mountPoint.appendingPathComponent("README.txt"))
        try? FileManager.default.removeItem(at: recoveryLaunchDestination)
        try? FileManager.default.removeItem(at: localizationDestination)
        try? FileManager.default.removeItem(at: startScriptDestination)

        _ = try runLogged("/usr/bin/ditto", ["--noqtn", appSource.path, appDestination.path], log: log)
        try FileManager.default.copyItem(at: recoveryLaunchSource, to: recoveryLaunchDestination)
        try FileManager.default.copyItem(at: localizationSource, to: localizationDestination)
        try FileManager.default.copyItem(at: startScriptSource, to: startScriptDestination)
        _ = try CommandRunner.run("/bin/sync")
    }

    private static func prepareDestinationVolume(at mountPoint: URL, log: (String) -> Void) throws {
        _ = try? CommandRunner.run("/bin/sync")
        log("Destination partition ready: \(mountPoint.path)")
    }

    private static func runLogged(_ executable: String, _ arguments: [String], log: (String) -> Void) throws -> CommandResult {
        log("$ \(([executable] + arguments).joined(separator: " "))")
        let result = try CommandRunner.run(executable, arguments: arguments)
        if !result.stdout.isEmpty { log(result.stdout.trimmingCharacters(in: .newlines)) }
        if !result.stderr.isEmpty { log(result.stderr.trimmingCharacters(in: .newlines)) }
        guard result.exitCode == 0 else {
            throw AcquisitionError.command("\(executable) exited with \(result.exitCode)")
        }
        return result
    }

    private static func diskInfo(_ diskID: String) -> [String: Any] {
        guard let result = try? CommandRunner.run("/usr/sbin/diskutil", arguments: ["info", "-plist", diskID]),
              let data = result.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return [:]
        }
        return plist
    }

    private struct USBDiskIdentity {
        let name: String?
        let protocolName: String
        let removable: Bool
    }

    private static func usbDiskIdentitiesByDevice() -> [String: USBDiskIdentity] {
        guard let result = try? CommandRunner.run("/usr/sbin/ioreg", arguments: ["-r", "-c", "IOUSBMassStorageDriverNub", "-l"]),
              !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }

        let marker = "+-o IOUSBMassStorageDriverNub"
        let chunks = result.stdout.components(separatedBy: marker).dropFirst().map { marker + $0 }
        var identities: [String: USBDiskIdentity] = [:]

        for chunk in chunks {
            guard let device = firstRegexValue(in: chunk, pattern: #""BSD Name" = "(disk[0-9]+)""#) else {
                continue
            }
            identities[device] = USBDiskIdentity(
                name: firstNonEmpty([
                    firstRegexValue(in: chunk, pattern: #""Device Characteristics" = \{[^}]*"Product Name"="([^"]+)""#),
                    firstRegexValue(in: chunk, pattern: #""Product Identification" = "([^"]+)""#),
                    firstRegexValue(in: chunk, pattern: #""USB Product Name" = "([^"]+)""#),
                    firstRegexValue(in: chunk, pattern: #""kUSBProductString"="([^"]+)""#)
                ]),
                protocolName: firstRegexValue(in: chunk, pattern: #""Physical Interconnect" = "([^"]+)""#) ?? "USB",
                removable: chunk.contains(#""Removable" = Yes"#) || chunk.contains(#""Ejectable" = Yes"#)
            )
        }

        return identities
    }

    private static func volumeNameSummary(in value: Any) -> String? {
        let names = Array(Set(collectStringValues(named: "VolumeName", in: value).filter { $0 != "EFI" })).sorted()
        guard !names.isEmpty else { return nil }
        return names.joined(separator: ", ")
    }

    private static func collectStringValues(named key: String, in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            var values: [String] = []
            if let string = stringValue(dictionary[key]) {
                values.append(string)
            }
            for child in dictionary.values {
                values.append(contentsOf: collectStringValues(named: key, in: child))
            }
            return values
        }
        if let array = value as? [Any] {
            return array.flatMap { collectStringValues(named: key, in: $0) }
        }
        return []
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

    private static func firstRegexValue(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges >= 2 else {
            return nil
        }
        guard let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizedBootSizeMegabytes(_ value: Int) -> Int {
        min(max(value, 50), 8192)
    }

    public static func sanitizedCaseDestinationName(_ value: String, format: DestinationDiskFormat) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        switch format {
        case .apfs:
            return trimmed.isEmpty ? "macCollect_Evidence" : String(trimmed.prefix(64))
        case .exfat:
            let allowed = CharacterSet.alphanumerics
            let normalized = trimmed.unicodeScalars
                .map { allowed.contains($0) ? Character($0) : nil }
                .compactMap { $0 }
            let name = String(normalized)
            return String((name.isEmpty ? "macCollectE" : name).prefix(11))
        }
    }

    private static func isRunningAsRoot() -> Bool {
        guard let result = try? CommandRunner.run("/usr/bin/id", arguments: ["-u"]) else { return false }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    private static func recoveryLaunchPlist(appName: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
                <key>AppName</key>
                <string>\(appName)</string>
                <key>ProductBuildVersion</key>
                <string>000001</string>
                <key>ProductVersion</key>
                <string>99.9</string>
        </dict>
        </plist>
        """
    }

    private static func writeRecoveryLaunchSupportFiles(to rootURL: URL) throws {
        let localizationURL = rootURL.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: localizationURL, withIntermediateDirectories: true)
        try recoveryDisplayNameStrings().write(
            to: localizationURL.appendingPathComponent("InfoPlist.strings"),
            atomically: true,
            encoding: .utf8
        )

        let startScriptURL = rootURL.appendingPathComponent("start.sh")
        try recoveryStartScript(appName: "macCollect.app", executableName: "macCollect").write(to: startScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: startScriptURL.path)
    }

    private static func recoveryStartScript(appName: String, executableName: String) -> String {
        """
        #!/bin/bash

        set -euo pipefail

        SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
        cd "$SCRIPT_DIR"

        export MACCOLLECT_FULLBUILD=1
        APP_BIN="$SCRIPT_DIR/\(appName)/Contents/MacOS/\(executableName)"
        if [ ! -x "$APP_BIN" ]; then
          echo "macCollect executable not found: $APP_BIN" >&2
          exit 127
        fi

        if [ "$(/usr/bin/id -u)" = "0" ]; then
          exec "$APP_BIN"
        fi

        if [ ! -d "/Applications/Utilities/Recovery Assistant.app" ] && [ ! -e "/System/Volumes/Data/private/tmp/Recovery" ] && [ ! -e "/private/tmp/Recovery" ]; then
          exec "$APP_BIN"
        fi

        if [ -x /usr/bin/sudo ]; then
          exec /usr/bin/sudo "$APP_BIN"
        fi

        echo "macCollect needs root privileges for Recovery APFS imaging." >&2
        exit 77
        """
    }

    private static func writeAppRecoveryLocalization(to appURL: URL) throws {
        let localizationURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: localizationURL, withIntermediateDirectories: true)
        try recoveryDisplayNameStrings().write(
            to: localizationURL.appendingPathComponent("InfoPlist.strings"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func recoveryDisplayNameStrings() -> String {
        #""CFBundleDisplayName" = "macCollect";"#
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
