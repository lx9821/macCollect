import AppKit
import SwiftUI
import UniformTypeIdentifiers
import macCollectBasicCore

enum FileVaultCredentialKind: String, CaseIterable, Identifiable {
    case adminPassword
    case recoveryKey

    var id: String { rawValue }

    var label: String {
        switch self {
        case .adminPassword: return "Admin Password"
        case .recoveryKey: return "Recovery Key"
        }
    }

    var prompt: String {
        switch self {
        case .adminPassword:
            return "Local admin or FileVault-enabled user password"
        case .recoveryKey:
            return "Personal recovery key, including dashes"
        }
    }
}

struct StartupLivePanel: View {
    let isCollectingProfile: Bool

    var body: some View {
        VStack(spacing: 18) {
            AppLogoImage(fallbackSystemName: "shippingbox")
                .frame(width: 192, height: 192)
            RootPrivilegeBanner()
                .frame(maxWidth: 620)
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.large)
                Text(statusText)
                    .font(.title3.weight(.semibold))
                Text("macCollect")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var statusText: String {
        if isCollectingProfile {
            return "Preparing workspace..."
        }
        return "Starting..."
    }
}

struct StartupFileVaultPanel: View {
    let candidates: [SourceCandidate]
    @Binding var selectedDevice: String
    @Binding var adminPassword: String
    @Binding var recoveryKey: String
    @Binding var credentialKind: FileVaultCredentialKind
    let isScanning: Bool
    let isUnlocking: Bool
    let isCollectingProfile: Bool
    let logLines: [String]
    let isRecoveryEnvironment: Bool
    let refresh: () -> Void
    let unlock: () -> Void
    let continueWithoutUnlock: () -> Void
    @State private var displayedTime = Date()
    @State private var displayedTimeText = currentSystemDateText()
    @State private var manualTime = Date()
    @State private var displayTimeZone = systemCommandTimeZone()
    @State private var displayTimeOffset: TimeInterval = 0
    @State private var displayTimeOverrideActive = false
    @State private var timeStatus = "Adjust only the time shown inside macCollect. The Mac system clock is not changed."
    @State private var isSettingTime = false
    @State private var showTimeSettings = false
    private let timeTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Header(title: "Recovery Startup", subtitle: "Keep the Mac offline, set system time if needed, then inspect volumes before mounting anything") {
                    Button(action: openTerminal) {
                        Label("Terminal", systemImage: "terminal")
                    }
                    Button(action: refresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isBusy)
                    Button(action: continueWithoutUnlock) {
                        Label("Continue", systemImage: "arrow.right")
                    }
                    .disabled(isBusy)
                }

                RootPrivilegeBanner()

                if isRecoveryEnvironment {
                    StartupTimeToolbar(
                        dateText: displayedTimeText,
                        manualDate: $manualTime,
                        timeZone: $displayTimeZone,
                        status: timeStatus,
                        isSetting: isSettingTime,
                        isPresented: $showTimeSettings,
                        setTime: setManualSystemTime,
                        openTerminal: openTerminal
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if isScanning || isCollectingProfile {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text(isCollectingProfile ? "Collecting available system profile..." : "Scanning APFS/FileVault state...")
                            .foregroundStyle(.secondary)
                    }
                }

                if isScanning {
                    StartupNotice(
                        icon: "magnifyingglass",
                        title: "Checking APFS/FileVault state",
                        message: "macCollect is still reading the Recovery volume state."
                    )
                } else if lockedCandidates.isEmpty {
                    StartupNotice(
                        icon: "checkmark.shield.fill",
                        title: "No locked encrypted APFS volume detected",
                        message: isCollectingProfile ? "macCollect is collecting the available profile now." : "macCollect can continue with profile collection."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Locked FileVault Data Volumes")
                            .font(.headline)
                        Text("Unlocking here only unlocks the APFS volume; it does not mount it. Use Volumes after startup to mount read-only, read-write, or unmount later.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        LazyVStack(spacing: 8) {
                            ForEach(lockedCandidates) { candidate in
                                Button(action: { selectedDevice = candidate.deviceIdentifier }) {
                                    StartupVolumeRow(
                                        candidate: candidate,
                                        isSelected: selectedDevice == candidate.deviceIdentifier
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack {
                        Spacer(minLength: 0)
                        StartupUnlockPromptCard(
                            candidate: selectedCandidate,
                            adminPassword: $adminPassword,
                            recoveryKey: recoveryKeyBinding,
                            credentialKind: $credentialKind,
                            isUnlocking: isUnlocking,
                            isBusy: isBusy,
                            commandPreview: commandPreview,
                            unlock: unlock
                        )
                        .frame(maxWidth: 720)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 6)
                }

                DisclosureGroup {
                    LogPanel(lines: logLines)
                        .padding(.top, 8)
                } label: {
                    Label("Startup logs", systemImage: "doc.text.magnifyingglass")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(timeTicker) { date in
            let effectiveDate = displayTimeOverrideActive ? date.addingTimeInterval(displayTimeOffset) : date
            displayedTime = effectiveDate
            displayedTimeText = formattedSystemDate(effectiveDate, timeZone: displayTimeZone)
            if !showTimeSettings && !isSettingTime {
                manualTime = effectiveDate
            }
        }
        .onAppear {
            displayTimeZone = systemCommandTimeZone()
            let effectiveDate = Date().addingTimeInterval(displayTimeOffset)
            displayedTimeText = formattedSystemDate(effectiveDate, timeZone: displayTimeZone)
        }
        .onChange(of: displayTimeZone) { newValue in
            setSystemDisplayTimeZone(newValue)
            let effectiveDate = Date().addingTimeInterval(displayTimeOffset)
            displayedTimeText = formattedSystemDate(effectiveDate, timeZone: newValue)
        }
    }

    private var isBusy: Bool {
        isScanning || isUnlocking || isCollectingProfile
    }

    private var lockedCandidates: [SourceCandidate] {
        let locked = candidates.filter { candidate in
            candidate.locked == true &&
                (candidate.fileVault == true || candidate.encrypted == true) &&
                !candidate.roles.contains("Preboot") &&
                !candidate.roles.contains("Recovery") &&
                !candidate.roles.contains("VM")
        }
        let data = locked.filter { $0.roles.contains("Data") }
        if !data.isEmpty { return data }
        let unlockedMountedDataExists = candidates.contains { candidate in
            candidate.roles.contains("Data") &&
                candidate.locked != true &&
                candidate.mountPoint?.isEmpty == false
        }
        return unlockedMountedDataExists ? [] : locked
    }

    private var selectedCandidate: SourceCandidate? {
        lockedCandidates.first { $0.deviceIdentifier == selectedDevice } ?? lockedCandidates.first
    }

    private var commandPreview: String {
        let device = selectedDevice.isEmpty ? "<volume>" : selectedDevice
        switch credentialKind {
        case .adminPassword:
            return "diskutil apfs unlockVolume \(device) -nomount -stdinpassphrase"
        case .recoveryKey:
            return "diskutil apfs listCryptoUsers \(device); diskutil apfs unlockVolume \(device) -user <recovery-user-uuid> -nomount -stdinpassphrase"
        }
    }

    private var recoveryKeyBinding: Binding<String> {
        Binding(
            get: { recoveryKey },
            set: { newValue in
                recoveryKey = formattedRecoveryKey(newValue)
            }
        )
    }

    private func formattedRecoveryKey(_ value: String) -> String {
        let characters = value
            .uppercased()
            .filter { $0.isLetter || $0.isNumber }
            .prefix(24)
        return stride(from: 0, to: characters.count, by: 4).map { index -> String in
            let start = characters.index(characters.startIndex, offsetBy: index)
            let end = characters.index(start, offsetBy: min(4, characters.distance(from: start, to: characters.endIndex)))
            return String(characters[start..<end])
        }.joined(separator: "-")
    }

    private func setManualSystemTime() {
        guard isRecoveryEnvironment else { return }
        guard !isSettingTime else { return }
        let target = manualTime
        isSettingTime = true
        timeStatus = "Applying display time inside macCollect only..."
        let targetTimeZone = displayTimeZone
        displayTimeOffset = target.timeIntervalSince(Date())
        displayTimeOverrideActive = true
        displayTimeZone = targetTimeZone
        setSystemDisplayTimeZone(targetTimeZone)
        setAcquisitionDisplayTimeOverride(actualDate: Date(), displayDate: target, timeZone: targetTimeZone)
        displayedTime = target
        displayedTimeText = formattedSystemDate(target, timeZone: targetTimeZone)
        manualTime = target
        isSettingTime = false
        timeStatus = "Display time applied locally in macCollect. System date and time were not changed."
    }

}

struct StartupTimeToolbar: View {
    let dateText: String
    @Binding var manualDate: Date
    @Binding var timeZone: TimeZone
    let status: String
    let isSetting: Bool
    @Binding var isPresented: Bool
    let setTime: () -> Void
    let openTerminal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label("Recovery Display Time", systemImage: "clock")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text(dateText)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .lineLimit(1)
                Text(currentTimeZoneText(timeZone: timeZone, date: manualDate))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: {
                if !isPresented {
                    manualDate = Date()
                }
                isPresented.toggle()
            }) {
                Image(systemName: "gearshape")
            }
            .help("Adjust only the time displayed inside macCollect")
            .buttonStyle(.bordered)
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                StartupTimeSettingsPanel(
                    dateText: dateText,
                    manualDate: $manualDate,
                    timeZone: $timeZone,
                    status: status,
                    isSetting: isSetting,
                    setTime: {
                        setTime()
                        isPresented = false
                    },
                    openTerminal: openTerminal
                )
                .frame(width: 520)
                .padding(14)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct StartupTimeSettingsPanel: View {
    let dateText: String
    @Binding var manualDate: Date
    @Binding var timeZone: TimeZone
    let status: String
    let isSetting: Bool
    let setTime: () -> Void
    let openTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Recovery Display Time", systemImage: "clock.badge.checkmark")
                .font(.headline)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 4) {
                Text("Current: \(dateText)")
                    .font(.callout.monospacedDigit().weight(.semibold))
                Text(currentTimeZoneText(timeZone: timeZone, date: manualDate))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Timezone")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $timeZone) {
                        ForEach(preferredManualTimeZones(), id: \.identifier) { zone in
                            Text(manualTimeZoneLabel(zone, date: manualDate)).tag(zone)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 360)
                }
                GridRow {
                    Text("Date")
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: $manualDate, displayedComponents: .date)
                        .labelsHidden()
                        .environment(\.timeZone, timeZone)
                        .environment(\.locale, Locale(identifier: "en_GB"))
                }
                GridRow {
                    Text("Time")
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: $manualDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .environment(\.timeZone, timeZone)
                        .environment(\.locale, Locale(identifier: "en_GB"))
                }
            }
            HStack {
                Spacer()
                Button(action: setTime) {
                    Label(isSetting ? "Applying" : "Apply Display Time", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSetting)
            }
        }
    }
}

private func preferredManualTimeZones() -> [TimeZone] {
    let current = systemCommandTimeZone()
    let identifiers = ([current.identifier, "UTC", "Europe/Berlin"] + TimeZone.knownTimeZoneIdentifiers).sorted {
        $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
    }
    var seen = Set<String>()
    return identifiers.compactMap { identifier in
        guard !identifier.isEmpty,
              seen.insert(identifier).inserted,
              let zone = TimeZone(identifier: identifier) else { return nil }
        return zone
    }
}

private func manualTimeZoneLabel(_ zone: TimeZone, date: Date) -> String {
    let seconds = zone.secondsFromGMT(for: date)
    let sign = seconds < 0 ? "-" : "+"
    let absolute = abs(seconds)
    let offset = "\(sign)\(String(format: "%02d:%02d", absolute / 3600, (absolute / 60) % 60))"
    return "\(zone.identifier) (\(offset))"
}

struct StartupNotice: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Color.green)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct StartupVolumeRow: View {
    let candidate: SourceCandidate
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 22)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(candidate.name)
                        .font(.headline)
                    Text(candidate.deviceIdentifier)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Spacer()
                    StartupBadge(text: candidate.roles.isEmpty ? "No role" : candidate.roles.joined(separator: ", "), color: candidate.roles.contains("Data") ? .orange : .blue)
                    StartupBadge(text: "Locked", color: .orange)
                }

                HStack(spacing: 12) {
                    Text(candidate.sizeBytes.map(ByteCount.string(from:)) ?? "Unknown size")
                    Text(candidate.mountPoint ?? "Not mounted")
                    Text(candidate.source)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct StartupUnlockPromptCard: View {
    let candidate: SourceCandidate?
    @Binding var adminPassword: String
    @Binding var recoveryKey: String
    @Binding var credentialKind: FileVaultCredentialKind
    let isUnlocking: Bool
    let isBusy: Bool
    let commandPreview: String
    let unlock: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.open.trianglebadge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(Color.orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Unlock Selected Data Volume")
                        .font(.title3.weight(.semibold))
                    Text("This only unlocks APFS. It does not mount the volume; mount read-only or read-write later from Volumes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Effective unlock target")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let candidate {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                        GridRow {
                            unlockFact("Device")
                            unlockValue(candidate.deviceIdentifier, monospace: true)
                        }
                        GridRow {
                            unlockFact("Volume")
                            unlockValue(candidate.name.isEmpty ? "APFS volume" : candidate.name)
                        }
                        GridRow {
                            unlockFact("Role")
                            unlockValue(candidate.roles.isEmpty ? "No APFS role reported" : candidate.roles.joined(separator: ", "))
                        }
                        GridRow {
                            unlockFact("After unlock")
                            unlockValue("Unlocked, still unmounted (-nomount)")
                        }
                    }
                    .textSelection(.enabled)
                } else {
                    Text("Select a locked APFS Data volume above.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Picker("", selection: $credentialKind) {
                ForEach(FileVaultCredentialKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                if credentialKind == .recoveryKey {
                    TextField(credentialKind.prompt, text: $recoveryKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(credentialKind.prompt, text: $adminPassword)
                        .textFieldStyle(.roundedBorder)
                }
                Button(action: unlock) {
                    Label(isUnlocking ? "Unlocking" : "Unlock", systemImage: "lock.open.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(candidate == nil || activeCredential.isEmpty || isBusy)
            }

            DisclosureGroup {
                Text(commandPreview)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            } label: {
                Label("Technical unlock command", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Color.orange.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func unlockFact(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 96, alignment: .leading)
    }

    private func unlockValue(_ text: String, monospace: Bool = false) -> some View {
        Text(text)
            .font(monospace ? .caption.monospaced() : .caption)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var activeCredential: String {
        switch credentialKind {
        case .adminPassword:
            return adminPassword
        case .recoveryKey:
            return recoveryKey
        }
    }
}

struct StartupBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.13))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
