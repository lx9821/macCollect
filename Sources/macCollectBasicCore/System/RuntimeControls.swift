import Foundation

public enum WirelessManager {
    public static func disableWiFi() -> String {
        let devices = wifiDisableTargets()

        var actions: [String] = []
        var failures: [String] = []
        if let airportMessage = disassociateAirport() {
            actions.append(airportMessage)
        }

        for device in devices {
            if let result = try? CommandRunner.run(
                "/usr/sbin/networksetup",
                arguments: ["-setairportpower", device, "off"],
                timeoutSeconds: 8
            ) {
                let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
                if result.exitCode == 0 {
                    actions.append("Wi-Fi power off on \(device).")
                } else if !isExpectedMissingNetworkService(output) {
                    failures.append("\(device): \(output.isEmpty ? "networksetup failed" : output)")
                }
            } else {
                failures.append("\(device): networksetup could not be started")
            }
            if device.hasPrefix("en") {
                switch interfaceDownMessage(device) {
                case .success(let message):
                    actions.append(message)
                case .ignored:
                    break
                case .failure(let message):
                    failures.append(message)
                }
            }
        }
        if !actions.isEmpty {
            let suffix = failures.isEmpty ? "" : " Some fallback attempts did not apply: \(failures.joined(separator: "; "))."
            return "\(actions.joined(separator: " "))\(suffix)"
        }
        if failures.isEmpty {
            return "No Wi-Fi hardware service detected."
        }
        return "Wi-Fi disable attempted, but no known Wi-Fi service could be changed. \(failures.joined(separator: "; "))"
    }

    private enum InterfaceDownResult {
        case success(String)
        case ignored
        case failure(String)
    }

    private static func interfaceDownMessage(_ device: String) -> InterfaceDownResult {
        guard let result = try? CommandRunner.run("/sbin/ifconfig", arguments: [device, "down"], timeoutSeconds: 5) else {
            return .failure("\(device): ifconfig could not be started")
        }
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0 {
            return .success("\(device) interface down.")
        }
        if isExpectedMissingInterface(output) {
            return .ignored
        }
        return .failure(output.isEmpty ? "\(device): could not bring interface down" : "\(device): \(output)")
    }

    private static func wifiDisableTargets() -> [String] {
        var targets = wifiDevices()
        targets.append(contentsOf: ["Wi-Fi", "AirPort", "en0", "en1", "en2"])
        var seen = Set<String>()
        return targets.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func isExpectedMissingNetworkService(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("is not a wi-fi interface") ||
            lower.contains("is not an airport interface") ||
            lower.contains("not a recognized airport") ||
            lower.contains("network service was not found") ||
            lower.contains("does not exist")
    }

    private static func isExpectedMissingInterface(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("interface") && lower.contains("does not exist")
    }

    private static func disassociateAirport() -> String? {
        let paths = [
            "/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport",
            "/usr/sbin/airport"
        ]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return nil
        }
        guard let result = try? CommandRunner.run(path, arguments: ["-z"], timeoutSeconds: 5) else {
            return "Could not start airport disassociation."
        }
        let output = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0 {
            return "Wi-Fi disassociated via airport."
        }
        return output.isEmpty ? "airport disassociation failed." : "airport disassociation failed: \(output)"
    }

    private static func wifiDevices() -> [String] {
        guard let result = try? CommandRunner.run(
            "/usr/sbin/networksetup",
            arguments: ["-listallhardwareports"],
            timeoutSeconds: 5
        ) else {
            return []
        }

        let lines = result.stdout.split(separator: "\n").map(String.init)
        var devices: [String] = []
        var currentIsWiFi = false

        for line in lines {
            if line.hasPrefix("Hardware Port:") {
                let value = line.replacingOccurrences(of: "Hardware Port:", with: "").trimmingCharacters(in: .whitespaces)
                currentIsWiFi = value.localizedCaseInsensitiveContains("wi-fi") ||
                    value.localizedCaseInsensitiveContains("airport")
            } else if currentIsWiFi, line.hasPrefix("Device:") {
                let device = line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces)
                if !device.isEmpty {
                    devices.append(device)
                }
            }
        }

        return devices
    }
}

public enum ShutdownManager {
    public static func shutdownNow() -> CommandResult {
        let command = "/sbin/shutdown -h now"
        if FileManager.default.isExecutableFile(atPath: "/sbin/shutdown"),
           let result = try? CommandRunner.run("/sbin/shutdown", arguments: ["-h", "now"], timeoutSeconds: 5) {
            return result
        }

        let script = "do shell script \(appleScriptQuote(command)) with administrator privileges"
        if let result = try? CommandRunner.run("/usr/bin/osascript", arguments: ["-e", script], timeoutSeconds: 45) {
            return result
        }

        return CommandResult(exitCode: 1, stdout: "", stderr: "Could not execute shutdown command.")
    }

    private static func appleScriptQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

public enum RuntimePrivilege {
    public static var isRunningAsRoot: Bool { geteuid() == 0 }
    public static var statusText: String {
        isRunningAsRoot ? "root (uid 0)" : "user uid \(geteuid())"
    }
}
