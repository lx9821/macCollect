import AppKit
import SwiftUI
import UniformTypeIdentifiers
import macCollectBasicCore

final class USBBuilderState: ObservableObject {
    @Published var selectedDiskID = ""
    @Published var includeEvidencePartition = true
    @Published var caseDriveDestinationName = "macCollect_Evidence"
    @Published var caseDriveDestinationFormat: DestinationDiskFormat = .apfs
    @Published var disks: [ExternalDisk] = USBImageBuilder.externalDisks()
    @Published var isWorking = false
    @Published var showCommandDetails = false
    @Published var caseDriveStatus = "Select a target and review the erase command."
}

struct USBBuilderPanel: View {
    @ObservedObject var state: USBBuilderState
    var onActivityChange: (Bool, String, Double) -> Void = { _, _, _ in }
    private let caseDriveBootSizeMegabytes = 50

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Header(title: "USB Builder", subtitle: "Prepare a dual-partition macCollect case drive") {
                    Button(action: refreshDisks) {
                        Label("Refresh Disks", systemImage: "arrow.clockwise")
                    }
                    .disabled(state.isWorking)
                }

                selectableDisks

                if let selectedDisk {
                    caseDriveCard(selectedDisk)
                }
            }
            .padding(28)
        }
    }

    private var selectableDisks: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selectable External Disks")
                .font(.headline)
            if state.disks.isEmpty {
                Text("No selectable external whole disks detected.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(state.disks) { disk in
                    Button(action: { selectDisk(disk) }) {
                        HStack {
                            Image(systemName: state.selectedDiskID == disk.id ? "largecircle.fill.circle" : "circle")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(disk.displayName)
                                HStack(spacing: 6) {
                                    USBDeviceMetadataBadge(label: "Protocol", value: disk.protocolName, tint: .blue)
                                    USBDeviceMetadataBadge(label: disk.safeToFlash ? "Safety" : "Blocked", value: disk.safetySummary, tint: disk.safeToFlash ? .green : .red)
                                }
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(state.selectedDiskID == disk.id ? Color.accentColor.opacity(0.16) : Color.clear)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func caseDriveCard(_ disk: ExternalDisk) -> some View {
        InfoCard(title: "Case Drive") {
            Toggle("Create evidence partition", isOn: $state.includeEvidencePartition)
            if state.includeEvidencePartition {
                InfoLine("Boot Partition", "\(caseDriveBootSizeMegabytes) MB fixed")
            } else {
                Label("No evidence partition will be created. The whole stick becomes the macCollect launcher volume; write evidence to another external destination.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                InfoLine("macCollect Partition", "Uses remaining drive size")
            }
            InputRow("Destination File System") {
                Picker("", selection: $state.caseDriveDestinationFormat) {
                    ForEach(DestinationDiskFormat.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520, alignment: .leading)
            }
            .disabled(!state.includeEvidencePartition)
            InputRow("Destination Name") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Destination volume name", text: $state.caseDriveDestinationName)
                    if let warning = exFATNameWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .disabled(!state.includeEvidencePartition)
            CaseDrivePartitionPreview(
                disk: disk,
                bootSizeMegabytes: caseDriveBootSizeMegabytes,
                destinationFormat: state.caseDriveDestinationFormat,
                destinationName: safeCaseDriveDestinationName,
                includeEvidencePartition: state.includeEvidencePartition
            )
            DisclosureGroup(isExpanded: $state.showCommandDetails) {
                USBCommandPreview(
                    diskID: state.selectedDiskID,
                    partitionCommand: USBImageBuilder.caseDriveCommand(
                        diskID: state.selectedDiskID,
                        bootSizeMegabytes: caseDriveBootSizeMegabytes,
                        destinationFormat: state.caseDriveDestinationFormat,
                        destinationVolumeName: safeCaseDriveDestinationName,
                        includeEvidencePartition: state.includeEvidencePartition
                    ),
                    destinationVolumeName: safeCaseDriveDestinationName
                )
                .padding(.top, 4)
            } label: {
                Label("Technical command details", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
            HStack(spacing: 8) {
                Image(systemName: state.isWorking ? "hourglass" : "info.circle")
                    .foregroundStyle(state.isWorking ? Color.accentColor : Color.secondary)
                Text(state.caseDriveStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(action: prepareCaseDrive) {
                Label("Prepare Case Drive", systemImage: "externaldrive.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(state.isWorking || !disk.safeToFlash)
        }
    }

    private var selectedDisk: ExternalDisk? {
        state.disks.first { $0.id == state.selectedDiskID }
    }

    private var safeCaseDriveDestinationName: String {
        USBImageBuilder.sanitizedCaseDestinationName(
            state.caseDriveDestinationName,
            format: state.caseDriveDestinationFormat
        )
    }

    private var exFATNameWarning: String? {
        guard state.caseDriveDestinationFormat == .exfat else { return nil }
        let raw = state.caseDriveDestinationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = safeCaseDriveDestinationName
        let allowed = CharacterSet.alphanumerics
        let normalized = String(raw.unicodeScalars.compactMap { allowed.contains($0) ? Character($0) : nil })
        guard normalized.count > 11 || normalized != sanitized else { return nil }
        return "ExFAT volume names are limited here to 11 letters/numbers; this will be written as \(sanitized)."
    }

    private func refreshDisks() {
        state.disks = USBImageBuilder.externalDisks()
        if !state.disks.contains(where: { $0.id == state.selectedDiskID }) {
            state.selectedDiskID = state.disks.first?.id ?? ""
        }
        state.caseDriveStatus = "Disk list refreshed."
    }

    private func prepareCaseDrive() {
        guard selectedDisk?.safeToFlash == true else {
            state.caseDriveStatus = "Selected disk is not a safe case-drive target."
            return
        }
        state.caseDriveStatus = "Confirm the erase dialog to continue."
        let alert = NSAlert()
        alert.messageText = "Erase and prepare /dev/\(state.selectedDiskID) as a case drive?"
        alert.informativeText = "This will erase the selected external disk completely."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Prepare")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            state.caseDriveStatus = "Preparation cancelled."
            return
        }

        state.isWorking = true
        state.caseDriveStatus = "Preparing target. macOS may ask for Removable Volumes access while files are copied."
        onActivityChange(true, "Waiting for authorization", 0.08)
        let diskID = state.selectedDiskID
        let destinationName = safeCaseDriveDestinationName
        let destinationFormat = state.caseDriveDestinationFormat
        let includeEvidencePartition = state.includeEvidencePartition
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try USBImageBuilder.prepareCaseDrive(
                    diskID: diskID,
                    bootSizeMegabytes: caseDriveBootSizeMegabytes,
                    destinationFormat: destinationFormat,
                    destinationVolumeName: destinationName,
                    includeEvidencePartition: includeEvidencePartition
                ) { line in
                    DispatchQueue.main.async { reportProgress(line) }
                }
                DispatchQueue.main.async {
                    state.isWorking = false
                    state.caseDriveStatus = "Case drive completed."
                    onActivityChange(false, state.caseDriveStatus, 1)
                    refreshDisks()
                }
            } catch {
                DispatchQueue.main.async {
                    state.isWorking = false
                    state.caseDriveStatus = "Case drive failed: \(error.localizedDescription)"
                    onActivityChange(false, state.caseDriveStatus, 1)
                }
            }
        }
    }

    private func reportProgress(_ line: String) {
        guard state.isWorking else { return }
        let status = usbActivity(from: line)
        state.caseDriveStatus = status.text
        onActivityChange(true, status.text, status.progress)
    }

    private func usbActivity(from line: String) -> (text: String, progress: Double) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("$ ") || lower.contains("/usr/sbin/") || lower.contains("/usr/bin/") || lower.contains("osascript") {
            if lower.contains("partitiondisk") || lower.contains("diskutil") {
                return ("Partitioning target disk", 0.22)
            }
            if lower.contains("ditto") {
                return ("Copying launcher files", 0.48)
            }
            return ("Running preparation step", 0.18)
        }
        if trimmed.localizedCaseInsensitiveContains("Partitioning case drive") {
            return ("Partitioning target disk", 0.22)
        }
        if trimmed.localizedCaseInsensitiveContains("Copying launcher payload") {
            return ("Copying launcher files", 0.48)
        }
        if trimmed.localizedCaseInsensitiveContains("Preparing destination volume") {
            return ("Preparing evidence volume", 0.72)
        }
        if trimmed.localizedCaseInsensitiveContains("Destination partition ready") {
            return ("Finalizing case drive", 0.9)
        }
        if trimmed.localizedCaseInsensitiveContains("Case drive completed") {
            return ("Case drive completed", 1)
        }
        if trimmed.localizedCaseInsensitiveContains("[error]") {
            return ("Case drive failed", 1)
        }
        return ("Preparing case drive", 0.12)
    }

    private func selectDisk(_ disk: ExternalDisk) {
        state.selectedDiskID = disk.id
        state.caseDriveStatus = "Selected /dev/\(disk.id). Review the erase command before preparing."
    }
}

struct USBDeviceMetadataBadge: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(tint)
                .fontWeight(.semibold)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct USBCommandPreview: View {
    let diskID: String
    let partitionCommand: String
    let destinationVolumeName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(commands.indices, id: \.self) { index in
                    commandRow(commands[index])
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))

            Text("Runtime temp paths and mounted volume paths are resolved after diskutil finishes. macOS may ask for Removable Volumes access before the copy step.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ToolLegend(items: [
                ToolLegendItem(name: "diskutil", detail: "partition selected whole disk and create both volumes", color: .blue),
                ToolLegendItem(name: "ditto", detail: "copy macCollect.app bundle to the launcher volume", color: .orange),
                ToolLegendItem(name: "Swift/FileManager", detail: "stage payload and copy support files that are not shell commands", color: .teal),
                ToolLegendItem(name: "sync", detail: "flush staged writes before the case drive is used", color: .purple)
            ])
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func commandRow(_ item: USBPreviewCommand) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(item.kind.prefix)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.color)
                if item.kind == .shell {
                    Text(highlightedCommand(item.detail))
                        .font(.system(size: 11, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 1)
                .fill(item.color.opacity(0.75))
                .frame(width: 2)
        }
    }

    private func highlightedCommand(_ command: String) -> AttributedString {
        let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var highlighted = AttributedString()
        var firstToken = true

        for part in parts {
            if !firstToken {
                highlighted.append(AttributedString(" "))
            }
            var token = AttributedString(part)
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)

            if firstToken || commandNames.contains(trimmed) {
                token.foregroundColor = commandTint(trimmed)
                token.font = .system(size: 11, weight: .semibold, design: .monospaced)
            } else if trimmed.hasPrefix("-") {
                token.foregroundColor = .purple
            } else if trimmed.hasPrefix("/dev/") || trimmed.contains("/") {
                token.foregroundColor = .teal
            } else if ["partitionDisk", "GPT", "JHFS+", "APFS", "ExFAT", "R"].contains(trimmed) {
                token.foregroundColor = .orange
            } else {
                token.foregroundColor = .primary
            }

            highlighted.append(token)
            firstToken = false
        }
        return highlighted
    }

    private var commands: [USBPreviewCommand] {
        [
            USBPreviewCommand(kind: .internalStep, label: "Stage payload", detail: "Swift creates a temporary payload directory, copies macCollect.app with the root-aware launcher, then writes .IAPhysicalMedia, start.sh and en.lproj.", color: .teal),
            USBPreviewCommand(kind: .shell, label: "Erase and partition", detail: partitionCommand, color: .blue),
            USBPreviewCommand(kind: .shell, label: "Copy app bundle", detail: "/usr/bin/ditto --noqtn <temp payload>/macCollect.app /Volumes/macCollect/macCollect.app", color: .orange),
            USBPreviewCommand(kind: .internalStep, label: "Copy launcher support", detail: "Swift FileManager copies .IAPhysicalMedia, en.lproj and start.sh to /Volumes/macCollect.", color: .teal),
            USBPreviewCommand(kind: .shell, label: "Flush writes", detail: "/bin/sync", color: .purple)
        ]
    }

    private var commandNames: Set<String> {
        ["/usr/sbin/diskutil", "diskutil", "/usr/bin/ditto", "ditto", "/bin/sync", "sync"]
    }

    private func commandTint(_ command: String) -> Color {
        switch command {
        case "/usr/sbin/diskutil", "diskutil":
            return .blue
        case "/usr/bin/ditto", "ditto":
            return .orange
        case "/bin/sync", "sync":
            return .purple
        default:
            return .teal
        }
    }
}

private struct USBPreviewCommand {
    let kind: USBPreviewCommandKind
    let label: String
    let detail: String
    let color: Color
}

private enum USBPreviewCommandKind {
    case shell
    case internalStep

    var prefix: String {
        switch self {
        case .shell: return "$"
        case .internalStep: return "APP"
        }
    }
}

struct CaseDrivePartitionPreview: View {
    let disk: ExternalDisk
    let bootSizeMegabytes: Int
    let destinationFormat: DestinationDiskFormat
    let destinationName: String
    let includeEvidencePartition: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Partition Preview", systemImage: "chart.bar.xaxis")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(disk.sizeBytes.map(ByteCount.string(from:)) ?? disk.size)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    if includeEvidencePartition {
                        Rectangle().fill(Color.blue).frame(width: segmentWidth(bytes: bootBytes, totalWidth: proxy.size.width))
                        Rectangle().fill(Color.green).frame(maxWidth: .infinity)
                    } else {
                        Rectangle().fill(Color.blue).frame(maxWidth: .infinity)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 18)
            HStack(spacing: 16) {
                Text("macCollect: \(ByteCount.string(from: macCollectBytes)) HFS+")
                if includeEvidencePartition {
                    Text("\(destinationName): \(ByteCount.string(from: destinationBytes)) \(destinationFormat.label)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var bootBytes: Int64 { Int64(bootSizeMegabytes) * 1_024 * 1_024 }
    private var totalBytes: Int64 { max(disk.sizeBytes ?? 0, bootBytes) }
    private var macCollectBytes: Int64 { includeEvidencePartition ? bootBytes : totalBytes }
    private var destinationBytes: Int64 { max(0, totalBytes - bootBytes) }

    private func segmentWidth(bytes: Int64, totalWidth: CGFloat) -> CGFloat {
        guard totalBytes > 0 else { return 0 }
        let fraction = CGFloat(Double(bytes) / Double(totalBytes))
        return max(8, totalWidth * fraction)
    }
}
