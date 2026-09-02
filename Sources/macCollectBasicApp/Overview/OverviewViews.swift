import AppKit
import SwiftUI
import macCollectBasicCore

struct OverviewPanel: View {
    let profile: SystemProfile
    let refresh: () -> Void
    var isBasic = true

    @State private var fullDiskAccessStatus: FullDiskAccessStatus? = ForensicDataRoot.isRecoveryEnvironment ? nil : FullDiskAccessChecker.currentStatus()
    @State private var accessCheckedAt: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                OverviewHero(profile: profile) {
                    if ForensicDataRoot.isRecoveryEnvironment {
                        Button(action: openTerminal) {
                            Label("Terminal", systemImage: "terminal")
                        }
                    } else {
                        Button(action: AppSettings.openFullDiskAccess) {
                            Label("Full Disk Access", systemImage: "lock.shield")
                        }
                    }
                    Button(action: refresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }

                OverviewStatusStrip(profile: profile, fullDiskAccessStatus: fullDiskAccessStatus)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 10)], alignment: .leading, spacing: 10) {
                    OverviewSectionCard(title: "Device", systemImage: deviceIcon, tint: .blue) {
                        InfoLine("Device Name", profile.computerName)
                        InfoLine("Model", profile.modelName ?? profile.modelIdentifier ?? "Unknown")
                        InfoLine("Identifier", profile.modelIdentifier ?? "Unknown")
                        InfoLine("A-Number", profile.appleModelNumber ?? "Unknown")
                        InfoLine("Order No.", profile.modelNumber ?? "Unknown")
                        InfoLine("Serial", profile.serialNumber ?? "Unknown")
                    }

                    OverviewSectionCard(title: "Operating System", systemImage: "apple.logo", tint: .teal) {
                        InfoLine("macOS", profile.osVersion)
                        InfoLine("Kernel", profile.kernelVersion)
                        InfoLine("Architecture", profile.architecture)
                        InfoLine("Installed", profile.systemInstallDate.map(format) ?? "Unknown")
                        InfoLine("Last Boot", profile.lastBootTime.map(format) ?? "Unknown")
                    }

                    OverviewSectionCard(title: "Compute", systemImage: "cpu", tint: .orange) {
                        InfoLine("CPU / SoC", profile.processorName ?? "Unknown")
                        InfoLine("Cores", profile.cpuCoreSummary)
                        InfoLine("Memory", ByteCount.string(from: Int64(profile.physicalMemoryBytes)))
                        InfoLine("Host", profile.hostName)
                    }

                    if let fullDiskAccessStatus {
                        OverviewSectionCard(title: "Live Access", systemImage: "scope", tint: fullDiskAccessStatus.isGranted ? .green : .orange) {
                            InfoLine("Full Disk Access", fullDiskAccessStatus.state.label)
                            InfoLine("Bundle ID", fullDiskAccessStatus.bundleIdentifier)
                            InfoLine("TCC auth_value", fullDiskAccessStatus.authValue.map(String.init) ?? "None")
                            InfoLine("Checked", accessCheckedAt.map(format) ?? "On view load")
                            Text(fullDiskAccessStatus.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(18)
        }
        .onAppear(perform: checkFullDiskAccess)
    }

    private var deviceIcon: String {
        let name = (profile.modelName ?? profile.modelIdentifier ?? "").lowercased()
        if name.contains("book") { return "laptopcomputer" }
        if name.contains("mini") { return "macmini" }
        if name.contains("imac") { return "desktopcomputer" }
        return "macwindow"
    }

    private func checkFullDiskAccess() {
        guard !ForensicDataRoot.isRecoveryEnvironment else { return }
        fullDiskAccessStatus = FullDiskAccessChecker.currentStatus()
        accessCheckedAt = Date()
    }
}

struct OverviewHero<Actions: View>: View {
    let profile: SystemProfile
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.14))
                    AppLogoImage(fallbackSystemName: deviceIcon)
                }
                .frame(width: 62, height: 62)

                VStack(alignment: .leading, spacing: 6) {
                    Text(heroTitle)
                        .font(.largeTitle.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text(heroSubtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        OverviewBadge(text: profile.modelIdentifier ?? "Unknown identifier", color: .blue)
                        OverviewBadge(text: profile.appleModelNumber ?? "Unknown A-number", color: .purple)
                        OverviewBadge(text: profile.architecture, color: .teal)
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    actions()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                OverviewHeroFact(label: "Serial", value: profile.serialNumber ?? "Unknown")
                OverviewHeroFact(label: "macOS", value: profile.osVersion)
                OverviewHeroFact(label: "Collected", value: format(profile.collectedAt))
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var deviceIcon: String {
        let name = (profile.modelName ?? profile.modelIdentifier ?? "").lowercased()
        if name.contains("book") { return "laptopcomputer" }
        if name.contains("mini") { return "macmini" }
        if name.contains("imac") { return "desktopcomputer" }
        return "macwindow"
    }

    private var heroTitle: String {
        if ForensicDataRoot.isRecoveryEnvironment,
           !profile.computerName.isEmpty,
           profile.computerName != "Unknown" {
            return profile.computerName
        }
        if let modelName = profile.modelName, !modelName.isEmpty {
            return modelName
        }
        if !profile.computerName.isEmpty, profile.computerName != "Unknown" {
            return profile.computerName
        }
        return profile.modelIdentifier ?? "Unknown Mac"
    }

    private var heroSubtitle: String {
        if heroTitle == profile.computerName,
           let modelName = profile.modelName,
           !modelName.isEmpty,
           modelName != profile.computerName {
            return modelName
        }
        if heroTitle != profile.computerName,
           !profile.computerName.isEmpty,
           profile.computerName != "Unknown" {
            return profile.computerName
        }
        return profile.modelIdentifier ?? "Unknown identifier"
    }
}

struct OverviewHeroFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct OverviewStatusStrip: View {
    let profile: SystemProfile
    let fullDiskAccessStatus: FullDiskAccessStatus?

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 8)], alignment: .leading, spacing: 8) {
            OverviewStatusPill(title: "Boot Context", value: profile.bootContext, icon: "power.circle", color: profile.bootContext.localizedCaseInsensitiveContains("recovery") ? .orange : .green)
            OverviewStatusPill(title: "Root Volume", value: profile.rootVolumeReadOnly == true ? "Read-only" : "Needs review", icon: profile.rootVolumeReadOnly == true ? "lock.fill" : "exclamationmark.triangle.fill", color: profile.rootVolumeReadOnly == true ? .green : .orange)
            OverviewStatusPill(title: "Data Volume", value: profile.unlockState.state, icon: profile.unlockState.isAvailable ? "key.fill" : "key.slash.fill", color: profile.unlockState.isAvailable ? .green : .orange)
            OverviewStatusPill(title: "Volumes", value: "\(profile.volumes.count) detected", icon: "externaldrive.fill", color: .teal)
            if let fullDiskAccessStatus {
                OverviewStatusPill(title: "Full Disk Access", value: fullDiskAccessStatus.state.label, icon: fullDiskAccessStatus.isGranted ? "checkmark.shield.fill" : "lock.shield", color: fullDiskAccessStatus.isGranted ? .green : .orange)
            }
        }
    }
}

struct OverviewStatusPill: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct OverviewSectionCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 18)
                Text(title)
                    .font(.headline)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(tint)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AppLogoImage: View {
    let fallbackSystemName: String
    private static let logo = Bundle.main
        .url(forResource: "AppLogo", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        if let logo = Self.logo {
            Image(nsImage: logo)
                .resizable()
                .scaledToFit()
                .padding(8)
        } else {
            Image(systemName: fallbackSystemName)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
    }
}
