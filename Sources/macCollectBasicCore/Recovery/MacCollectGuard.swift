import DiskArbitration
import Foundation

public final class MacCollectGuard {
    public enum Operation: String, CaseIterable, Hashable {
        case mount
        case unmount
        case eject
    }

    public static let shared = MacCollectGuard()

    private let lock = NSLock()
    private var session: DASession?
    private var contextPointer: UnsafeMutableRawPointer?
    private var protectedDevices: Set<String> = []
    private var protectedContainers: Set<String> = []
    private var rootDevices: Set<String> = []
    private var allowedOperations: [AllowanceKey: Date] = [:]
    private var logHandler: ((String) -> Void)?
    private var hasStarted = false

    private init() {}

    deinit {
        if let session {
            DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }
        if let contextPointer {
            Unmanaged<MacCollectGuard>.fromOpaque(contextPointer).release()
        }
    }

    public var statusText: String {
        lock.withLock {
            guard hasStarted else { return "macCollectGuard not started." }
            guard session != nil else { return "macCollectGuard inactive." }
            if protectedDevices.isEmpty {
                return "macCollectGuard active; no protected source volume identified yet."
            }
            return "macCollectGuard active; protecting \(protectedDevices.sorted().joined(separator: ", "))."
        }
    }

    public func startIfNeeded(log: ((String) -> Void)? = nil) {
        lock.lock()
        if let log {
            logHandler = log
        }
        if hasStarted {
            let message = statusTextLocked()
            lock.unlock()
            emit(message)
            return
        }

        hasStarted = true
        rootDevices = Self.currentRootDeviceIdentifiers()

        guard RuntimePrivilege.isRunningAsRoot else {
            lock.unlock()
            emit("[guard] macCollectGuard inactive: root is required for mount protection.")
            return
        }

        guard let createdSession = DASessionCreate(kCFAllocatorDefault) else {
            lock.unlock()
            emit("[guard] macCollectGuard inactive: mount protection session could not be created.")
            return
        }

        let retainedContext = Unmanaged.passRetained(self).toOpaque()
        contextPointer = retainedContext
        session = createdSession

        DARegisterDiskMountApprovalCallback(createdSession, nil, macCollectGuardMountApproval, retainedContext)
        DARegisterDiskUnmountApprovalCallback(createdSession, nil, macCollectGuardUnmountApproval, retainedContext)
        DARegisterDiskEjectApprovalCallback(createdSession, nil, macCollectGuardEjectApproval, retainedContext)
        DASessionScheduleWithRunLoop(createdSession, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let message = statusTextLocked()
        lock.unlock()
        emit("[guard] \(message)")
    }

    public func updateProtectedDevices(from candidates: [SourceCandidate]) {
        let root = Self.currentRootDeviceIdentifiers()
        let protected = candidates.filter { Self.shouldProtect($0, rootDevices: root) }
        let devices = Set(protected.map(\.deviceIdentifier).filter { !$0.isEmpty })
        let containers = Set(protected.compactMap(\.containerReference).filter { !$0.isEmpty })

        lock.withLock {
            rootDevices = root
            protectedDevices = devices
            protectedContainers = containers
        }

        let protectedText = devices.isEmpty ? "none" : devices.sorted().joined(separator: ", ")
        emit("[guard] protected source volumes: \(protectedText)")
    }

    public func withTemporaryAllowance<T>(
        deviceIdentifier: String,
        operations: Set<Operation>,
        seconds: TimeInterval = 45,
        _ body: () throws -> T
    ) rethrows -> T {
        let normalized = Self.normalizeDeviceIdentifier(deviceIdentifier)
        let expiry = Date().addingTimeInterval(seconds)
        lock.withLock {
            for operation in operations {
                allowedOperations[AllowanceKey(device: normalized, operation: operation)] = expiry
            }
        }
        defer {
            lock.withLock {
                for operation in operations {
                    allowedOperations.removeValue(forKey: AllowanceKey(device: normalized, operation: operation))
                }
            }
        }
        return try body()
    }

    fileprivate func approval(for disk: DADisk, operation: Operation) -> Unmanaged<DADissenter>? {
        let info = Self.diskInfo(from: disk)
        guard shouldDeny(device: info.deviceIdentifier, operation: operation, description: info) else {
            return nil
        }

        let reason = "macCollectGuard blocked \(operation.rawValue) for protected source \(info.deviceIdentifier)"
        emit("[guard] blocked \(operation.rawValue): \(info.summary)")
        let dissenter = DADissenterCreate(kCFAllocatorDefault, DAReturn(kDAReturnNotPermitted), reason as CFString)
        return Unmanaged.passRetained(dissenter)
    }

    private func shouldDeny(device: String, operation: Operation, description: DiskDescription) -> Bool {
        let now = Date()
        let normalized = Self.normalizeDeviceIdentifier(device)

        return lock.withLock {
            allowedOperations = allowedOperations.filter { $0.value > now }

            if let expiry = allowedOperations[AllowanceKey(device: normalized, operation: operation)], expiry > now {
                return false
            }
            if rootDevices.contains(normalized) || description.mountPoint == "/" {
                return false
            }
            if description.isExternal || description.isDiskImage {
                return false
            }
            if description.isMacCollectVolume {
                return false
            }
            if protectedContainers.contains(normalized) {
                return true
            }
            if protectedDevices.contains(normalized) {
                return true
            }
            if let container = description.containerIdentifier,
               protectedContainers.contains(Self.normalizeDeviceIdentifier(container)) {
                return true
            }
            return false
        }
    }

    private func statusTextLocked() -> String {
        guard hasStarted else { return "macCollectGuard not started." }
        guard session != nil else { return "macCollectGuard inactive." }
        if protectedDevices.isEmpty {
            return "macCollectGuard active; waiting for APFS source scan."
        }
        return "macCollectGuard active; protecting \(protectedDevices.sorted().joined(separator: ", "))."
    }

    private func emit(_ line: String) {
        let handler = lock.withLock { logHandler }
        handler?(line)
    }

    private static func shouldProtect(_ candidate: SourceCandidate, rootDevices: Set<String>) -> Bool {
        let device = normalizeDeviceIdentifier(candidate.deviceIdentifier)
        guard !device.isEmpty else { return false }
        guard !rootDevices.contains(device), candidate.mountPoint != "/" else { return false }
        guard candidate.internalDisk != false else { return false }
        guard !candidate.isKnownAuxiliaryVolume else { return false }
        guard candidate.roles.contains("Data") || candidate.roles.contains("System") else { return false }
        return true
    }

    private static func diskInfo(from disk: DADisk) -> DiskDescription {
        let bsdName = DADiskGetBSDName(disk).map { String(cString: $0) } ?? ""
        let description = DADiskCopyDescription(disk) as NSDictionary?
        let volumeName = description?.object(forKey: kDADiskDescriptionVolumeNameKey) as? String
        let volumePath = description?.object(forKey: kDADiskDescriptionVolumePathKey) as? URL
        let mediaKind = description?.object(forKey: kDADiskDescriptionMediaKindKey) as? String
        let volumeKind = description?.object(forKey: kDADiskDescriptionVolumeKindKey) as? String
        let protocolName = description?.object(forKey: kDADiskDescriptionDeviceProtocolKey) as? String
        let internalDevice = description?.object(forKey: kDADiskDescriptionDeviceInternalKey) as? Bool
        let whole = description?.object(forKey: kDADiskDescriptionMediaWholeKey) as? Bool
        let content = description?.object(forKey: kDADiskDescriptionMediaContentKey) as? String
        let container = description?.object(forKey: kDADiskDescriptionMediaUUIDKey) as? String

        return DiskDescription(
            deviceIdentifier: normalizeDeviceIdentifier(bsdName),
            volumeName: volumeName,
            mountPoint: volumePath?.path,
            mediaKind: mediaKind,
            volumeKind: volumeKind,
            protocolName: protocolName,
            internalDevice: internalDevice,
            whole: whole,
            content: content,
            containerIdentifier: container
        )
    }

    private static func currentRootDeviceIdentifiers() -> Set<String> {
        guard let result = try? CommandRunner.run("/sbin/mount", timeoutSeconds: 2) else { return [] }
        var devices: Set<String> = []
        for line in result.stdout.split(separator: "\n").map(String.init) {
            guard let onRange = line.range(of: " on "),
                  let optionsRange = line.range(of: " (", options: .backwards) else { continue }
            let mountPoint = String(line[onRange.upperBound..<optionsRange.lowerBound])
            guard mountPoint == "/" else { continue }
            let device = String(line[..<onRange.lowerBound])
            let normalized = normalizeDeviceIdentifier(device)
            if !normalized.isEmpty {
                devices.insert(normalized)
            }
        }
        return devices
    }

    private static func normalizeDeviceIdentifier(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/dev/r", with: "")
            .replacingOccurrences(of: "/dev/", with: "")
    }
}

private struct AllowanceKey: Hashable {
    let device: String
    let operation: MacCollectGuard.Operation
}

private struct DiskDescription {
    let deviceIdentifier: String
    let volumeName: String?
    let mountPoint: String?
    let mediaKind: String?
    let volumeKind: String?
    let protocolName: String?
    let internalDevice: Bool?
    let whole: Bool?
    let content: String?
    let containerIdentifier: String?

    var isExternal: Bool {
        internalDevice == false
    }

    var isDiskImage: Bool {
        let combined = "\(mediaKind ?? "") \(volumeKind ?? "") \(protocolName ?? "") \(content ?? "")".lowercased()
        return combined.contains("disk image") || combined.contains("diskimage")
    }

    var isMacCollectVolume: Bool {
        let lowerName = volumeName?.lowercased() ?? ""
        let lowerMount = mountPoint?.lowercased() ?? ""
        return lowerName == "maccollect" ||
            lowerName == "maccollect_evidence" ||
            lowerName.hasPrefix("maccollect") ||
            lowerMount == "/volumes/maccollect" ||
            lowerMount == "/volumes/maccollect_evidence" ||
            lowerMount.hasPrefix("/volumes/maccollect")
    }

    var summary: String {
        var parts = [deviceIdentifier]
        if let volumeName, !volumeName.isEmpty { parts.append(volumeName) }
        if let mountPoint, !mountPoint.isEmpty { parts.append(mountPoint) }
        if let protocolName, !protocolName.isEmpty { parts.append(protocolName) }
        return parts.joined(separator: " | ")
    }
}

private let macCollectGuardMountApproval: DADiskMountApprovalCallback = { disk, context in
    guard let context else { return nil }
    let guardInstance = Unmanaged<MacCollectGuard>.fromOpaque(context).takeUnretainedValue()
    return guardInstance.approval(for: disk, operation: .mount)
}

private let macCollectGuardUnmountApproval: DADiskUnmountApprovalCallback = { disk, context in
    guard let context else { return nil }
    let guardInstance = Unmanaged<MacCollectGuard>.fromOpaque(context).takeUnretainedValue()
    return guardInstance.approval(for: disk, operation: .unmount)
}

private let macCollectGuardEjectApproval: DADiskEjectApprovalCallback = { disk, context in
    guard let context else { return nil }
    let guardInstance = Unmanaged<MacCollectGuard>.fromOpaque(context).takeUnretainedValue()
    return guardInstance.approval(for: disk, operation: .eject)
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
