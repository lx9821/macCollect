import Foundation

public enum ByteCount {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    public static func string(from bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }
}

public enum SafeFileName {
    public static func component(_ value: String, allowingSpaces: Bool = false, fallback: String = "macCollect_Acquisition") -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_." + (allowingSpaces ? " " : ""))
        var result = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        if allowingSpaces {
            result = result.replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " ._-"))
        return result.isEmpty ? fallback : result
    }
}
