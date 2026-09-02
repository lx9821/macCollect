import Foundation

public enum ForensicToolLocator {
    public static func resolve(_ name: String) -> String? {
        for path in candidatePaths(for: name) where FileManager.default.isExecutableFile(atPath: path) {
            if let result = try? CommandRunner.run(path, arguments: ["--version"], timeoutSeconds: 4),
               result.exitCode == 0 {
                return path
            }
        }
        return nil
    }

    private static func candidatePaths(for name: String) -> [String] {
        var paths: [String] = []
        if let resources = Bundle.main.resourceURL {
            paths.append(resources.appendingPathComponent("Tools/macos-arm64/\(name)").path)
            paths.append(resources.appendingPathComponent("Tools/\(name)").path)
        }
        paths.append(contentsOf: [
            "/usr/bin/\(name)",
            "/bin/\(name)",
            "/sbin/\(name)",
            "/usr/sbin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)"
        ])
        return paths
    }
}
