import SwiftUI
import macCollectBasicCore

struct VolumesPanel: View {
    let volumes: [VolumeInfo]
    let unlockState: SecurityUnlockInfo
    let isRefreshing: Bool
    let guardLogLines: [String]
    let refresh: () -> Void
    @State private var recoveryCandidates: [SourceCandidate] = []
    @State private var selectedUnlockDevice = ""
    @State private var unlockPassphrase = ""
    @State private var isScanningRecoveryVolumes = false
    @State private var isRunningVolumeAction = false
    @State private var actionStatus = ""
    @State private var pendingWritableMountDevice = ""
    @State private var showWritableMountConfirmation = false
    @State private var showGuardLogs = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(title: "Volumes", subtitle: summary) {
                if ForensicDataRoot.isRecoveryEnvironment {
                    Button(action: { showGuardLogs = true }) {
                        Label("Guard Logs", systemImage: "shield.lefthalf.filled")
                    }
                }
                Button(action: refreshAll) {
                    Label(isRefreshing ? "Refreshing" : "Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing || isRunningVolumeAction)
            }

            HStack(spacing: 8) {
                Label(unlockState.state, systemImage: unlockState.isAvailable ? "key.fill" : "key.slash.fill")
                    .foregroundStyle(unlockState.isAvailable ? .green : .orange)
                Text(unlockState.detail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if ForensicDataRoot.isRecoveryEnvironment {
                RecoveryVolumeActionPanel(
                    candidates: recoveryCandidates,
                    selectedUnlockDevice: $selectedUnlockDevice,
                    unlockPassphrase: $unlockPassphrase,
                    isScanning: isScanningRecoveryVolumes,
                    isRunning: isRunningVolumeAction,
                    status: actionStatus,
                    unlock: unlockRecoveryVolume,
                    mountReadOnly: { runMountAction(.readOnly, device: $0) },
                    mountWritable: requestWritableMount,
                    unmount: { runMountAction(.unmount, device: $0) }
                )
            }

            GeometryReader { proxy in
                let columns = VolumeColumns(width: proxy.size.width)
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        VolumeHeader(columns: columns)
                        ForEach(sortedVolumes) { volume in
                            VolumeRow(volume: volume, columns: columns)
                        }
                    }
                    .frame(minWidth: columns.total, alignment: .leading)
                    .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor))
                .border(Color.secondary.opacity(0.25))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .onAppear(perform: scanRecoveryVolumesIfNeeded)
        .sheet(isPresented: $showGuardLogs) {
            GuardLogsSheet(lines: guardLogLines)
        }
        .alert("Mount read-write?", isPresented: $showWritableMountConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingWritableMountDevice = ""
            }
            Button("Mount RW", role: .destructive) {
                let device = pendingWritableMountDevice
                pendingWritableMountDevice = ""
                runMountAction(.writable, device: device)
            }
        } message: {
            Text("Read-write mounting can change metadata or write journal state on the source volume. Use it only when you intentionally need write access.")
        }
    }

    private var summary: String {
        let mounted = volumes.filter { !$0.path.isEmpty }.count
        let data = volumes.filter(\.isDataVolume).count
        return "\(mounted) mounted, \(data) Data, \(volumes.count) total"
    }

    private var sortedVolumes: [VolumeInfo] {
        volumes.sorted {
            let left = $0.identifier.isEmpty ? $0.name : $0.identifier
            let right = $1.identifier.isEmpty ? $1.name : $1.identifier
            let order = left.localizedStandardCompare(right)
            return order == .orderedSame ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : order == .orderedAscending
        }
    }

    private func refreshAll() {
        refresh()
        scanRecoveryVolumes()
    }

    private func scanRecoveryVolumesIfNeeded() {
        guard ForensicDataRoot.isRecoveryEnvironment, recoveryCandidates.isEmpty else { return }
        scanRecoveryVolumes()
    }

    private func scanRecoveryVolumes() {
        guard ForensicDataRoot.isRecoveryEnvironment else { return }
        isScanningRecoveryVolumes = true
        if actionStatus.isEmpty {
            actionStatus = "Scanning recovery volumes..."
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let candidates = RecoverySourceScanner.scan()
            MacCollectGuard.shared.updateProtectedDevices(from: candidates)
            DispatchQueue.main.async {
                recoveryCandidates = candidates
                if selectedUnlockDevice.isEmpty {
                    selectedUnlockDevice = candidates.first(where: { $0.locked == true && ($0.fileVault == true || $0.encrypted == true) })?.deviceIdentifier ?? ""
                }
                isScanningRecoveryVolumes = false
                if actionStatus == "Scanning recovery volumes..." {
                    actionStatus = candidates.isEmpty ? "No recovery volumes detected." : "Recovery volumes loaded."
                }
            }
        }
    }

    private func unlockRecoveryVolume() {
        guard !selectedUnlockDevice.isEmpty, !unlockPassphrase.isEmpty else { return }
        let device = selectedUnlockDevice
        let passphrase = unlockPassphrase
        unlockPassphrase = ""
        isRunningVolumeAction = true
        actionStatus = "Unlocking \(device) without mounting..."
        DispatchQueue.global(qos: .userInitiated).async {
            let result: CommandResult
            do {
                result = try RecoverySourceScanner.unlockVolume(deviceIdentifier: device, passphrase: passphrase)
            } catch {
                DispatchQueue.main.async {
                    isRunningVolumeAction = false
                    actionStatus = error.localizedDescription
                }
                return
            }
            finishVolumeAction(result, success: "\(device) unlocked and left unmounted.")
        }
    }

    private func requestWritableMount(_ device: String) {
        guard !device.isEmpty else { return }
        pendingWritableMountDevice = device
        showWritableMountConfirmation = true
    }

    private enum RecoveryMountAction {
        case readOnly
        case writable
        case unmount
    }

    private func runMountAction(_ action: RecoveryMountAction, device: String) {
        guard !device.isEmpty else { return }
        isRunningVolumeAction = true
        switch action {
        case .readOnly:
            actionStatus = "Mounting \(device) read-only..."
        case .writable:
            actionStatus = "Mounting \(device) read-write..."
        case .unmount:
            actionStatus = "Unmounting \(device)..."
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result: CommandResult
            switch action {
            case .readOnly:
                result = RecoverySourceScanner.mountReadOnly(deviceIdentifier: device)
            case .writable:
                result = RecoverySourceScanner.mountWritable(deviceIdentifier: device)
            case .unmount:
                result = RecoverySourceScanner.unmount(deviceIdentifier: device)
            }
            let success: String
            switch action {
            case .readOnly:
                success = "\(device) mounted read-only."
            case .writable:
                success = "\(device) mounted read-write."
            case .unmount:
                success = "\(device) unmounted."
            }
            finishVolumeAction(result, success: success)
        }
    }

    private func finishVolumeAction(_ result: CommandResult, success: String) {
        let output = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshedCandidates = RecoverySourceScanner.scan()
        DispatchQueue.main.async {
            actionStatus = result.exitCode == 0 ? success : (output.isEmpty ? "diskutil exited \(result.exitCode)." : output)
            recoveryCandidates = refreshedCandidates
            refresh()
            isRunningVolumeAction = false
        }
    }
}

private struct GuardLogsSheet: View {
    let lines: [String]
    @Environment(\.dismiss) private var dismiss

    private var displayLines: [String] {
        let filtered = lines.filter { $0.contains("[guard]") }
        if filtered.isEmpty {
            return [timestampedLogLine("[guard] No macCollectGuard log entries captured yet.")]
        }
        return filtered
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("macCollectGuard Logs", systemImage: "shield.lefthalf.filled")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            Text("Mount, unmount and eject decisions for protected internal source volumes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            LogPanel(lines: displayLines, height: 420)
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 520)
    }
}

private struct RecoveryVolumeActionPanel: View {
    let candidates: [SourceCandidate]
    @Binding var selectedUnlockDevice: String
    @Binding var unlockPassphrase: String
    let isScanning: Bool
    let isRunning: Bool
    let status: String
    let unlock: () -> Void
    let mountReadOnly: (String) -> Void
    let mountWritable: (String) -> Void
    let unmount: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Recovery Volume Control", systemImage: "externaldrive.badge.gearshape")
                    .font(.headline)
                Spacer()
                Text(summary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !lockedCandidates.isEmpty {
                HStack(spacing: 8) {
                    Picker("", selection: $selectedUnlockDevice) {
                        ForEach(lockedCandidates) { candidate in
                            Text("\(candidate.deviceIdentifier) \(candidate.name)").tag(candidate.deviceIdentifier)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    SecureField("FileVault password or recovery key", text: $unlockPassphrase)
                        .textFieldStyle(.roundedBorder)
                    Button(action: unlock) {
                        Label("Unlock", systemImage: "lock.open")
                    }
                    .disabled(isRunning || selectedUnlockDevice.isEmpty || unlockPassphrase.isEmpty)
                }
            }

            if isScanning && candidates.isEmpty {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning recovery volumes...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if displayCandidates.isEmpty {
                Text("No mountable recovery volumes detected yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        header("Device")
                        header("Name")
                        header("Status")
                        header("Mount")
                        header("Actions")
                    }
                    Divider()
                        .gridCellColumns(5)
                    ForEach(displayCandidates) { candidate in
                        GridRow {
                            Text(candidate.deviceIdentifier)
                                .font(.caption.monospaced())
                            Text(candidate.name.isEmpty ? "Volume" : candidate.name)
                                .font(.caption)
                                .lineLimit(1)
                            RecoveryVolumeStateIcons(candidate: candidate)
                            Text(candidate.mountPoint ?? "Not mounted")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 4) {
                                Button("Mount R") { mountReadOnly(candidate.deviceIdentifier) }
                                    .disabled(isRunning || candidate.locked == true)
                                Button("Mount RW") { mountWritable(candidate.deviceIdentifier) }
                                    .disabled(isRunning || candidate.locked == true)
                                Button("Unmount") { unmount(candidate.deviceIdentifier) }
                                    .disabled(isRunning || !candidate.isMounted)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .textSelection(.enabled)
            }

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var lockedCandidates: [SourceCandidate] {
        candidates.filter { $0.locked == true && ($0.fileVault == true || $0.encrypted == true) }
    }

    private var displayCandidates: [SourceCandidate] {
        candidates
            .filter { !$0.roles.contains("APFS Container") && !$0.isKnownAuxiliaryVolume }
            .prefix(14)
            .map { $0 }
    }

    private var summary: String {
        let locked = candidates.filter { $0.locked == true }.count
        let mounted = candidates.filter(\.isMounted).count
        return "\(locked) locked, \(mounted) mounted"
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct RecoveryVolumeStateIcons: View {
    let candidate: SourceCandidate

    var body: some View {
        HStack(spacing: 5) {
            RecoveryStatePill(
                icon: candidate.locked == true ? "lock.fill" : "lock.open.fill",
                label: candidate.locked == true ? "Locked" : "Unlocked",
                color: candidate.locked == true ? .orange : .green
            )
            RecoveryStatePill(
                icon: candidate.isMounted ? "externaldrive.fill" : "externaldrive",
                label: candidate.isMounted ? "Mounted" : "Unmounted",
                color: candidate.isMounted ? .blue : .secondary
            )
            RecoveryStatePill(
                icon: writeIcon,
                label: writeLabel,
                color: writeColor
            )
        }
    }

    private var writeIcon: String {
        guard candidate.isMounted else { return "pencil.slash" }
        if candidate.readOnly == true { return "pencil.slash" }
        if candidate.readOnly == false { return "pencil" }
        return "questionmark.circle"
    }

    private var writeLabel: String {
        guard candidate.isMounted else { return "No write" }
        if candidate.readOnly == true { return "Read-only" }
        if candidate.readOnly == false { return "Read-write" }
        return "Write ?"
    }

    private var writeColor: Color {
        guard candidate.isMounted else { return .secondary }
        if candidate.readOnly == true { return .green }
        if candidate.readOnly == false { return .red }
        return .orange
    }
}

private struct RecoveryStatePill: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .imageScale(.small)
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(color.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .help(label)
    }
}

private struct VolumeColumns {
    let id: CGFloat = 125
    let name: CGFloat = 360
    let state: CGFloat = 210
    let size: CGFloat = 110
    let mount: CGFloat

    init(width: CGFloat) {
        mount = max(240, width - id - name - state - size)
    }

    var total: CGFloat { id + name + state + size + mount }
}

private struct VolumeHeader: View {
    let columns: VolumeColumns

    var body: some View {
        HStack(spacing: 0) {
            cell("ID", columns.id, header: true)
            cell("Name", columns.name, header: true)
            cell("State", columns.state, header: true)
            cell("Size", columns.size, header: true)
            cell("Mount / Usage", columns.mount, header: true)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct VolumeRow: View {
    let volume: VolumeInfo
    let columns: VolumeColumns

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            idCell
            nameCell
            stateCell
            cell(volume.size, columns.size, emphasized: volume.isDataVolume)
            mountCell
        }
        .background(volume.color.opacity(volume.isDataVolume ? 0.16 : 0.08))
    }

    private var idCell: some View {
        HStack(spacing: 3) {
            Color.clear
                .frame(width: CGFloat(max(volume.indentLevel, 0)) * 14)
            Text(branch)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: volume.indentLevel > 0 ? 10 : 0, alignment: .leading)
            Text(volume.identifier.isEmpty ? "-" : volume.identifier)
                .fontWeight(volume.isDataVolume ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .volumeCell(width: columns.id)
    }

    private var nameCell: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.displayName)
                    .fontWeight(volume.isDataVolume ? .semibold : .regular)
                    .lineLimit(1)
                if let detail = volume.typeDetail {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .volumeCell(width: columns.name)
    }

    private var stateCell: some View {
        HStack(spacing: 4) {
            if let roleLabel = volume.roleLabel {
                volumeBadge(roleLabel, volume.isDataVolume ? .orange : .gray)
            }
            if let writeStateLabel = volume.writeStateLabel {
                volumeBadge(writeStateLabel, volume.isReadOnly == true ? .green : .orange)
            }
            if volume.path.isEmpty { volumeBadge("Unmounted", .gray) }
            if volume.status.localizedCaseInsensitiveContains("synthesized") { volumeBadge("Synth", .teal) }
        }
        .volumeCell(width: columns.state)
    }

    private var mountCell: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(volume.path.isEmpty ? "-" : volume.path)
                .lineLimit(1)
                .truncationMode(.middle)
            if let usageText = volume.usageText {
                Text(usageText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .volumeCell(width: columns.mount)
    }

    private var branch: String {
        volume.indentLevel > 0 ? "└" : ""
    }
}

private func cell(_ text: String, _ width: CGFloat, header: Bool = false, emphasized: Bool = false) -> some View {
    Text(text)
        .fontWeight(header || emphasized ? .semibold : .regular)
        .lineLimit(1)
        .truncationMode(.middle)
        .volumeCell(width: width)
}

private func volumeBadge(_ text: String, _ color: Color) -> some View {
    Text(text)
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.13))
        .foregroundStyle(color)
        .clipShape(RoundedRectangle(cornerRadius: 4))
}

private extension View {
    func volumeCell(width: CGFloat) -> some View {
        self
            .frame(width: width, alignment: .topLeading)
            .frame(minHeight: 30, alignment: .topLeading)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .border(Color.secondary.opacity(0.16), width: 0.5)
    }
}

private extension VolumeInfo {
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.localizedCaseInsensitiveCompare("Unknown") == .orderedSame {
            if isAPFS { return "APFS volume" }
            return "Volume"
        }
        return trimmed
    }

    var typeDetail: String? {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.localizedCaseInsensitiveCompare("Unknown") != .orderedSame else { return nil }
        if isAPFS && displayName == "APFS volume" { return nil }
        return trimmed
    }

    var usageText: String? {
        guard usedBytes != nil || availableBytes != nil else { return nil }
        return "Used \(usedBytes.map(ByteCount.string(from:)) ?? "-") / Free \(availableBytes.map(ByteCount.string(from:)) ?? "-")"
    }

    var isDataVolume: Bool {
        name.localizedCaseInsensitiveContains("Data") || path == "/System/Volumes/Data" || path.hasSuffix("/Data")
    }

    var roleLabel: String? {
        if isDataVolume { return "Data" }
        if name.localizedCaseInsensitiveContains("Macintosh HD") { return "System" }
        if type.localizedCaseInsensitiveContains("disk image") { return "Disk image" }
        return nil
    }

    var writeStateLabel: String? {
        guard let isReadOnly else { return nil }
        return isReadOnly ? "Read-only" : "Writable"
    }

    var isAPFS: Bool {
        type.localizedCaseInsensitiveContains("APFS")
    }

    var color: Color {
        if isDataVolume { return .orange }
        if isReadOnly == true { return .green }
        if type.localizedCaseInsensitiveContains("disk image") { return .purple }
        if path.localizedCaseInsensitiveContains("/System/Volumes") { return .teal }
        return .blue
    }
}
