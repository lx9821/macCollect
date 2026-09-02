import AppKit
import SwiftUI
import UniformTypeIdentifiers
import macCollectBasicCore

enum AppSettings {
    static func openFullDiskAccess() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    static func restartAsRoot() {
        guard let executablePath = Bundle.main.executablePath else { return }
        let command = shellQuoted(executablePath) + " >/dev/null 2>&1 &"
        let script = "do shell script \(appleScriptQuoted(command)) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do {
            try process.run()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                NSApp.terminate(nil)
            }
        } catch {
            NSSound.beep()
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}

struct AppTextScaleKey: EnvironmentKey {
    static let defaultValue = 1.0
}

extension EnvironmentValues {
    var appTextScale: Double {
        get { self[AppTextScaleKey.self] }
        set { self[AppTextScaleKey.self] = newValue }
    }
}

struct ScaledMonospacedFont: ViewModifier {
    @Environment(\.appTextScale) private var textScale
    let size: CGFloat
    let weight: Font.Weight?

    func body(content: Content) -> some View {
        content.font(.system(size: scaledFontSize(size, scale: textScale), weight: weight, design: .monospaced))
    }
}

extension View {
    func scaledMonospaced(_ size: CGFloat, weight: Font.Weight? = nil) -> some View {
        modifier(ScaledMonospacedFont(size: size, weight: weight))
    }
}

func scaledFontSize(_ size: CGFloat, scale: Double) -> CGFloat {
    max(9, min(size * CGFloat(scale), size * 1.6))
}

func openTerminal() {
    let candidates = [
        "/System/Applications/Utilities/Terminal.app",
        "/Applications/Utilities/Terminal.app"
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        return
    }
    _ = try? CommandRunner.run("/usr/bin/open", arguments: ["-a", "Terminal"], timeoutSeconds: 5)
}

func currentSystemDateText() -> String {
    formattedSystemDate(Date(), timeZone: systemCommandTimeZone())
}

func currentTimeZoneText(timeZone: TimeZone) -> String {
    currentTimeZoneText(timeZone: timeZone, date: Date())
}

func currentTimeZoneText(timeZone: TimeZone, date: Date) -> String {
    let identifier = timeZone.identifier.hasPrefix("GMT") ? (timeZone.abbreviation() ?? timeZone.identifier) : timeZone.identifier
    return "Timezone: \(identifier) (\(timeZoneOffsetText(timeZone, date: date)))"
}

func formattedSystemDate(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
    return "\(formatter.string(from: date)) (\(timeZoneOffsetText(timeZone, date: date)))"
}

func formattedAcquisitionTime(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return "\(formatter.string(from: date)) \(timeZoneOffsetText(timeZone, date: date))"
}

func timeZoneOffsetText(_ timeZone: TimeZone, date: Date = Date()) -> String {
    let seconds = timeZone.secondsFromGMT(for: date)
    let sign = seconds >= 0 ? "+" : "-"
    let absolute = abs(seconds)
    let hours = absolute / 3600
    let minutes = (absolute / 60) % 60
    if minutes == 0 {
        return "UTC\(sign)\(hours)"
    }
    return "UTC\(sign)\(hours):\(String(format: "%02d", minutes))"
}

func systemCommandTimeZone() -> TimeZone {
    if let cached = SystemTimeZoneCache.timeZone {
        return cached
    }
    if let result = try? CommandRunner.run(
        "/bin/date",
        arguments: ["+%z"],
        timeoutSeconds: 1
    ) {
        let text = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let zone = timeZoneFromOffset(text) {
            SystemTimeZoneCache.timeZone = zone
            return zone
        }
    }
    SystemTimeZoneCache.timeZone = TimeZone.current
    return TimeZone.current
}

@discardableResult
func setSystemDisplayTimeZone(_ timeZone: TimeZone) {
    SystemTimeZoneCache.timeZone = timeZone
}

func setAcquisitionDisplayTimeOverride(actualDate: Date, displayDate: Date, timeZone: TimeZone) {
    AcquisitionTimeContextCache.actualDate = actualDate
    AcquisitionTimeContextCache.displayDate = displayDate
    AcquisitionTimeContextCache.timeZone = timeZone
    AcquisitionTimeContextCache.wasAdjustedInApp = true
}

func currentAcquisitionTimeContext() -> AcquisitionTimeContext {
    let actual = Date()
    let zone = AcquisitionTimeContextCache.timeZone ?? systemCommandTimeZone()
    let displayDate: Date
    if let cachedActual = AcquisitionTimeContextCache.actualDate,
       let cachedDisplay = AcquisitionTimeContextCache.displayDate {
        displayDate = actual.addingTimeInterval(cachedDisplay.timeIntervalSince(cachedActual))
    } else {
        displayDate = actual
    }
    return AcquisitionTimeContext(
        actualSystemTime: formattedAcquisitionTime(actual, timeZone: TimeZone(secondsFromGMT: 0)!),
        effectiveDisplayTime: formattedAcquisitionTime(displayDate, timeZone: zone),
        effectiveTimeZone: "\(zone.identifier) (\(timeZoneOffsetText(zone, date: displayDate)))",
        actualReferenceDate: actual,
        displayReferenceDate: displayDate,
        effectiveSecondsFromGMT: zone.secondsFromGMT(for: displayDate)
    )
}

private enum SystemTimeZoneCache {
    static var timeZone: TimeZone?
}

private enum AcquisitionTimeContextCache {
    static var actualDate: Date?
    static var displayDate: Date?
    static var timeZone: TimeZone?
    static var wasAdjustedInApp = false
}

private func timeZoneFromOffset(_ value: String) -> TimeZone? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count == 5,
          let sign = trimmed.first,
          sign == "+" || sign == "-",
          let hours = Int(trimmed.dropFirst().prefix(2)),
          let minutes = Int(trimmed.suffix(2)) else { return nil }
    let multiplier = sign == "-" ? -1 : 1
    return TimeZone(secondsFromGMT: multiplier * ((hours * 3600) + (minutes * 60)))
}

struct OverviewBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct Header<Actions: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let actions: () -> Actions

    init(title: String, subtitle: String, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.largeTitle.weight(.semibold))
                if !subtitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(subtitle)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 8) { actions() }
                .buttonStyle(.bordered)
        }
    }
}

struct InfoCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct RootPrivilegeBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: RuntimePrivilege.isRunningAsRoot ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(RuntimePrivilege.isRunningAsRoot ? Color.green : Color.orange)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(RuntimePrivilege.isRunningAsRoot ? "Root privileges active" : "Root privileges not active")
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if !RuntimePrivilege.isRunningAsRoot {
                Button {
                    AppSettings.restartAsRoot()
                } label: {
                    Label("Restart as root", systemImage: "arrow.triangle.2.circlepath.shield")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background((RuntimePrivilege.isRunningAsRoot ? Color.green : Color.orange).opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke((RuntimePrivilege.isRunningAsRoot ? Color.green : Color.orange).opacity(0.25), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var detail: String {
        if RuntimePrivilege.isRunningAsRoot {
            return "macCollect is running as \(RuntimePrivilege.statusText). Raw APFS device access can use privileged system APIs."
        }
        return "Current identity: \(RuntimePrivilege.statusText). Volume copy with rsync or ditto can still run on mounted sources; live protected paths need Full Disk Access and raw device reads need root."
    }
}

struct InlineLoadingRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct InfoLine: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

struct InputRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content

    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.content = content
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            content()
        }
    }
}

struct LogPanel: View {
    let lines: [String]
    var height: CGFloat = 280

    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(logEntries.enumerated()), id: \.offset) { index, entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.level.label)
                                    .font(.caption2.monospaced().weight(.bold))
                                    .foregroundStyle(entry.level.color)
                                    .frame(width: 52, alignment: .leading)
                                Text(entry.text)
                                    .scaledMonospaced(12)
                                    .foregroundStyle(entry.level.color)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .id(index)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                        Color.clear.frame(width: 24, height: 24).id("bottom")
                    }
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: geometry.size.width + 24, minHeight: geometry.size.height + 24, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottomLeading)
                }
                .onChange(of: lines.count) { _ in
                    proxy.scrollTo("bottom", anchor: .bottomLeading)
                }
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
        .border(Color.secondary.opacity(0.25))
    }

    private var logEntries: [LogEntry] {
        lines.flatMap { line in
            let pieces = line.components(separatedBy: .newlines)
            return pieces.isEmpty ? [LogEntry(text: line)] : pieces.filter { !$0.isEmpty }.map(LogEntry.init)
        }
    }
}

func format(_ date: Date) -> String {
    let timeZone = systemCommandTimeZone()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
    return "\(formatter.string(from: date)) (\(timeZoneOffsetText(timeZone, date: date)))"
}

func logTimestamp(_ date: Date = Date()) -> String {
    let timeZone = systemCommandTimeZone()
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm:ss"
    return "\(formatter.string(from: date)) \(timeZoneOffsetText(timeZone, date: date))"
}

func timestampedLogLine(_ text: String, date: Date = Date()) -> String {
    if text.range(of: #"^\[[0-9]{2}:[0-9]{2}:[0-9]{2}(?: UTC[+-][0-9]{1,2}(?::[0-9]{2})?)?\]"#, options: .regularExpression) != nil {
        return text
    }
    return "[\(logTimestamp(date))] \(text)"
}

func defaultEvidenceSubjectName(serial: String? = nil, prefix: String = "Evidence") -> String {
    let identifier = sanitizedEvidenceComponent(serial ?? localSerialNumber() ?? Host.current().localizedName ?? "Mac")
    return "\(prefix)-\(identifier)"
}

private func localSerialNumber() -> String? {
    guard let result = try? CommandRunner.run(
        "/usr/sbin/ioreg",
        arguments: ["-rd1", "-c", "IOPlatformExpertDevice"],
        timeoutSeconds: 2
    ) else { return nil }
    let pattern = #""IOPlatformSerialNumber"\s*=\s*"([^"]+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: result.stdout, range: NSRange(result.stdout.startIndex..<result.stdout.endIndex, in: result.stdout)),
          let range = Range(match.range(at: 1), in: result.stdout) else { return nil }
    return String(result.stdout[range])
}

private func sanitizedEvidenceComponent(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics
    let cleaned = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
    let collapsed = String(cleaned).split(separator: "-").joined(separator: "-")
    return collapsed.isEmpty ? "Mac" : String(collapsed.prefix(32))
}

private struct LogEntry {
    let text: String
    let level: LogLevel

    init(text: String) {
        self.text = text
        self.level = LogLevel.detect(in: text)
    }
}

private enum LogLevel {
    case error
    case warning
    case success
    case progress
    case command
    case info

    var label: String {
        switch self {
        case .error: return "ERROR"
        case .warning: return "WARN"
        case .success: return "OK"
        case .progress: return "PROG"
        case .command: return "CMD"
        case .info: return "INFO"
        }
    }

    var color: Color {
        switch self {
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        case .progress: return .blue
        case .command: return .purple
        case .info: return .primary
        }
    }

    static func detect(in text: String) -> LogLevel {
        let lower = text.lowercased()
        if lower.contains("[error]") || lower.contains(" exited with ") || lower.contains(" failed") {
            return .error
        }
        if lower.contains("[warning]") || lower.contains("[warn]") || lower.contains(" warning") {
            return .warning
        }
        if lower.contains("[done]") || lower.contains(" completed") || lower.contains(" succeeded") || lower.contains(" ready") {
            return .success
        }
        if lower.contains("[progress]") || lower.contains("copying source data") || lower.contains("replicating") {
            return .progress
        }
        let cleaned = text.replacingOccurrences(of: #"^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\]\s*"#, with: "", options: .regularExpression)
        if cleaned.hasPrefix("$ ") {
            return .command
        }
        return .info
    }
}

func boolText(_ value: Bool?) -> String {
    value.map { $0 ? "Yes" : "No" } ?? "Unknown"
}
