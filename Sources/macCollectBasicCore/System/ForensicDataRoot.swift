import Foundation

public enum ForensicDataRoot {
    private static var cachedCurrentURL: URL?

    public static var isRecoveryEnvironment: Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: "/System/Installation") ||
            fileManager.fileExists(atPath: "/Applications/Utilities/Recovery Assistant.app") ||
            fileManager.fileExists(atPath: "/System/Volumes/Data/private/tmp/Recovery") ||
            fileManager.fileExists(atPath: "/private/tmp/Recovery")
    }

    public static func resetCache() {
        cachedCurrentURL = nil
    }

    public static func current() -> URL {
        if let cachedCurrentURL {
            return cachedCurrentURL
        }

        let resolved = resolveCurrent()
        cachedCurrentURL = resolved
        return resolved
    }

    private static func resolveCurrent() -> URL {
        let fileManager = FileManager.default

        if isRecoveryEnvironment {
            if fileManager.fileExists(atPath: "/Volumes/Data/Users") {
                return URL(fileURLWithPath: "/Volumes/Data", isDirectory: true)
            }

            let dataCandidates = RecoverySourceScanner.scan().filter {
                $0.roles.contains("Data") && $0.locked != true && $0.mountPoint?.isEmpty == false
            }
            if let mountedData = dataCandidates.first(where: { $0.mountPoint?.hasPrefix("/Volumes/") == true })?.mountPoint {
                return URL(fileURLWithPath: mountedData, isDirectory: true)
            }
        }

        if fileManager.fileExists(atPath: "/System/Volumes/Data/Users") {
            return URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        }

        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    public static func resolve(_ absolutePath: String) -> URL {
        let dataRoot = current()
        guard dataRoot.path != "/" else {
            return URL(fileURLWithPath: absolutePath)
        }

        if absolutePath == "/var" || absolutePath.hasPrefix("/var/") {
            let relative = "private/" + absolutePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return dataRoot.appendingPathComponent(relative)
        }

        if absolutePath == "/etc" || absolutePath.hasPrefix("/etc/") {
            let relative = "private/" + absolutePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return dataRoot.appendingPathComponent(relative)
        }

        let prefixes = ["/Users", "/Library", "/Applications", "/private"]
        guard prefixes.contains(where: { absolutePath == $0 || absolutePath.hasPrefix($0 + "/") }) else {
            return URL(fileURLWithPath: absolutePath)
        }

        let relative = absolutePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return dataRoot.appendingPathComponent(relative)
    }
}
