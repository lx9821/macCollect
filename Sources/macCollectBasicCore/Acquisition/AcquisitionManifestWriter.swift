import Foundation

private struct FailedCopyCSVRow {
    let context: String
    let exitCode: String
    let classification: String
    let reason: String
    let path: String
    let sourcePath: String
    let tool: String
    let rawLine: String
}

public struct AcquisitionManifestWriter {
    let plan: AcquisitionPlan
    let startedAt: Date
    let timeline: [AcquisitionTimelineEntry]
    let copyWarnings: [String]
    let failedCopies: [String]
    let commandLog: [String]
    let toolVersions: [String: String]
    let log: AcquisitionRunner.LogHandler

    func write(outputDirectory: URL, finalImage: URL, hashText: String, endedAt: Date) throws {
        let reportURL = outputDirectory.appendingPathComponent("\(safeName(plan.imageName)).txt")
        let failedCopiesCSVFileName = "\(safeName(plan.imageName))-failed-files.csv"
        let text = conciseReport(
            finalImage: finalImage,
            hashText: hashText,
            endedAt: endedAt,
            failedCopiesCSVFileName: failedCopiesCSVFileName
        )
        try text.write(to: reportURL, atomically: true, encoding: .utf8)
        if !failedCopies.isEmpty {
            try failedCopiesCSVText().write(
                to: outputDirectory.appendingPathComponent(failedCopiesCSVFileName),
                atomically: true,
                encoding: .utf8
            )
        }
        log("Wrote report: \(reportURL.path)")
    }

    func writeFailedCopiesOnly(outputDirectory: URL) throws {
        guard !failedCopies.isEmpty else { return }
        let failedCopiesCSVFileName = "\(safeName(plan.imageName))-failed-files.csv"
        let csvURL = outputDirectory.appendingPathComponent(failedCopiesCSVFileName)
        try failedCopiesCSVText().write(to: csvURL, atomically: true, encoding: .utf8)
        log("Wrote failed copy CSV: \(csvURL.path)")
    }

    public static func statusReportText(
        status: String,
        detail: String,
        plan: AcquisitionPlan,
        startedAt: Date,
        endedAt: Date?,
        finalImagePath: String?,
        hashText: String,
        timeline: [AcquisitionTimelineEntry]
    ) -> String {
        AcquisitionManifestWriter(
            plan: plan,
            startedAt: startedAt,
            timeline: timeline,
            copyWarnings: [],
            failedCopies: [],
            commandLog: [],
            toolVersions: [:],
            log: { _ in }
        ).statusReport(status: status, detail: detail, endedAt: endedAt, finalImagePath: finalImagePath, hashText: hashText)
    }

    private func statusReport(status: String, detail: String, endedAt: Date?, finalImagePath: String?, hashText: String) -> String {
        let separator = String(repeating: "-", count: 72)
        var lines = [
            "macCollect Acquisition Report",
            "Version: \(appVersionText())",
            separator,
            "",
            "Acquisition Status",
            field("Status", status)
        ]
        if !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !(status.localizedCaseInsensitiveCompare("Completed") == .orderedSame && detail.localizedCaseInsensitiveCompare("Acquisition completed.") == .orderedSame) {
            lines.append(field("Status Detail", detail))
        }
        lines.append(contentsOf: [
            "",
            "Case Information",
            field("Case Number", notFilledFallback(plan.caseName)),
            field("Evidence Name", safeName(plan.imageName)),
            field("Examiner", notFilledFallback(plan.examiner)),
            field("Notes", notFilledFallback(plan.notes)),
            "",
            "System Information"
        ])
        lines.append(contentsOf: systemInformationLines())
        if let timeContext = plan.timeContext {
            lines.append(contentsOf: [
                "",
                "Time Context",
                field("System Time", timeContext.actualSystemTime),
                field("Report Time", timeContext.effectiveDisplayTime),
                field("Report Zone", timeContext.effectiveTimeZone),
                field("Acquisition Start", displayTime(startedAt, context: timeContext)),
                field("Acquisition End", endedAt.map { displayTime($0, context: timeContext) } ?? "Not finished")
            ])
            if !timeline.isEmpty {
                lines.append("  Phase Timeline:")
                lines.append(contentsOf: compactTimeline(timeline).map { entry in
                    let start = displayTime(entry.startedAt, context: timeContext)
                    let end = entry.endedAt.map { displayTime($0, context: timeContext) } ?? "Not finished"
                    let duration = entry.endedAt.map { " (\(durationText($0.timeIntervalSince(entry.startedAt))))" } ?? ""
                    return "    \(entry.phase): \(start) -> \(end)\(duration)"
                })
            }
        }
        lines.append(contentsOf: [
            "",
            "Acquisition Information",
            field("Acquisition Type", "Filesystem acquisition"),
            field("Source", plan.sourcePath),
            field("Source Device", plan.sourceDeviceIdentifier ?? "Unknown"),
            field("Source Role", plan.sourceRoles.isEmpty ? "Unknown" : plan.sourceRoles.joined(separator: ", ")),
            field("Mount State", plan.sourceReadOnlyHint.map { $0 ? "Read-only" : "Writable" } ?? "Unknown"),
            field("Read-only", plan.requireReadOnly ? "Required" : plan.readOnlyCheckNotApplicable ? "Not applicable" : "Disabled"),
            field("Destination", plan.destinationPath),
            field("Started", plan.timeContext.map { displayTime(startedAt, context: $0) } ?? timestamp(startedAt)),
            field("Finished", endedAt.map { date in plan.timeContext.map { displayTime(date, context: $0) } ?? timestamp(date) } ?? "Not finished"),
            field("Method", reportMethodLabel(plan.method)),
            field("Output Format", plan.outputFormat.label),
            ""
        ])
        lines.append("Image Result")
        lines.append(field("Image File", finalImagePath ?? "Not finalized"))
        let hashes = parsedHashes(from: hashText)
            .filter { !$0.value.localizedCaseInsensitiveContains("not computed") }
            .map { (name: $0.name.replacingOccurrences(of: " checksum", with: "", options: .caseInsensitive), value: $0.value) }
        if hashes.isEmpty {
            lines.append(field("Hashes", hashText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Not computed" : hashText))
        } else {
            lines.append(contentsOf: hashes.map { field($0.name, $0.value) })
        }
        lines.append(separator)
        return lines.joined(separator: "\n") + "\n"
    }

    private func conciseReport(
        finalImage: URL,
        hashText: String,
        endedAt: Date,
        failedCopiesCSVFileName: String
    ) -> String {
        let separator = String(repeating: "-", count: 72)
        let hashes = parsedHashes(from: hashText)
        var lines: [String] = [
            "macCollect Acquisition Report",
            "Version: \(appVersionText())",
            separator,
            "",
            "Acquisition Status",
            field("Status", "Completed"),
            "",
            "Case Information",
            field("Case Number", notFilledFallback(plan.caseName)),
            field("Evidence Name", safeName(plan.imageName)),
            field("Examiner", notFilledFallback(plan.examiner)),
            field("Notes", notFilledFallback(plan.notes)),
            "",
            "System Information"
        ]

        lines.append(contentsOf: systemInformationLines())
        if let timeContext = plan.timeContext {
            lines.append(contentsOf: [
                "",
                "Time Context",
                field("System Time", timeContext.actualSystemTime),
                field("Report Time", timeContext.effectiveDisplayTime),
                field("Report Zone", timeContext.effectiveTimeZone),
                field("Acquisition Start", displayTime(startedAt, context: timeContext)),
                field("Acquisition End", displayTime(endedAt, context: timeContext))
            ])
            if !timeline.isEmpty {
                lines.append("  Phase Timeline:")
                lines.append(contentsOf: compactTimeline(timeline).map { entry in
                    let start = displayTime(entry.startedAt, context: timeContext)
                    let end = entry.endedAt.map { displayTime($0, context: timeContext) } ?? "Not finished"
                    let duration = entry.endedAt.map { " (\(durationText($0.timeIntervalSince(entry.startedAt))))" } ?? ""
                    return "    \(entry.phase): \(start) -> \(end)\(duration)"
                })
            }
        }
        lines.append(contentsOf: [
            "",
            "Acquisition Information",
            field("Acquisition Type", "Filesystem acquisition"),
            field("Source", plan.sourcePath),
            field("Source Device", plan.sourceDeviceIdentifier ?? "Unknown"),
            field("Source Role", plan.sourceRoles.isEmpty ? "Unknown" : plan.sourceRoles.joined(separator: ", ")),
            field("Mount State", plan.sourceReadOnlyHint.map { $0 ? "Read-only" : "Writable" } ?? "Unknown"),
            field("Read-only", plan.requireReadOnly ? "Required" : plan.readOnlyCheckNotApplicable ? "Not applicable" : "Disabled"),
            field("Destination", plan.destinationPath),
            field("Started", plan.timeContext.map { displayTime(startedAt, context: $0) } ?? timestamp(startedAt)),
            field("Finished", plan.timeContext.map { displayTime(endedAt, context: $0) } ?? timestamp(endedAt)),
            field("Method", reportMethodLabel(plan.method)),
            field("Output Format", plan.outputFormat.label),
            field("Failed Dummies", plan.createFailedFilePlaceholders ? "Enabled" : "Disabled"),
            ""
        ])

        if !toolVersions.isEmpty {
            lines.append("Tool Versions")
            lines.append(contentsOf: toolVersions.keys.sorted().map { key in
                field(key, toolVersions[key] ?? "Unknown")
            })
            lines.append("")
        }

        if !commandLog.isEmpty {
            lines.append("Command Log")
            lines.append(contentsOf: commandLog.map { "  $ \($0)" })
            lines.append("")
        }

        lines.append("Image Result")
        lines.append(field("Image File", finalImage.path))
        lines.append(field("Image Size", fileSizeText(finalImage)))
        if hashes.isEmpty {
            lines.append(field("Hashes", "Not computed"))
        } else {
            lines.append(contentsOf: hashes.map { field($0.name, $0.value) })
        }

        if copyWarnings.isEmpty && failedCopies.isEmpty {
            lines.append("")
            lines.append("Acquisition Warnings: None")
        } else {
            lines.append("")
            lines.append("Acquisition Warnings:")
            lines.append(field("Copy warnings", "\(copyWarnings.count)"))
            if failedCopies.isEmpty {
                lines.append(field("Failed items", "0"))
            } else {
                let summary = failedCopySummary()
                lines.append(field("Failed items", "\(summary.totalItems) in \(failedCopies.count) group(s)"))
                lines.append(field("CSV", failedCopiesCSVFileName))
                lines.append("  Failed types:")
                lines.append(contentsOf: summary.byClassification.map { "    - \($0.classification): \($0.count)" })
            }
        }

        lines.append(separator)

        return lines.joined(separator: "\n") + "\n"
    }

    private func systemInformationLines() -> [String] {
        guard let profile = plan.systemProfile else {
            return ["Profile: Unknown"]
        }

        return [
            field("Device Name", unknownFallback(profile.computerName)),
            field("Model", unknownFallback(profile.modelName)),
            field("Model ID", unknownFallback(profile.modelIdentifier)),
            field("A-Number", unknownFallback(profile.appleModelNumber)),
            field("Order No.", unknownFallback(profile.modelNumber)),
            field("Serial Number", unknownFallback(profile.serialNumber)),
            field("macOS", unknownFallback(profile.osVersion)),
            field("Kernel", unknownFallback(profile.kernelVersion)),
            field("Architecture", unknownFallback(profile.architecture)),
            field("CPU / SoC", unknownFallback(profile.processorName)),
            field("CPU Cores", unknownFallback(profile.cpuCoreSummary)),
            field("Memory", profile.physicalMemoryBytes > 0 ? ByteCount.string(from: Int64(profile.physicalMemoryBytes)) : "Unknown"),
            field("Boot Context", unknownFallback(profile.bootContext)),
            field("Root Volume", profile.rootVolumeReadOnly.map { $0 ? "Read-only" : "Writable" } ?? "Unknown"),
            field("FileVault", unknownFallback(profile.unlockState.state)),
            field("FileVault Info", unknownFallback(profile.unlockState.detail))
        ]
    }

    private func failedCopiesCSVText() -> String {
        let rows = failedCopyCSVRows()
        let header = [
            "context",
            "exit_code",
            "classification",
            "reason",
            "path",
            "source_path",
            "tool",
            "raw_line"
        ].joined(separator: ",")
        guard !rows.isEmpty else { return header + "\n" }
        return ([header] + rows.map { row in
            [
                row.context,
                row.exitCode,
                row.classification,
                row.reason,
                row.path,
                row.sourcePath,
                row.tool,
                row.rawLine
            ].map(csvEscape).joined(separator: ",")
        }).joined(separator: "\n") + "\n"
    }

    private func failedCopyCSVRows() -> [FailedCopyCSVRow] {
        failedCopies.flatMap { entry -> [FailedCopyCSVRow] in
            let context = failedCopyValue(named: "Context", from: entry)
            let exitCode = failedCopyValue(named: "Exit code", from: entry)
            let classification = failedCopyClassification(from: entry)
            return failedCopyDetailLines(from: entry).map { line in
                let parsed = parseFailedCopyLine(line)
                return FailedCopyCSVRow(
                    context: context,
                    exitCode: exitCode,
                    classification: classification,
                    reason: parsed.reason,
                    path: parsed.path,
                    sourcePath: parsed.sourcePath,
                    tool: parsed.tool,
                    rawLine: line
                )
            }
        }
    }

    private func failedCopySummary() -> (totalItems: Int, byClassification: [(classification: String, count: Int)]) {
        var counts: [String: Int] = [:]
        var total = 0

        for entry in failedCopies {
            let classification = failedCopyClassification(from: entry)
            let itemCount = max(1, failedCopyDetailLines(from: entry).count)
            total += itemCount
            counts[classification, default: 0] += itemCount
        }

        let ordered = counts
            .map { (classification: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.classification.localizedStandardCompare($1.classification) == .orderedAscending
                }
                return $0.count > $1.count
            }
        return (total, ordered)
    }

    private func failedCopyClassification(from entry: String) -> String {
        failedCopyValue(named: "Classification", from: entry).isEmpty
            ? "Unclassified copy failure"
            : failedCopyValue(named: "Classification", from: entry)
    }

    private func failedCopyValue(named name: String, from entry: String) -> String {
        let prefix = "\(name):"
        return entry.components(separatedBy: .newlines)
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }

    private func failedCopyDetailLines(from entry: String) -> [String] {
        let lines = entry.components(separatedBy: .newlines)
        guard let detailsIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "Details:" }) else {
            return []
        }
        return lines[lines.index(after: detailsIndex)...]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "No command output captured." }
    }

    private func parseFailedCopyLine(_ line: String) -> (tool: String, path: String, sourcePath: String, reason: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = parseRsyncReadError(trimmed) {
            return parsed
        }
        if let parsed = parseRsyncVerificationError(trimmed) {
            return parsed
        }
        if let parsed = parseDittoError(trimmed) {
            return parsed
        }
        return ("unknown", "", "", trimmed)
    }

    private func parseRsyncReadError(_ line: String) -> (tool: String, path: String, sourcePath: String, reason: String)? {
        guard line.localizedCaseInsensitiveContains("rsync:"),
              line.localizedCaseInsensitiveContains("read errors mapping"),
              let firstQuote = line.firstIndex(of: "\""),
              let secondQuote = line[line.index(after: firstQuote)...].firstIndex(of: "\"") else {
            return nil
        }
        let sourcePath = String(line[line.index(after: firstQuote)..<secondQuote])
        let suffix = String(line[line.index(after: secondQuote)...])
        let reason = suffix
            .replacingOccurrences(of: ":", with: "", options: [], range: suffix.startIndex..<suffix.index(suffix.startIndex, offsetBy: min(1, suffix.count)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ("rsync", displayPath(fromSourcePath: sourcePath), sourcePath, reason.isEmpty ? "read errors mapping" : reason)
    }

    private func parseRsyncVerificationError(_ line: String) -> (tool: String, path: String, sourcePath: String, reason: String)? {
        guard line.hasPrefix("ERROR:"),
              let range = line.range(of: " failed verification -- update discarded") else {
            return nil
        }
        let path = String(line[line.index(line.startIndex, offsetBy: "ERROR:".count)..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ("rsync", path, path, "failed verification -- update discarded")
    }

    private func parseDittoError(_ line: String) -> (tool: String, path: String, sourcePath: String, reason: String)? {
        guard line.localizedCaseInsensitiveContains("ditto:") else { return nil }
        let withoutPrefix = line.replacingOccurrences(of: "ditto:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = withoutPrefix.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            return ("ditto", parts[0].trimmingCharacters(in: .whitespacesAndNewlines), parts[0].trimmingCharacters(in: .whitespacesAndNewlines), parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return ("ditto", "", "", withoutPrefix)
    }

    private func displayPath(fromSourcePath sourcePath: String) -> String {
        let prefixes = [
            "/Volumes/Data/",
            "/System/Volumes/Data/"
        ]
        for prefix in prefixes where sourcePath.hasPrefix(prefix) {
            return String(sourcePath.dropFirst(prefix.count))
        }
        return sourcePath
    }

    private func csvEscape(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private func safeName(_ value: String) -> String {
        SafeFileName.component(value)
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss 'UTC'"
        return formatter.string(from: date)
    }

    private func displayTime(_ date: Date, context: AcquisitionTimeContext) -> String {
        let shiftedDate = date.addingTimeInterval(context.displayReferenceDate.timeIntervalSince(context.actualReferenceDate))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: context.effectiveSecondsFromGMT)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(formatter.string(from: shiftedDate)) \(offsetText(seconds: context.effectiveSecondsFromGMT))"
    }

    private func offsetText(seconds: Int) -> String {
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute / 60) % 60
        if minutes == 0 {
            return "UTC\(sign)\(hours)"
        }
        return "UTC\(sign)\(hours):\(String(format: "%02d", minutes))"
    }

    private func compactTimeline(_ entries: [AcquisitionTimelineEntry]) -> [AcquisitionTimelineEntry] {
        let wanted = ["Copy source", "DMG conversion", "Final image copy", "Hash output"]
        return wanted.compactMap { phase in
            entries.last { $0.phase == phase }
        }
    }

    private func durationText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded()))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private func notFilledFallback(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "<not filled out>" : trimmed
    }

    private func unknownFallback(_ value: String?) -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return "Unknown"
        }
        return trimmed
    }

    private func field(_ name: String, _ value: String) -> String {
        "  \(name):\(String(repeating: " ", count: max(1, 15 - name.count)))\(value)"
    }

    private func reportMethodLabel(_ method: AcquisitionMethod) -> String {
        switch method {
        case .rsync: return "rsync copy"
        case .ditto: return "ditto copy"
        }
    }

    private func appVersionText() -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        let safeVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? version! : "0.1"
        if let build, !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, build != safeVersion {
            return "\(safeVersion) (\(build))"
        }
        return safeVersion
    }

    private func parsedHashes(from text: String) -> [(name: String, value: String)] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }

    private func fileSizeText(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value ?? attributes[.size] as? Int64 else {
            return "Unknown"
        }
        return "\(ByteCount.string(from: size)) (\(size) bytes)"
    }
}
