import AppKit
import SwiftUI
import macCollectBasicCore

private enum BasicAppSection: Hashable {
    case overview
    case acquisition
    case volumes
    case usbBuilder
}

struct BasicSystemOverviewView: View {
    @State private var profile: SystemProfile?
    @State private var selectedSection: BasicAppSection = .overview
    @State private var isRefreshingVolumes = false
    @State private var volumesPrepared = false
    @StateObject private var acquisitionSession = AcquisitionSessionState()
    @StateObject private var usbBuilderState = USBBuilderState()
    @State private var startupScanStarted = false
    @State private var startupCandidates: [SourceCandidate] = []
    @State private var selectedStartupDevice = ""
    @State private var startupAdminPassword = ""
    @State private var startupRecoveryKey = ""
    @State private var startupCredentialKind: FileVaultCredentialKind = .adminPassword
    @State private var isScanningStartupVolumes = false
    @State private var isUnlockingStartupVolume = false
    @State private var isCollectingProfile = false
    @State private var wifiDisableStarted = false
    @State private var showFullDiskAccessPrompt = false
    @State private var startupLogLines: [String] = [
        timestampedLogLine("Starting Recovery checks.")
    ]

    var body: some View {
        Group {
            if let profile {
                mainContent(profile: profile)
            } else if !ForensicDataRoot.isRecoveryEnvironment {
                StartupLivePanel(
                    isCollectingProfile: isCollectingProfile
                )
            } else {
                StartupFileVaultPanel(
                    candidates: startupCandidates,
                    selectedDevice: $selectedStartupDevice,
                    adminPassword: $startupAdminPassword,
                    recoveryKey: $startupRecoveryKey,
                    credentialKind: $startupCredentialKind,
                    isScanning: isScanningStartupVolumes,
                    isUnlocking: isUnlockingStartupVolume,
                    isCollectingProfile: isCollectingProfile,
                    logLines: startupLogLines,
                    isRecoveryEnvironment: ForensicDataRoot.isRecoveryEnvironment,
                    refresh: scanStartupVolumes,
                    unlock: unlockStartupVolume,
                    continueWithoutUnlock: collectProfileAfterStartup
                )
            }
        }
        .onAppear(perform: startStartupPreflightIfNeeded)
        .onAppear(perform: showFullDiskAccessPromptIfNeeded)
        .alert("Enable Full Disk Access", isPresented: $showFullDiskAccessPrompt) {
            Button("Open Settings") {
                AppSettings.openFullDiskAccess()
            }
            if !RuntimePrivilege.isRunningAsRoot {
                Button("Restart as root") {
                    AppSettings.restartAsRoot()
                }
            }
            Button("Later", role: .cancel) {}
        } message: {
            Text("Please enable Full Disk Access for macCollect before live acquisition, so protected macOS artifacts can be collected.")
        }
    }

    @ViewBuilder
    private func mainContent(profile: SystemProfile) -> some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                Section("System") {
                    NavigationLink(value: BasicAppSection.overview) {
                        Label("Overview", systemImage: "desktopcomputer")
                    }
                }

                Section("Acquire") {
                    NavigationLink(value: BasicAppSection.volumes) {
                        Label("Volumes", systemImage: "externaldrive")
                    }
                    NavigationLink(value: BasicAppSection.acquisition) {
                        Label("Acquisition", systemImage: "shippingbox")
                    }
                }
                if !isRecoveryEnvironment(profile) {
                    Section("Prepare") {
                        NavigationLink(value: BasicAppSection.usbBuilder) {
                            Label("USB Builder", systemImage: "externaldrive.badge.plus")
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 180, max: 220)
        } detail: {
            VStack(spacing: 0) {
                if !RuntimePrivilege.isRunningAsRoot {
                    RootPrivilegeBanner()
                        .padding([.horizontal, .top], 12)
                }
                ZStack {
                    switch selectedSection {
                    case .overview:
                        OverviewPanel(profile: profile, refresh: refreshProfile, isBasic: true)
                    case .acquisition:
                        AcquisitionPanel(profile: profile, model: acquisitionSession)
                    case .volumes:
                        ZStack(alignment: .topLeading) {
                            VolumesPanel(
                                volumes: profile.volumes,
                                unlockState: profile.unlockState,
                                isRefreshing: isRefreshingVolumes,
                                guardLogLines: startupLogLines,
                                refresh: refreshVolumes
                            )
                            if isRefreshingVolumes && !volumesPrepared {
                                InlineLoadingRow(text: "Preparing volumes...")
                                    .padding(12)
                            }
                        }
                        .onAppear {
                            guard !volumesPrepared else { return }
                            refreshVolumes()
                        }
                    case .usbBuilder:
                        USBBuilderPanel(state: usbBuilderState)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func refreshProfile() {
        profile = SystemProfiler.collectBasic()
    }

    private func refreshVolumes() {
        guard !isRefreshingVolumes else { return }
        isRefreshingVolumes = true
        DispatchQueue.global(qos: .userInitiated).async {
            let volumes = SystemProfiler.collectVolumes()
            let unlockState = SystemProfiler.collectUnlockState()
            DispatchQueue.main.async {
                if let currentProfile = profile {
                    profile = currentProfile.replacing(volumes: volumes, unlockState: unlockState)
                }
                volumesPrepared = true
                isRefreshingVolumes = false
            }
        }
    }

    private func startStartupPreflightIfNeeded() {
        guard !startupScanStarted else { return }
        startupScanStarted = true
        if ForensicDataRoot.isRecoveryEnvironment {
            MacCollectGuard.shared.startIfNeeded { line in
                DispatchQueue.main.async {
                    appendStartupLog(line)
                }
            }
            disableWiFiByDefault()
            scanStartupVolumes()
        } else {
            startupLogLines = [
                timestampedLogLine("[live] Live macOS detected."),
                timestampedLogLine("[profile] Preparing acquisition profile.")
            ]
            collectProfileAfterStartup()
        }
    }

    private func showFullDiskAccessPromptIfNeeded() {
        guard !ForensicDataRoot.isRecoveryEnvironment else { return }
        let status = FullDiskAccessChecker.currentStatus()
        guard !status.isGranted else { return }
        showFullDiskAccessPrompt = true
    }

    private func appendStartupLog(_ text: String) {
        startupLogLines.append(timestampedLogLine(text))
    }

    private func disableWiFiByDefault() {
        guard !wifiDisableStarted else { return }
        wifiDisableStarted = true
        appendStartupLog("[network] Disabling Wi-Fi by default.")
        DispatchQueue.global(qos: .utility).async {
            let message = WirelessManager.disableWiFi()
            DispatchQueue.main.async {
                appendStartupLog("[network] \(message)")
            }
        }
    }

    private func scanStartupVolumes() {
        guard !isScanningStartupVolumes, !isUnlockingStartupVolume, !isCollectingProfile else { return }
        isScanningStartupVolumes = true
        appendStartupLog("[filevault] Scanning APFS volumes.")

        DispatchQueue.global(qos: .userInitiated).async {
            let candidates = RecoverySourceScanner.scan()
            MacCollectGuard.shared.updateProtectedDevices(from: candidates)
            DispatchQueue.main.async {
                startupCandidates = candidates
                let locked = lockedEncryptedCandidates(from: candidates)
                if selectedStartupDevice.isEmpty || !locked.contains(where: { $0.deviceIdentifier == selectedStartupDevice }) {
                    selectedStartupDevice = locked.first?.deviceIdentifier ?? ""
                }
                isScanningStartupVolumes = false

                if locked.isEmpty {
                    appendStartupLog("[filevault] No locked Data volume requires startup action. Continue when ready.")
                } else {
                    appendStartupLog("[filevault] Select and unlock a locked Data volume, or continue and manage it later in Volumes.")
                }
            }
        }
    }

    private func unlockStartupVolume() {
        let selectedCredential = startupCredentialKind == .recoveryKey ? startupRecoveryKey : startupAdminPassword
        guard !selectedStartupDevice.isEmpty, !selectedCredential.isEmpty else { return }
        let device = selectedStartupDevice
        let credential = selectedCredential
        let credentialKind = startupCredentialKind
        if credentialKind == .recoveryKey {
            startupRecoveryKey = ""
        } else {
            startupAdminPassword = ""
        }
        isUnlockingStartupVolume = true
        appendStartupLog("[unlock] Trying \(device) without mounting.")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var recoveryUser: APFSCryptoUser?
                if credentialKind == .recoveryKey {
                    let users = RecoverySourceScanner.cryptoUsers(deviceIdentifier: device)
                    recoveryUser = users.first(where: \.isRecoveryUser)
                }

                let result = try RecoverySourceScanner.unlockVolume(
                    deviceIdentifier: device,
                    passphrase: credential,
                    userUUID: recoveryUser?.uuid
                )
                let output = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)

                DispatchQueue.main.async {
                    isUnlockingStartupVolume = false
                    if result.exitCode == 0 {
                        appendStartupLog("[unlock] \(device) unlocked and left unmounted.")
                        rescanAfterUnlock()
                    } else {
                        appendStartupLog("[unlock] diskutil exited \(result.exitCode): \(output)")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isUnlockingStartupVolume = false
                    appendStartupLog("[unlock] \(error.localizedDescription)")
                }
            }
        }
    }

    private func rescanAfterUnlock() {
        isScanningStartupVolumes = true
        DispatchQueue.global(qos: .userInitiated).async {
            let candidates = RecoverySourceScanner.scan()
            MacCollectGuard.shared.updateProtectedDevices(from: candidates)
            DispatchQueue.main.async {
                startupCandidates = candidates
                let locked = lockedEncryptedCandidates(from: candidates)
                selectedStartupDevice = locked.first?.deviceIdentifier ?? ""
                isScanningStartupVolumes = false
                if locked.isEmpty {
                    appendStartupLog("[filevault] Data volume is unlocked. Continuing to overview.")
                    collectProfileAfterStartup()
                } else {
                    appendStartupLog("[filevault] \(locked.count) locked volume(s) remain.")
                }
            }
        }
    }

    private func collectProfileAfterStartup() {
        guard !isCollectingProfile, profile == nil else { return }
        isCollectingProfile = true
        appendStartupLog("[profile] Collecting acquisition profile.")
        DispatchQueue.global(qos: .userInitiated).async {
            ForensicDataRoot.resetCache()
            let collected = SystemProfiler.collectBasic()
            DispatchQueue.main.async {
                profile = collected
                if ForensicDataRoot.isRecoveryEnvironment {
                    acquisitionSession.enforceReadOnly = true
                }
                isCollectingProfile = false
            }
        }
    }

    private func lockedEncryptedCandidates(from candidates: [SourceCandidate]) -> [SourceCandidate] {
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

    private func isRecoveryEnvironment(_ profile: SystemProfile) -> Bool {
        profile.bootContext.localizedCaseInsensitiveContains("recovery") ||
            profile.bootContext.localizedCaseInsensitiveContains("installer")
    }

}

