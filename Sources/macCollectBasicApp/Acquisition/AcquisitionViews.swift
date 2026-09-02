import AppKit
import SwiftUI
import UniformTypeIdentifiers
import macCollectBasicCore

final class AcquisitionSessionState: ObservableObject {
    @Published var caseName = ""
    @Published var examiner = ""
    @Published var imageName = "macCollect-logical"
    @Published var selectedSource = ""
    @Published var destinationPath = ""
    @Published var selectedSourceDevice = ""
    @Published var sourceCandidates: [SourceCandidate] = []
    @Published var preflightChecks: [PreflightCheck] = []
    @Published var rsyncAvailable = ForensicToolLocator.resolve("rsync") != nil
    @Published var cancellationToken: CancellationToken?
    @Published var method: AcquisitionMethod = .rsync
    @Published var outputFormat: AcquisitionOutputFormat = .compressedDMG
    @Published var enforceReadOnly = true
    @Published var notes = ""
    @Published var showSourceTable = false
    @Published var showCommandDetails = false
    @Published var showPreflightDetails = false
    @Published var isPreparingSources = false
    @Published var ignoreDestinationSizeCheck = false
    @Published var createFailedFilePlaceholders = false
    @Published var shutdownAfterSuccess = false
    @Published var acquisitionLogView: AcquisitionLogView = .summary
    @Published var acquisitionProgress = 0.0
    @Published var acquisitionStage = "Ready"
    @Published var acquisitionSubstatus = ""
    @Published var copySpeedText = ""
    @Published var estimatedFinishText = ""
    @Published var acquisitionFailure: String?
    @Published var acquisitionStartedAt: Date?
    @Published var elapsedNow = Date()
    @Published var acquisitionSteps = AcquisitionProgressStep.defaultSteps()
    @Published var isRunning = false
    @Published var isUnlocking = false
    @Published var acquisitionReportURLs: [URL] = []
    @Published var acquisitionReportPreviewText = ""
    @Published var showAcquisitionReportPreview = false
    @Published var statusLines: [String] = [
        "Ready. Logical acquisition is functional. Choose an external destination before starting."
    ]

    init() {
        sourceCandidates = RecoverySourceScanner.scan()
        if !rsyncAvailable {
            method = .ditto
        }
        if let candidate = sourceCandidates.first(where: { $0.isRecommendedDataSource }) ??
            sourceCandidates.first(where: { $0.isAcquisitionSelectable }) {
            selectedSourceDevice = candidate.deviceIdentifier
            selectedSource = candidate.acquisitionPath ?? ""
        }
    }

}

struct AcquisitionPanel: View {
    let profile: SystemProfile
    @ObservedObject var model: AcquisitionSessionState
    private let acquisitionTicker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Header(title: "Acquisition", subtitle: "") {
                    if isRecoveryAcquisitionContext {
                        Button(action: openTerminal) {
                            Label("Terminal", systemImage: "terminal")
                        }
                    }
                    Button(action: { refreshSources() }) {
                        Label("Refresh Sources", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRunning || model.isUnlocking)
                }

                if shouldShowAcquisitionStatus {
                    AcquisitionStatusBanner(
                        stage: model.acquisitionStage,
                        substatus: model.acquisitionSubstatus,
                        progress: model.acquisitionProgress,
                        elapsed: elapsedText,
                        speed: model.copySpeedText,
                        eta: model.estimatedFinishText,
                        failure: model.acquisitionFailure,
                        isRunning: model.isRunning
                    )
                    if canPreviewAcquisitionReport {
                        HStack {
                            Spacer()
                            Button {
                                model.showAcquisitionReportPreview = true
                            } label: {
                                Label("View Log", systemImage: "doc.text.magnifyingglass")
                            }
                        }
                    }
                }

                if model.isPreparingSources {
                    InlineLoadingRow(text: "Preparing acquisition sources...")
                }

                AcquisitionAdvancedCasePanel(
                    caseName: $model.caseName,
                    examiner: $model.examiner,
                    imageName: $model.imageName,
                    destinationPath: model.destinationPath,
                    method: model.method,
                    outputFormat: model.outputFormat,
                    notes: $model.notes,
                    isRunning: model.isRunning
                )
                .disabled(model.isRunning || model.isUnlocking)

                AcquisitionAdvancedSourceDestinationPanel(
                    candidates: model.sourceCandidates,
                    selectedSource: $model.selectedSource,
                    selectedDevice: $model.selectedSourceDevice,
                    sourceDisplayText: sourceDisplayText,
                    destinationPath: $model.destinationPath,
                    chooseSource: chooseSource,
                    chooseDestination: chooseDestination
                )
                .disabled(model.isRunning || model.isUnlocking)

                AcquisitionAdvancedMethodPanel(
                    method: $model.method,
                    outputFormat: $model.outputFormat,
                    availableMethods: availableMethods,
                    availableOutputFormats: availableOutputFormats
                )
                .disabled(model.isRunning || model.isUnlocking)

                AcquisitionAdditionalSettingsPanel(
                    enforceReadOnly: $model.enforceReadOnly,
                    ignoreDestinationSizeCheck: $model.ignoreDestinationSizeCheck,
                    createFailedFilePlaceholders: $model.createFailedFilePlaceholders,
                    shutdownAfterSuccess: $model.shutdownAfterSuccess,
                    isRecovery: isRecoveryAcquisitionContext
                )
                .disabled(model.isRunning || model.isUnlocking)

                if isRecoveryAcquisitionContext {
                    ReadOnlyWarning(
                        sourcePath: resolvedSourcePath,
                        readOnly: selectedSourceCandidate?.readOnly,
                        sourceDevice: selectedSourceCandidate?.deviceIdentifier,
                        enforceReadOnly: model.enforceReadOnly
                    )
                }

                AcquisitionAdvancedPreflightPanel(
                    isRunning: model.isRunning,
                    isUnlocking: model.isUnlocking,
                    checks: model.preflightChecks,
                    showPreflightDetails: $model.showPreflightDetails,
                    showCommandDetails: $model.showCommandDetails,
                    source: resolvedSourcePath,
                    sourceDevice: selectedSourceCandidate?.deviceIdentifier,
                    destination: model.destinationPath,
                    imageName: model.imageName,
                    method: model.method,
                    outputFormat: model.outputFormat,
                    hashMethods: AcquisitionHashMethod.allCases,
                    runPreflight: runPreflight,
                    start: startAcquisition,
                    cancel: cancelAcquisition
                )

                if shouldShowAcquisitionStatus {
                    HStack {
                        Picker("", selection: $model.acquisitionLogView) {
                            ForEach(AcquisitionLogView.allCases) { view in
                                Text(view.label).tag(view)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 340, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    switch model.acquisitionLogView {
                    case .summary:
                        AcquisitionProgressPanel(
                            progress: model.acquisitionProgress,
                            stage: model.acquisitionStage,
                            elapsed: elapsedText,
                            steps: model.acquisitionSteps
                        )
                    case .toolOutput:
                        LogPanel(lines: visibleToolOutputLines, height: 300)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    case .raw:
                        LogPanel(lines: visibleRawLogLines, height: 300)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            applyDefaultEvidenceNameIfNeeded()
            prepareSourcesOnAppear()
            selectPreparedDestinationIfNeeded()
        }
        .onReceive(acquisitionTicker) { now in
            if model.isRunning {
                model.elapsedNow = now
            }
        }
        .onChange(of: model.selectedSource) { _ in
            normalizeAcquisitionMethod()
        }
        .onChange(of: model.selectedSourceDevice) { _ in
            normalizeAcquisitionMethod()
        }
        .onChange(of: model.method) { _ in
            normalizeOutputFormat()
        }
        .sheet(isPresented: $model.showAcquisitionReportPreview) {
            AcquisitionReportPreview(text: model.acquisitionReportPreviewText)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            model.destinationPath = panel.url?.path ?? model.destinationPath
        }
    }

    private func chooseSource() {
        model.sourceCandidates = RecoverySourceScanner.scan()
        selectRecommendedSourceIfNeeded(force: selectedSourceCandidate?.isAcquisitionSelectable != true || resolvedSourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        model.showSourceTable = true
        model.statusLines.append("[sources] Choose Source opened the APFS volume list; Finder source picking is disabled for acquisition sources.")
    }

    private func startAcquisition() {
        refreshSourcesForPreflight()
        let plan = currentPlan()
        let startedAt = Date()
        model.acquisitionFailure = nil
        model.preflightChecks = []
        model.acquisitionReportURLs = []
        model.statusLines = []
        model.acquisitionStartedAt = startedAt
        model.elapsedNow = startedAt
        model.acquisitionLogView = .summary
        model.acquisitionProgress = 0.02
        model.acquisitionStage = "Running preflight"
        model.acquisitionSubstatus = "Checking source, destination and acquisition tools"
        model.copySpeedText = ""
        model.estimatedFinishText = ""
        model.acquisitionSteps = AcquisitionProgressStep.defaultSteps(for: plan)
        setAcquisitionStep(.preflight, .running, detail: "Checking source, destination and tool availability")
        appendAcquisitionLog("[start] \(acquisitionFullTimestamp(startedAt))")

        let checks = AcquisitionPreflight.run(plan: plan)
        model.preflightChecks = checks
        let passes = checks.filter { $0.severity == .pass }.count
        let warnings = checks.filter { $0.severity == .warning }.count
        let failures = checks.filter { $0.severity == .fail }.count
        appendAcquisitionLog("[preflight] \(passes) passed, \(warnings) warnings, \(failures) failures.")
        guard !AcquisitionPreflight.hasFailures(checks) else {
            appendAcquisitionLog("[preflight] Start blocked: fix failed checks first.")
            model.acquisitionStage = "Preflight blocked acquisition"
            model.acquisitionSubstatus = "Open preflight details before starting"
            model.acquisitionFailure = "\(failures) preflight failure(s). Open Preflight details before starting."
            model.acquisitionProgress = 0
            model.showPreflightDetails = true
            setAcquisitionStep(.preflight, .failed, detail: "\(failures) failures, \(warnings) warnings")
            return
        }
        model.showPreflightDetails = false

        model.acquisitionReportURLs = createAcquisitionReportFiles(for: plan, startedAt: startedAt)
        writeAcquisitionReport(status: "Running", plan: plan, startedAt: startedAt, endedAt: nil, detail: "Preflight passed. Acquisition starting.", finalImagePath: nil, hashText: "Not computed")
        if model.acquisitionReportURLs.isEmpty {
            appendAcquisitionLog("[log] Acquisition report could not be opened yet.")
        } else {
            model.acquisitionReportURLs.forEach { appendAcquisitionLog("[log] Acquisition report: \($0.path)") }
        }

        model.isRunning = true
        let token = CancellationToken()
        model.cancellationToken = token
        model.acquisitionProgress = 0.05
        model.acquisitionStage = "Preflight passed"
        model.acquisitionSubstatus = "Starting acquisition runner"
        setAcquisitionStep(.preflight, .done, detail: "\(passes) passed, \(warnings) warnings")

        DispatchQueue.global(qos: .utility).async {
            let runner = AcquisitionRunner(plan: plan, cancellationToken: token) { line in
                DispatchQueue.main.async {
                    appendAcquisitionLog(line)
                }
            }

            do {
                let result = try runner.run()
                DispatchQueue.main.async {
                    appendAcquisitionLog("[done] Acquisition completed.")
                    model.acquisitionFailure = nil
                    model.acquisitionSubstatus = "Finished"
                    model.acquisitionProgress = 1.0
                    model.estimatedFinishText = ""
                    completeAllAcquisitionSteps()
                    writeAcquisitionReport(
                        status: "Completed",
                        plan: plan,
                        startedAt: startedAt,
                        endedAt: result.endedAt,
                        detail: "Acquisition completed.",
                        finalImagePath: result.finalImagePath,
                        hashText: result.hashText,
                        timeline: result.timeline
                    )
                    model.isRunning = false
                    model.cancellationToken = nil
                    if model.shutdownAfterSuccess {
                        requestShutdownAfterSuccessfulAcquisition()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    appendAcquisitionLog("[error] \(error.localizedDescription)")
                    model.acquisitionFailure = error.localizedDescription
                    model.acquisitionSubstatus = "Stopped before completion"
                    model.acquisitionProgress = min(model.acquisitionProgress, 0.99)
                    failRunningAcquisitionStep(error.localizedDescription)
                    writeAcquisitionReport(status: "Failed", plan: plan, startedAt: startedAt, endedAt: Date(), detail: error.localizedDescription, finalImagePath: nil, hashText: "Not computed or incomplete.")
                    model.isRunning = false
                    model.cancellationToken = nil
                }
            }
        }
    }

    private func currentPlan() -> AcquisitionPlan {
        let selectedCandidate = selectedSourceCandidate
        let checkReadOnly = isRecoveryAcquisitionContext && model.enforceReadOnly
        let sourceRoles = selectedCandidate?.roles ?? []
        let sourceReadOnlyHint = isRecoveryAcquisitionContext ? selectedCandidate?.readOnly : nil
        return AcquisitionPlan(
            caseName: model.caseName,
            examiner: model.examiner,
            imageName: model.imageName,
            sourcePath: resolvedSourcePath,
            sourceDeviceIdentifier: selectedCandidate?.deviceIdentifier,
            sourceVolumeUUID: selectedCandidate?.volumeUUID,
            sourceReadOnlyHint: sourceReadOnlyHint,
            sourceRoles: sourceRoles,
            destinationPath: model.destinationPath,
            method: model.method,
            outputFormat: model.outputFormat,
            requireReadOnly: checkReadOnly,
            readOnlyCheckNotApplicable: !isRecoveryAcquisitionContext || !model.enforceReadOnly,
            skipDestinationSizeCheck: model.ignoreDestinationSizeCheck,
            createFailedFilePlaceholders: model.createFailedFilePlaceholders,
            hashMethods: AcquisitionHashMethod.allCases,
            notes: model.notes,
            systemProfile: profile,
            timeContext: currentAcquisitionTimeContext()
        )
    }

    private func applyDefaultEvidenceNameIfNeeded() {
        let image = model.imageName.trimmingCharacters(in: .whitespacesAndNewlines)
        if image.isEmpty || image == "macCollect-logical" {
            model.imageName = defaultEvidenceSubjectName(serial: profile.serialNumber, prefix: "macCollect")
        }
        if model.caseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.caseName = defaultEvidenceSubjectName(serial: profile.serialNumber, prefix: "Case")
        }
    }

    private func requestShutdownAfterSuccessfulAcquisition() {
        appendAcquisitionLog("[shutdown] Automatic shutdown requested after successful acquisition.")
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            let result = ShutdownManager.shutdownNow()
            let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if result.exitCode == 0 {
                    appendAcquisitionLog("[shutdown] Shutdown command accepted.")
                } else {
                    appendAcquisitionLog("[warning] Shutdown command failed: \(output.isEmpty ? "unknown error" : output)")
                }
            }
        }
    }

    private func runPreflight() {
        refreshSourcesForPreflight()
        model.acquisitionFailure = nil
        let checks = AcquisitionPreflight.run(plan: currentPlan())
        model.preflightChecks = checks
        model.showPreflightDetails = true
        let failures = checks.filter { $0.severity == .fail }.count
        let warnings = checks.filter { $0.severity == .warning }.count
        model.statusLines.append("[preflight] \(failures) failures, \(warnings) warnings.")
        if failures > 0 {
            model.acquisitionStage = "Preflight needs attention"
            model.acquisitionFailure = "\(failures) preflight failure(s)."
            model.acquisitionProgress = 0
            setAcquisitionStep(.preflight, .failed, detail: "\(failures) failures, \(warnings) warnings")
        } else {
            model.acquisitionStage = warnings > 0 ? "Preflight passed with warnings" : "Preflight passed"
            setAcquisitionStep(.preflight, .done, detail: "\(warnings) warnings")
        }
    }

    private func refreshSources(silent: Bool = false) {
        model.rsyncAvailable = ForensicToolLocator.resolve("rsync") != nil
        model.sourceCandidates = RecoverySourceScanner.scan()
        selectRecommendedSourceIfNeeded(force: selectedSourceCandidate?.isAcquisitionSelectable != true || !FileManager.default.fileExists(atPath: resolvedSourcePath))
        normalizeAcquisitionMethod()
        if !silent {
            model.statusLines.append("[sources] Refreshed \(model.sourceCandidates.count) APFS/mounted source candidates.")
        }
    }

    private func prepareSourcesOnAppear() {
        guard !model.isPreparingSources else { return }
        model.isPreparingSources = true
        DispatchQueue.global(qos: .userInitiated).async {
            let rsyncAvailable = ForensicToolLocator.resolve("rsync") != nil
            let candidates = RecoverySourceScanner.scan()
            DispatchQueue.main.async {
                model.rsyncAvailable = rsyncAvailable
                model.sourceCandidates = candidates
                normalizeAcquisitionMethod()
                selectRecommendedSourceIfNeeded(force: model.selectedSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.selectedSource == "/System/Volumes/Data" || model.selectedSource == "/Volumes/System/Data")
                        model.isPreparingSources = false
            }
        }
    }

    private func refreshSourcesForPreflight() {
        model.sourceCandidates = RecoverySourceScanner.scan()
        if model.selectedSourceDevice.isEmpty,
           let candidate = model.sourceCandidates.first(where: { $0.acquisitionPath == model.selectedSource }) {
            model.selectedSourceDevice = candidate.deviceIdentifier
        }
        if selectedSourceCandidate?.isAcquisitionSelectable != true || resolvedSourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selectRecommendedSourceIfNeeded(force: true)
        }
    }

    private func selectRecommendedSourceIfNeeded(force: Bool = false) {
        let sourceMissing = model.selectedSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let currentSourceExists = FileManager.default.fileExists(atPath: resolvedSourcePath)
        let placeholderSource = model.selectedSource == "/System/Volumes/Data" || model.selectedSource == "/Volumes/System/Data"
        if !force && !sourceMissing && currentSourceExists && model.selectedSourceDevice.isEmpty && !placeholderSource { return }
        guard force || sourceMissing || !currentSourceExists || model.selectedSourceDevice.isEmpty || placeholderSource else { return }
        let candidate = model.sourceCandidates.first(where: { $0.isRecommendedDataSource }) ??
            model.sourceCandidates.first(where: { $0.isAcquisitionSelectable && !$0.roles.contains("APFS Container") })
        guard let candidate else {
            if !currentSourceExists {
                model.selectedSource = ""
                model.selectedSourceDevice = ""
            }
            return
        }
        model.selectedSourceDevice = candidate.deviceIdentifier
        if let sourcePath = candidate.acquisitionPath {
            model.selectedSource = sourcePath
        }
    }

    private func selectPreparedDestinationIfNeeded() {
        guard model.destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let volumesURL = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard let volumes = try? FileManager.default.contentsOfDirectory(
            at: volumesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let preferred = volumes.first { $0.lastPathComponent == "macCollect_Evidence" } ??
            volumes.first { $0.lastPathComponent == "macCollectE" } ??
            volumes.first { $0.lastPathComponent == "macCollect_Destination" } ??
            volumes.first {
                let name = $0.lastPathComponent.lowercased()
                return name.contains("evidence") || name.contains("destination")
            }

        guard let preferred, preferred.path != model.selectedSource, preferred.lastPathComponent != "macCollect" else { return }
        model.destinationPath = preferred.path
        model.statusLines.append("[destination] Auto-selected prepared destination: \(model.destinationPath)")
    }

    private func normalizeAcquisitionMethod() {
        if model.method == .rsync, !isRsyncAvailable {
            model.method = .ditto
            model.statusLines.append("[method] rsync is unavailable; switched to ditto.")
        }
        normalizeOutputFormat()
    }

    private func normalizeOutputFormat() {
        _ = model.outputFormat
    }

    private func cancelAcquisition() {
        model.cancellationToken?.cancel()
        model.acquisitionFailure = "Cancellation requested."
        appendAcquisitionLog("[cancel] Cancellation requested.")
    }

    private var isRecoveryAcquisitionContext: Bool {
        profile.bootContext.localizedCaseInsensitiveContains("recovery") ||
            profile.bootContext.localizedCaseInsensitiveContains("installer")
    }

    private var elapsedText: String {
        guard let acquisitionStartedAt = model.acquisitionStartedAt else { return "00:00:00" }
        let seconds = max(0, Int(model.elapsedNow.timeIntervalSince(acquisitionStartedAt)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func appendAcquisitionLog(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        updateAcquisitionProgress(from: trimmed)
        if isCopyOutputLine(trimmed) && !isCommandLine(trimmed) {
            return
        }
        model.statusLines.append(timestampedMultilineLog(trimmed))
        trimVisibleAcquisitionLog()
    }

    private func trimVisibleAcquisitionLog(limit: Int = 1_000) {
        guard model.statusLines.count > limit else { return }
        model.statusLines.removeFirst(model.statusLines.count - limit)
    }

    private func timestampedMultilineLog(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? line : acquisitionTimestampedLogLine(line)
            }
            .joined(separator: "\n")
    }

    private func createAcquisitionReportFiles(for plan: AcquisitionPlan, startedAt: Date) -> [URL] {
        let baseName = safeAcquisitionFileName(plan.imageName)
        var urls: [URL] = []
        var seen = Set<String>()

        if !plan.destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let directory = plan.outputDirectoryURL
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("\(baseName)-status.txt")
                if seen.insert(url.path).inserted {
                    urls.append(url)
                }
            } catch {
                // The preflight will surface destination problems; keep the UI responsive here.
            }
        }

        return urls
    }

    private func writeAcquisitionReport(status: String, plan: AcquisitionPlan, startedAt: Date, endedAt: Date?, detail: String, finalImagePath: String?, hashText: String, timeline: [AcquisitionTimelineEntry] = []) {
        guard !model.acquisitionReportURLs.isEmpty else { return }
        let text = AcquisitionManifestWriter.statusReportText(
            status: status,
            detail: detail,
            plan: plan,
            startedAt: startedAt,
            endedAt: endedAt,
            finalImagePath: finalImagePath,
            hashText: hashText,
            timeline: timeline
        )
        model.acquisitionReportPreviewText = text
        for url in model.acquisitionReportURLs {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func isCommandLine(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            logComparableLine(line).hasPrefix("$ ")
        }
    }

    private func isCopyOutputLine(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let trimmed = logComparableLine(line)
            let lower = trimmed.lowercased()
            return lower.hasPrefix("ditto:") ||
                lower.hasPrefix("rsync") ||
                lower.hasPrefix("progress:") ||
                lower.contains("error reading block") ||
                lower.hasPrefix("reading ") ||
                lower.hasPrefix("validating ") ||
                lower.hasPrefix("finished") ||
                lower.hasPrefix("done") ||
                lower.contains("failed to create source stream") ||
                lower.contains("no space left on device") ||
                lower.contains("bad file descriptor")
        }
    }

    private func logComparableLine(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let close = trimmed.firstIndex(of: "]") else {
            return trimmed
        }
        return trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func safeAcquisitionFileName(_ value: String) -> String {
        SafeFileName.component(value)
    }

    private func setStage(_ stage: String, _ substatus: String, floor: Double, step: (AcquisitionStepID, AcquisitionStepStatus, String?)? = nil) {
        model.acquisitionStage = stage
        model.acquisitionSubstatus = substatus
        model.acquisitionProgress = max(model.acquisitionProgress, floor)
        if let step {
            setAcquisitionStep(step.0, step.1, detail: step.2)
        }
    }

    private func copyPercentFloor(_ percent: Int?) -> Double {
        0.12 + (Double(percent ?? 0) / 100.0) * copyProgressSpan
    }

    private func updateAcquisitionProgress(from text: String) {
        for line in text.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !line.isEmpty {
            let lower = line.lowercased()
            if lower.contains("maccollect logical acquisition started") {
                setStage("Acquisition started", "Preparing temporary target image", floor: 0.03)
            } else if lower.contains("estimated image size") {
                setStage(line, "Sizing temporary image", floor: 0.04)
            } else if lower.contains("creating temporary sparse image") {
                setStage("Creating temporary image", line, floor: 0.06, step: (.prepareImage, .running, nil))
            } else if lower.hasPrefix("created:") {
                setStage(model.acquisitionStage, "Temporary image created", floor: 0.08, step: (.prepareImage, .done, nil))
            } else if lower.contains("attaching sparse image") {
                setStage("Attaching temporary image", "Mounting temporary image", floor: 0.09, step: (.attachImage, .running, nil))
            } else if lower.contains("/volumes/") && lower.contains("/dev/disk") {
                setStage(model.acquisitionStage, "Temporary image mounted", floor: 0.10, step: (.attachImage, .done, nil))
            } else if lower.hasPrefix("$ ") && lower.contains("/ditto ") {
                let substatus = "ditto: \(dittoCopyTarget(from: line) ?? "copying current item")"
                setStage("Copying source data", substatus, floor: 0.12, step: (.copySource, .running, substatus))
            } else if lower.hasPrefix("$ ") && lower.contains("/rsync ") {
                setStage("Copying source data", "rsync: copying source tree", floor: 0.12, step: (.copySource, .running, "rsync: copying source tree"))
            } else if lower.hasPrefix("progress:") {
                let percent = percentToken(in: line)
                if let percent { updatePercentBasedETA(percent: percent) }
                setStage(percent.map { "Imaging \($0)%" } ?? "Imaging running", line, floor: copyPercentFloor(percent), step: (.copySource, .running, line))
            } else if lower.hasPrefix("[progress] copying source data") {
                if lower.contains("complete") {
                    model.copySpeedText = ""
                    model.estimatedFinishText = ""
                    setStage("Copy stage completed", line, floor: copyCompleteProgress, step: (.copySource, .done, line))
                    continue
                }
                let percent = percentToken(in: line)
                updateCopyMetrics(from: line)
                if let percent {
                    if model.estimatedFinishText.isEmpty {
                        updatePercentBasedETA(percent: percent)
                    }
                    setStage("Copying source data \(percent)%", copyStatusText(from: line), floor: copyPercentFloor(percent), step: (.copySource, .running, line))
                } else {
                    setStage(line, "Copying source data", floor: 0.12, step: (.copySource, .running, line))
                }
            } else if lower.contains("copying ") {
                model.acquisitionStage = "Copying source data"
                if !lower.contains("/volumes/") || model.acquisitionSubstatus.isEmpty {
                    model.acquisitionSubstatus = line
                }
                model.acquisitionProgress = max(model.acquisitionProgress, 0.12)
                setAcquisitionStep(.copySource, .running)
            } else if lower.contains("no space left on device") {
                model.acquisitionStage = line
                model.acquisitionSubstatus = "Copy stage failed"
                model.acquisitionFailure = line
                setAcquisitionStep(.copySource, .failed, detail: line)
            } else if lower.contains("detaching") {
                setStage(model.acquisitionStage, line, floor: 0.86, step: (.copySource, .done, nil))
            } else if lower.hasPrefix("[progress] dmg conversion") || lower.hasPrefix("[progress] udrw conversion") {
                if lower.contains("complete") {
                    model.estimatedFinishText = ""
                    setStage("Compression completed", line, floor: 0.92, step: (.finalizeOutput, .running, "Copying final image to evidence folder next"))
                    continue
                }
                let percent = percentToken(in: line)
                model.copySpeedText = ""
                setStage(percent.map { "Finalizing output \($0)%" } ?? "Finalizing output image", line, floor: 0.86 + (Double(percent ?? 0) / 100.0) * 0.08, step: (.finalizeOutput, .running, line))
            } else if lower.hasPrefix("[progress] final image copy") {
                if lower.contains("complete") {
                    model.estimatedFinishText = ""
                    setStage("Output image finalized", line, floor: 0.94, step: (.finalizeOutput, .done, line))
                    continue
                }
                let percent = percentToken(in: line)
                model.copySpeedText = ""
                setStage(percent.map { "Copying final image \($0)%" } ?? "Copying final image", line, floor: 0.92 + (Double(percent ?? 0) / 100.0) * 0.02, step: (.finalizeOutput, .running, line))
            } else if lower.contains("converting sparse image") || lower.contains("converting dmg") || lower.contains("sparse image ready") {
                setStage("Finalizing output image", line, floor: 0.90, step: (.finalizeOutput, .running, nil))
            } else if lower.contains("hashing output") {
                model.copySpeedText = ""
                model.estimatedFinishText = ""
                setAcquisitionStep(.finalizeOutput, .done)
                setStage("Hashing output image", line, floor: 0.95, step: (.hashOutput, .running, nil))
            } else if lower.contains("wrote report") {
                setAcquisitionStep(.hashOutput, .done)
                setStage("Writing reports", line, floor: 0.98, step: (.writeReports, .done, nil))
            } else if lower.contains("acquisition completed") {
                model.estimatedFinishText = ""
                model.acquisitionProgress = 1.0
                model.acquisitionStage = "Acquisition completed"
                model.acquisitionSubstatus = "Finished"
                completeAllAcquisitionSteps()
            } else if lower.hasPrefix("[error]") {
                model.acquisitionStage = line
                model.acquisitionSubstatus = "Stopped before completion"
                model.acquisitionFailure = line
                failRunningAcquisitionStep(line)
            }
        }
    }


    private func percentToken(in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"([0-9]{1,3})%"#) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[swiftRange]).flatMap { $0 <= 100 ? $0 : nil }
    }

    private func updateCopyMetrics(from line: String) {
        if let speed = firstMatch(in: line, pattern: #", ([^,]+/s), ETA "#) {
            model.copySpeedText = speed
        }
        guard let eta = firstMatch(in: line, pattern: #"ETA ([^)]+)"#) else { return }
        if eta == "unknown" {
            model.estimatedFinishText = "Finish estimate unavailable"
            return
        }
        if let seconds = seconds(fromDuration: eta) {
            let finish = Date().addingTimeInterval(TimeInterval(seconds))
            model.estimatedFinishText = "ETA \(eta), finish about \(timeOnly(finish))"
        } else {
            model.estimatedFinishText = "ETA \(eta)"
        }
    }

    private func updatePercentBasedETA(percent: Int) {
        guard percent > 0,
              let started = model.acquisitionStartedAt else { return }
        let elapsed = max(1, Date().timeIntervalSince(started))
        let total = elapsed / (Double(percent) / 100.0)
        let remaining = max(0, Int(total - elapsed))
        let eta = durationText(remaining)
        let finish = Date().addingTimeInterval(TimeInterval(remaining))
        model.estimatedFinishText = "ETA \(eta), finish about \(timeOnly(finish))"
    }

    private func copyStatusText(from line: String) -> String {
        let prefix = "[progress] "
        return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line
    }

    private var copyProgressSpan: Double {
        0.72
    }

    private var copyCompleteProgress: Double {
        0.84
    }

    private func dittoCopyTarget(from line: String) -> String? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let source = parts.dropLast().last else { return nil }
        return URL(fileURLWithPath: source).lastPathComponent
    }

    private func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[swiftRange])
    }

    private func seconds(fromDuration text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private func durationText(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        return String(format: "%02d:%02d:%02d", safe / 3600, (safe / 60) % 60, safe % 60)
    }

    private func timeOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = systemCommandTimeZone()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func setAcquisitionStep(_ id: AcquisitionStepID, _ status: AcquisitionStepStatus, detail: String? = nil) {
        guard let index = model.acquisitionSteps.firstIndex(where: { $0.id == id }) else { return }
        model.acquisitionSteps[index].status = status
        if let detail {
            model.acquisitionSteps[index].detail = detail
        }
    }

    private func completeAllAcquisitionSteps() {
        for index in model.acquisitionSteps.indices where model.acquisitionSteps[index].status != .failed {
            model.acquisitionSteps[index].status = .done
        }
    }

    private func failRunningAcquisitionStep(_ detail: String) {
        if let index = model.acquisitionSteps.firstIndex(where: { $0.status == .running }) {
            model.acquisitionSteps[index].status = .failed
            model.acquisitionSteps[index].detail = detail
        } else if let index = model.acquisitionSteps.indices.last {
            model.acquisitionSteps[index].status = .failed
            model.acquisitionSteps[index].detail = detail
        }
    }

    private var selectedSourceCandidate: SourceCandidate? {
        model.sourceCandidates.first { candidate in
            (!model.selectedSourceDevice.isEmpty && candidate.deviceIdentifier == model.selectedSourceDevice) ||
                candidate.acquisitionPath == model.selectedSource
        }
    }

    private var availableMethods: [AcquisitionMethod] {
        isRsyncAvailable ? AcquisitionMethod.allCases : [.ditto]
    }

    private var availableOutputFormats: [AcquisitionOutputFormat] {
        return [.compressedDMG, .sparseImage, .uncompressedDMG]
    }

    private var isRsyncAvailable: Bool {
        return model.rsyncAvailable
    }

    private var shouldShowAcquisitionStatus: Bool {
        model.isRunning || model.acquisitionStartedAt != nil || model.acquisitionFailure != nil
    }

    private var canPreviewAcquisitionReport: Bool {
        !model.isRunning &&
            model.acquisitionStartedAt != nil &&
            !model.acquisitionReportPreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var visibleRawLogLines: [String] {
        let limit = 300
        guard model.statusLines.count > limit else { return model.statusLines }
        return ["[ui] Showing the latest \(limit) of \(model.statusLines.count) log entries."] +
            Array(model.statusLines.suffix(limit))
    }

    private var visibleToolOutputLines: [String] {
        let filtered = model.statusLines.filter { line in
            isCommandLine(line) || isCopyOutputLine(line)
        }
        let limit = 300
        let lines = filtered.count > limit
            ? ["[ui] Showing the latest \(limit) of \(filtered.count) tool output entries."] + Array(filtered.suffix(limit))
            : filtered
        return lines.isEmpty ? ["[tool-output] Waiting for copy tool output. Copy warnings and errors will appear here while the command runs."] : lines
    }

    private var resolvedSourcePath: String {
        if let candidate = selectedSourceCandidate,
           let path = candidate.acquisitionPath {
            return path
        }
        return model.selectedSource
    }

    private var sourceDisplayText: String {
        let path = resolvedSourcePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return "No mounted source selected" }
        return path
    }

}

enum AcquisitionLogView: String, CaseIterable, Identifiable {
    case summary
    case toolOutput
    case raw

    var id: String { rawValue }

    var label: String {
        switch self {
        case .summary: return "Progress"
        case .toolOutput: return "Tool Output"
        case .raw: return "Raw Log"
        }
    }
}

private func acquisitionFullTimestamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
    return formatter.string(from: date)
}

private func acquisitionTimestampedLogLine(_ text: String, date: Date = Date()) -> String {
    if text.range(of: #"^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC\]"#, options: .regularExpression) != nil {
        return text
    }
    return "[\(acquisitionFullTimestamp(date))] \(text)"
}

struct AcquisitionAdvancedCasePanel: View {
    @Binding var caseName: String
    @Binding var examiner: String
    @Binding var imageName: String
    let destinationPath: String
    let method: AcquisitionMethod
    let outputFormat: AcquisitionOutputFormat
    @Binding var notes: String
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AcquisitionSectionHeader(
                number: 1,
                title: "General Information",
                subtitle: "Define the evidence identity before choosing source, destination and method.",
                icon: "text.badge.checkmark"
            )

            InputRow("Case") {
                TextField("Case name", text: $caseName)
            }
            InputRow("Examiner") {
                TextField("Examiner", text: $examiner)
            }
            InputRow("Image Name") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Image name", text: $imageName)
                    if let collision = existingImageCollision {
                        Label("Exists already: \(collision)", systemImage: "xmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else if !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Output will be written as \(expectedFinalImagePath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
            InputRow("Notes") {
                if isRunning {
                    Text(notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No notes entered." : notes)
                        .frame(maxWidth: .infinity, minHeight: 70, alignment: .topLeading)
                        .padding(8)
                        .textSelection(.enabled)
                        .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    TextEditor(text: $notes)
                        .frame(height: 70)
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.35), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .acquisitionStepOutline()
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var previewPlan: AcquisitionPlan {
        AcquisitionPlan(
            caseName: caseName,
            examiner: examiner,
            imageName: imageName,
            sourcePath: "",
            destinationPath: destinationPath,
            method: method,
            outputFormat: displayOutputFormat,
            requireReadOnly: false,
            readOnlyCheckNotApplicable: true,
            hashMethods: [],
            notes: notes
        )
    }

    private var expectedFinalImagePath: String {
        previewPlan.expectedFinalImageURL.path
    }

    private var displayOutputFormat: AcquisitionOutputFormat {
        return outputFormat
    }

    private var existingImageCollision: String? {
        guard !destinationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return previewPlan.existingOutputConflicts().first?.path
    }
}

private extension View {
    func acquisitionStepOutline() -> some View {
        overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.48), lineWidth: 1.5)
        )
        .shadow(color: .black.opacity(0.24), radius: 3, x: 0, y: 1)
    }
}

struct AcquisitionAdvancedSourceDestinationPanel: View {
    let candidates: [SourceCandidate]
    @Binding var selectedSource: String
    @Binding var selectedDevice: String
    let sourceDisplayText: String
    @Binding var destinationPath: String
    let chooseSource: () -> Void
    let chooseDestination: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AcquisitionSectionHeader(
                number: 2,
                title: "Source and Destination",
                subtitle: "Choose what is acquired and where the evidence package will be written.",
                icon: "arrow.left.arrow.right"
            )

            AcquisitionSourceSelectionPanel(
                candidates: candidates,
                selectedSource: $selectedSource,
                selectedDevice: $selectedDevice,
                sourceDisplayText: sourceDisplayText,
                chooseSource: chooseSource
            )

            AcquisitionDestinationPanel(destinationPath: $destinationPath, chooseDestination: chooseDestination)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .acquisitionStepOutline()
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AcquisitionDestinationPanel: View {
    @Binding var destinationPath: String
    let chooseDestination: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Destination", systemImage: "externaldrive")
                    .font(.headline)
                Spacer()
                Button(action: chooseDestination) {
                    Label("Choose", systemImage: "folder")
                }
            }
            Text("Use a prepared external evidence volume. The source mount itself is blocked by preflight.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("External destination path", text: $destinationPath)
                .textFieldStyle(.roundedBorder)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct AcquisitionAdvancedMethodPanel: View {
    @Binding var method: AcquisitionMethod
    @Binding var outputFormat: AcquisitionOutputFormat
    let availableMethods: [AcquisitionMethod]
    let availableOutputFormats: [AcquisitionOutputFormat]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AcquisitionSectionHeader(
                number: 3,
                title: "Method and Verification",
                subtitle: "Choose the copy engine and output image type. MD5 and SHA256 are always computed over the final image.",
                icon: "slider.horizontal.3"
            )

            InputRow("Method") {
                Picker("", selection: $method) {
                    ForEach(availableMethods) { methodOption in
                        Text(methodOption.label).tag(methodOption)
                    }
                }
                .labelsHidden()
            }
            InputRow("Output") {
                Picker("", selection: $outputFormat) {
                    ForEach(availableOutputFormats) { format in
                        Text(format.label).tag(format)
                    }
                }
                .labelsHidden()
            }

            AcquisitionMethodGuide(method: method, outputFormat: outputFormat)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .acquisitionStepOutline()
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

}

struct AcquisitionAdditionalSettingsPanel: View {
    @Binding var enforceReadOnly: Bool
    @Binding var ignoreDestinationSizeCheck: Bool
    @Binding var createFailedFilePlaceholders: Bool
    @Binding var shutdownAfterSuccess: Bool
    let isRecovery: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AcquisitionSectionHeader(
                number: 4,
                title: "Additional Settings",
                subtitle: "Tune safety checks, logging and examiner conveniences before preflight.",
                icon: "switch.2"
            )

            VStack(spacing: 8) {
                if isRecovery {
                    SettingToggleRow(
                        title: "Require read-only source",
                        detail: "Typical Recovery default. Keep enabled for mounted evidence volumes; disable only for a documented live/writable collection.",
                        systemImage: "lock.shield",
                        isOn: $enforceReadOnly
                    )
                }
                SettingToggleRow(
                    title: "Ignore destination size warning",
                    detail: "Only use after checking the destination manually. This lets preflight continue when macCollect cannot estimate source size reliably.",
                    systemImage: "externaldrive.badge.exclamationmark",
                    isOn: $ignoreDestinationSizeCheck
                )
                FailedFilePlaceholderSettingRow(isOn: $createFailedFilePlaceholders)
                SettingToggleRow(
                    title: "Shut down after success",
                    detail: "Useful for unattended overnight copies. Shutdown is requested only after copy, reports and selected hashes complete successfully.",
                    systemImage: "power",
                    isOn: $shutdownAfterSuccess
                )
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .acquisitionStepOutline()
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct FailedFilePlaceholderSettingRow: View {
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Create failed-file placeholders", isOn: $isOn)
                    .font(.callout.weight(.semibold))
                Text("Useful when a few items cannot be copied but the rest should continue, especially iCloud files that are listed locally but not downloaded. Failed items are always logged; this only adds the same marked dummy file at each failed path so it remains visible and can be excluded by hash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    PlaceholderHashRow(label: "MD5", value: "d8ca7979802abe3542847b95d24c266e")
                    PlaceholderHashRow(label: "SHA256", value: "146d7057ef2bcb57e8e66f670cdb097cea9f7500045d0499c4a56f53f3efe313")
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct PlaceholderHashRow: View {
    let label: String
    let value: String

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
                Text(value)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }
}

struct SettingToggleRow: View {
    let title: String
    let detail: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Toggle(title, isOn: $isOn)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct AcquisitionAdvancedPreflightPanel: View {
    let isRunning: Bool
    let isUnlocking: Bool
    let checks: [PreflightCheck]
    @Binding var showPreflightDetails: Bool
    @Binding var showCommandDetails: Bool
    let source: String
    let sourceDevice: String?
    let destination: String
    let imageName: String
    let method: AcquisitionMethod
    let outputFormat: AcquisitionOutputFormat
    let hashMethods: [AcquisitionHashMethod]
    let runPreflight: () -> Void
    let start: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AcquisitionSectionHeader(
                number: 5,
                title: "Preflight and Start",
                subtitle: "Validate the setup, review command intent and start the controlled run.",
                icon: "checkmark.shield"
            )

            AcquisitionPreflightNotice()

            AcquisitionActionBar(
                isRunning: isRunning,
                isUnlocking: isUnlocking,
                runPreflight: runPreflight,
                start: start,
                cancel: cancel
            )

            if !checks.isEmpty {
                AcquisitionPreflightResultsDisclosure(checks: checks, isExpanded: $showPreflightDetails)
            }

            DisclosureGroup(isExpanded: $showCommandDetails) {
                CommandPreview(
                    source: source,
                    sourceDevice: sourceDevice,
                    destination: destination,
                    imageName: imageName,
                    method: method,
                    outputFormat: outputFormat,
                    hashMethods: hashMethods
                )
                .padding(.top, 4)
            } label: {
                Label("Technical command details", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 2)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .acquisitionStepOutline()
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AcquisitionPreflightResultsDisclosure: View {
    let checks: [PreflightCheck]
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            PreflightPanel(checks: checks)
                .padding(.top, 8)
        } label: {
            PreflightSummaryLabel(checks: checks)
        }
    }
}

struct AcquisitionSectionHeader: View {
    let number: Int
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(number)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Label(title, systemImage: icon)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Divider()
        }
    }
}

struct AcquisitionSourceSelectionPanel: View {
    let candidates: [SourceCandidate]
    @Binding var selectedSource: String
    @Binding var selectedDevice: String
    let sourceDisplayText: String
    let chooseSource: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Source Volume", systemImage: "internaldrive")
                    .font(.headline)
                Spacer()
                Button(action: chooseSource) {
                    Label("Refresh / Select", systemImage: "internaldrive")
                }
            }

            Text("Select the APFS Data volume for user files and most artifacts. macCollect boot and evidence volumes are excluded from valid sources.")
                .font(.callout)
                .foregroundStyle(.secondary)

            RecoverySourcePicker(
                candidates: candidates,
                selectedSource: $selectedSource,
                selectedDevice: $selectedDevice
            )
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct AcquisitionStatusBanner: View {
    let stage: String
    let substatus: String
    let progress: Double
    let elapsed: String
    let speed: String
    let eta: String
    let failure: String?
    let isRunning: Bool
    @State private var spin = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            statusIcon
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(failure == nil ? "Current Imaging Status" : "Acquisition Stopped")
                        .font(.headline)
                    Spacer()
                    Text(elapsed)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(failure ?? stage)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                ProgressView(value: min(max(progress, 0), 1))
                    .controlSize(.large)
                HStack(spacing: 12) {
                    Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                    if !speed.isEmpty {
                        Text(speed)
                            .font(.caption.monospacedDigit())
                    }
                    if !eta.isEmpty {
                        Text(eta)
                            .font(.caption)
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
                Text(substatus.isEmpty ? stage : substatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(tint.opacity(0.11))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tint: Color {
        if failure != nil { return .red }
        return isRunning ? .blue : .green
    }

    private var shouldSpin: Bool {
        isRunning && failure == nil
    }

    @ViewBuilder
    private var statusIcon: some View {
        if shouldSpin {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 1.2).repeatForever(autoreverses: false), value: spin)
                .onAppear { spin = true }
        } else {
            Image(systemName: failure == nil ? "checkmark.seal.fill" : "xmark.octagon.fill")
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 30)
                .onAppear { spin = false }
        }
    }
}

struct AcquisitionReportPreview: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Acquisition Log Preview", systemImage: "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                Text(text.isEmpty ? "No acquisition log has been written yet." : text)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(minWidth: 720, minHeight: 520)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(18)
    }
}

struct AcquisitionActionBar: View {
    let isRunning: Bool
    let isUnlocking: Bool
    let runPreflight: () -> Void
    let start: () -> Void
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            Button(action: runPreflight) {
                Label("Run Preflight", systemImage: "checkmark.shield")
            }
            .disabled(isRunning || isUnlocking)

            if isRunning {
                Button(action: cancel) {
                    Label("Cancel", systemImage: "stop.fill")
                }
            }

            Button(action: start) {
                Label(isRunning ? "Running" : "Start Acquisition", systemImage: isRunning ? "hourglass" : "play.fill")
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .buttonStyle(.borderedProminent)
            .disabled(isRunning || isUnlocking)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct PreflightSummaryLabel: View {
    let checks: [PreflightCheck]

    var body: some View {
        HStack(spacing: 8) {
            Label("Preflight Results", systemImage: failures > 0 ? "xmark.octagon.fill" : warnings > 0 ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                .font(.headline)
                .foregroundStyle(failures > 0 ? Color.red : warnings > 0 ? Color.orange : Color.green)
            Spacer()
            Text("\(failures) failures, \(warnings) warnings")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var failures: Int { checks.filter { $0.severity == .fail }.count }
    private var warnings: Int { checks.filter { $0.severity == .warning }.count }
}

enum AcquisitionStepStatus: String {
    case pending
    case running
    case done
    case failed

    var icon: String {
        switch self {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .pending: return .secondary
        case .running: return .blue
        case .done: return .green
        case .failed: return .red
        }
    }
}

enum AcquisitionStepID: String, CaseIterable, Identifiable {
    case preflight
    case prepareImage
    case attachImage
    case copySource
    case finalizeOutput
    case hashOutput
    case writeReports

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preflight: return "Preflight"
        case .prepareImage: return "Prepare Image"
        case .attachImage: return "Attach Image"
        case .copySource: return "Copy Source"
        case .finalizeOutput: return "Finalize Output"
        case .hashOutput: return "Hash Output"
        case .writeReports: return "Write Reports"
        }
    }
}

struct AcquisitionProgressStep: Identifiable {
    let id: AcquisitionStepID
    var title: String
    var status: AcquisitionStepStatus
    var detail: String

    static func defaultSteps() -> [AcquisitionProgressStep] {
        AcquisitionStepID.allCases.map { AcquisitionProgressStep(id: $0, title: $0.title, status: .pending, detail: "Waiting") }
    }

    static func defaultSteps(for plan: AcquisitionPlan) -> [AcquisitionProgressStep] {
        defaultSteps()
    }
}

struct AcquisitionPreflightNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(Color.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text("Preflight before imaging")
                    .font(.headline)
                Text("Run Preflight to review the setup before you start. Start runs the same preflight again and blocks acquisition on failed checks; warnings remain examiner decisions.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.blue.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct AcquisitionMethodGuide: View {
    let method: AcquisitionMethod
    let outputFormat: AcquisitionOutputFormat

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(method.shortGuide) · \(outputFormat.shortGuide)")
                    .font(.subheadline.weight(.semibold))
                Text(method.riskNote)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private extension AcquisitionMethod {
    var shortGuide: String {
        switch self {
        case .rsync: return "rsync logical copy"
        case .ditto: return "ditto logical copy"
        }
    }

    var riskNote: String {
        switch self {
        case .rsync: return "Preferred when available; ditto fallback on protocol errors."
        case .ditto: return "Native fallback; less resumable but simple."
        }
    }
}

private extension AcquisitionOutputFormat {
    var shortGuide: String {
        switch self {
        case .compressedDMG: return "compressed DMG"
        case .sparseImage: return "sparseimage"
        case .uncompressedDMG: return "uncompressed DMG"
        }
    }
}

struct AcquisitionProgressPanel: View {
    let progress: Double
    let stage: String
    let elapsed: String
    let steps: [AcquisitionProgressStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Imaging Progress")
                    .font(.headline)
                Spacer()
                Text("Elapsed \(elapsed)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(progress, 0), 1))
                .controlSize(.large)
            HStack {
                Text(stage)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
                    .font(.headline.monospacedDigit())
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(steps) { step in
                    AcquisitionStepTile(step: step)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

struct AcquisitionStepTile: View {
    let step: AcquisitionProgressStep

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: step.status.icon)
                .foregroundStyle(step.status.color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .background(stepBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.55), lineWidth: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .inset(by: 2)
                .stroke(step.status.color.opacity(0.9), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.32), radius: 3, x: 0, y: 1)
    }

    private var stepBackground: Color {
        switch step.status {
        case .pending:
            return Color(nsColor: .textBackgroundColor).opacity(0.92)
        default:
            return step.status.color.opacity(0.34)
        }
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct CommandPreviewBox: View {
    let rows: [(text: AttributedString, tint: Color)]
    let note: String
    let legend: [ToolLegendItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: 18, alignment: .trailing)
                        Text(row.text)
                            .scaledMonospaced(11)
                            .lineLimit(nil)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(row.tint.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(row.tint.opacity(0.72))
                            .frame(width: 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .textSelection(.enabled)

            Text(note)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            ToolLegend(items: legend)
        }
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct CommandPreview: View {
    let source: String
    let sourceDevice: String?
    let destination: String
    let imageName: String
    let method: AcquisitionMethod
    let outputFormat: AcquisitionOutputFormat
    let hashMethods: [AcquisitionHashMethod]

    var body: some View {
        CommandPreviewBox(
            rows: commands.map { (highlightedCommand($0), commandTint($0)) },
            note: outputFormatNote,
            legend: legendItems
        )
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
            } else if trimmed.contains("RUNTIME_") || trimmed.contains("UUID_NOT_RESOLVED") || trimmed.contains("DESTINATION_NOT_SELECTED") {
                token.foregroundColor = .orange
            } else if trimmed.contains("/") {
                token.foregroundColor = .teal
            } else if trimmed == ";" {
                token.foregroundColor = .secondary
            } else {
                token.foregroundColor = .primary
            }

            highlighted.append(token)
            firstToken = false
        }
        return highlighted
    }

    private var commandNames: Set<String> {
        ["hdiutil", "ditto", "rsync", "mv", "streamed", "shasum", "md5", "openssl"]
    }

    private func commandTint(_ command: String) -> Color {
        let name = command.split(separator: " ").first.map(String.init) ?? command
        switch name {
        case "hdiutil":
            return .blue
        case "ditto", "rsync":
            return .orange
        case "mv":
            return .teal
        case "streamed", "shasum", "md5", "openssl":
            return .purple
        default:
            return .accentColor
        }
    }

    private var outputFormatNote: String {
        switch outputFormat {
        case .compressedDMG:
            return "Output: compressed DMG via \(AcquisitionOutputFormat.compressedDMG.technicalName)."
        case .sparseImage:
            return "Output: staged sparseimage is kept."
        case .uncompressedDMG:
            return "Output: uncompressed DMG via \(AcquisitionOutputFormat.uncompressedDMG.technicalName)."
        }
    }

    private var legendItems: [ToolLegendItem] {
        var items: [ToolLegendItem] = [
            ToolLegendItem(name: "hdiutil", detail: "create, attach and convert images", color: .blue),
            ToolLegendItem(name: method.rawValue, detail: "copy source data", color: commandTint(method.rawValue))
        ]
        if outputFormat != .sparseImage {
            items.append(ToolLegendItem(name: "mv", detail: "move finalized DMG into evidence folder", color: .teal))
        }
        if !hashMethods.isEmpty {
            items.append(ToolLegendItem(name: "streamed hash", detail: hashMethods.map(\.label).joined(separator: ", "), color: .purple))
        }
        return items
    }

    private var commands: [String] {
        let safeImage = imageName.isEmpty ? "macCollect_Acquisition" : imageName
        let outputDir = destination.isEmpty ? "DESTINATION_NOT_SELECTED/\(safeImage)" : "\(destination)/\(safeImage)"
        let sparse = "\(outputDir)/\(safeImage)-temporary.sparseimage"
        let mountedSparseRoot = "/Volumes/\(safeImage)"
        let conversionSparse = "\(outputDir)/\(safeImage)-conversion.sparseimage"
        let conversionMount = "/Volumes/\(safeImage)-conversion"
        let finalDMG = "\(outputDir)/\(safeImage).dmg"
        let finalUDRW = "\(outputDir)/\(safeImage)_uncompressed.dmg"
        var result = [
            "hdiutil create -size RUNTIME_ESTIMATED_SIZE -fs APFS -volname \(shellQuote(safeImage)) \(shellQuote(sparse))",
            "hdiutil attach -nobrowse \(shellQuote(sparse))"
        ]

        switch method {
        case .ditto:
            result.append("ditto -X \(shellQuote(sourceWithTrailingSlash)) \(shellQuote(mountedSparseRoot))")
        case .rsync:
            let flags = AcquisitionRunner.rsyncPreservationArguments(executablePath: method.executablePath).joined(separator: " ")
            result.append("rsync \(flags) \(shellQuote(sourceWithTrailingSlash)) \(shellQuote(mountedSparseRoot))")
        }

        switch outputFormat {
        case .compressedDMG:
            result.append("hdiutil create -size RUNTIME_CONVERSION_SIZE -fs APFS -volname \(shellQuote("\(safeImage)-conversion")) \(shellQuote(conversionSparse))")
            result.append("hdiutil attach -nobrowse \(shellQuote(conversionSparse))")
            result.append("hdiutil convert \(shellQuote(sparse)) -format UDZO -o \(shellQuote("\(conversionMount)/\(safeImage).dmg"))")
            result.append("mv \(shellQuote("\(conversionMount)/\(safeImage).dmg")) \(shellQuote(finalDMG))")
        case .sparseImage:
            result.append("mv \(shellQuote(sparse)) \(shellQuote("\(outputDir)/\(safeImage).sparseimage"))")
        case .uncompressedDMG:
            result.append("hdiutil create -size RUNTIME_CONVERSION_SIZE -fs APFS -volname \(shellQuote("\(safeImage)-conversion")) \(shellQuote(conversionSparse))")
            result.append("hdiutil attach -nobrowse \(shellQuote(conversionSparse))")
            result.append("hdiutil convert \(shellQuote(sparse)) -format UDRW -o \(shellQuote("\(conversionMount)/\(safeImage)_uncompressed.dmg"))")
            result.append("mv \(shellQuote("\(conversionMount)/\(safeImage)_uncompressed.dmg")) \(shellQuote(finalUDRW))")
        }

        if !hashMethods.isEmpty {
            result.append(hashMethods.map(\.commandPreview).joined(separator: " ; "))
        }
        return result
    }

    private var sourceWithTrailingSlash: String {
        source.hasSuffix("/") ? source : source + "/"
    }

}


struct ToolLegendItem: Identifiable {
    let id = UUID()
    let name: String
    let detail: String
    let color: Color
}

struct ToolLegend: View {
    let items: [ToolLegendItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 7, height: 7)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                            .font(.caption2.weight(.semibold))
                        Text(item.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(item.color.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }
}

struct RecoverySourcePicker: View {
    let candidates: [SourceCandidate]
    @Binding var selectedSource: String
    @Binding var selectedDevice: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if visibleCandidates.isEmpty {
                Text("No mounted acquisition source candidates detected. Unlock FileVault Data and refresh sources.")
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            ForEach(visibleCandidates) { candidate in
                Button(action: {
                    selectedDevice = candidate.deviceIdentifier
                    if let sourcePath = candidate.acquisitionPath {
                        selectedSource = sourcePath
                    }
                }) {
                    HStack {
                        Image(systemName: selectedDevice == candidate.deviceIdentifier ? "largecircle.fill.circle" : "circle")
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 8) {
                                Text(sourceTitle(candidate))
                                    .font(.subheadline.weight(.semibold))
                                if candidate.isRecommendedDataSource {
                                    OverviewBadge(text: "Recommended Data", color: .orange)
                                } else if !candidate.roles.isEmpty {
                                    OverviewBadge(text: candidate.roles.joined(separator: ", "), color: .blue)
                                }
                                OverviewBadge(text: candidate.readOnly == true ? "Read-only" : candidate.readOnly == false ? "Writable" : "Write state unknown", color: candidate.readOnly == true ? .green : candidate.readOnly == false ? .orange : .gray)
                                if let sealStatus = candidate.sealStatus {
                                    OverviewBadge(text: sealStatus, color: candidate.hasBrokenSeal ? .red : .green)
                                }
                            }
                            Text(sourcePathText(candidate))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(candidate.synthesisDetail ?? candidate.source)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(candidate.deviceIdentifier)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(selectedDevice == candidate.deviceIdentifier ? Color.accentColor.opacity(0.15) : Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var visibleCandidates: [SourceCandidate] {
        candidates.filter { $0.isAcquisitionSelectable && !$0.roles.contains("APFS Container") }
    }

    private func sourceTitle(_ candidate: SourceCandidate) -> String {
        let roleText = candidate.roles.joined(separator: ", ")
        if candidate.name.localizedCaseInsensitiveCompare(roleText) == .orderedSame {
            return "\(candidate.name) \(candidate.deviceIdentifier)"
        }
        if roleText.isEmpty {
            return "\(candidate.name) \(candidate.deviceIdentifier)"
        }
        return "\(candidate.name) (\(roleText)) \(candidate.deviceIdentifier)"
    }

    private func sourcePathText(_ candidate: SourceCandidate) -> String {
        candidate.acquisitionPath ?? "Unmounted"
    }
}

extension SourceCandidate {
    var acquisitionPath: String? {
        if roles.contains("APFS Container"), let containerReference, !containerReference.isEmpty {
            return "/dev/\(containerReference)"
        }
        if let mountPoint = mountPoint?.trimmingCharacters(in: .whitespacesAndNewlines), !mountPoint.isEmpty {
            return mountPoint
        }
        if isRecommendedDataSource {
            let fm = FileManager.default
            let preferredPaths = ForensicDataRoot.isRecoveryEnvironment
                ? ["/Volumes/Data"]
                : ["/System/Volumes/Data", "/Volumes/Data"]
            for path in preferredPaths where fm.fileExists(atPath: path) && fm.fileExists(atPath: "\(path)/Users") {
                return path
            }
        }
        return nil
    }

    var isRecommendedDataSource: Bool {
        roles.contains { $0.localizedCaseInsensitiveCompare("Data") == .orderedSame } ||
            name.localizedCaseInsensitiveCompare("Data") == .orderedSame ||
            mountPoint == "/System/Volumes/Data" ||
            mountPoint == "/Volumes/Data" ||
            mountPoint?.hasSuffix("/Data") == true
    }

    var isAcquisitionSelectable: Bool {
        acquisitionPath != nil &&
            locked != true &&
            !isKnownAuxiliaryVolume
    }

}

struct PreflightPanel: View {
    let checks: [PreflightCheck]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Preflight")
                    .font(.headline)
                Spacer()
                Text("\(checks.filter { $0.severity == .fail }.count) failures, \(checks.filter { $0.severity == .warning }.count) warnings")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 0) {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: check.severity))
                            .foregroundStyle(color(for: check.severity))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                                .font(.subheadline.weight(.semibold))
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 7)
                    Divider()
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func icon(for severity: PreflightSeverity) -> String {
        switch severity {
        case .info: return "info.circle.fill"
        case .pass: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    private func color(for severity: PreflightSeverity) -> Color {
        switch severity {
        case .info: return .blue
        case .pass: return .green
        case .warning: return .orange
        case .fail: return .red
        }
    }
}

struct ReadOnlyWarning: View {
    let sourcePath: String
    let readOnly: Bool?
    let sourceDevice: String?
    let enforceReadOnly: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: readOnly == true || !enforceReadOnly ? "checkmark.shield.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(readOnly == true || !enforceReadOnly ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(enforceReadOnly ? "Recovery source write state" : "Read-only check disabled")
                    .font(.headline)
                Text("Source: \(sourcePath) \(sourceDevice.map { "(\($0))" } ?? "")")
                    .foregroundStyle(.secondary)
                Text(readOnly.map { $0 ? "Mounted read-only." : "Mounted writable; preflight blocks when enforcement is enabled." } ?? "Read-only state unknown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background((readOnly == true || !enforceReadOnly ? Color.green : Color.orange).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
