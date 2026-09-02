import Foundation
#if canImport(SQLite3)
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
#endif

public enum FullDiskAccessState: String {
    case granted
    case denied
    case notListed
    case unreadable
    case unavailable

    public var label: String {
        switch self {
        case .granted: return "Granted"
        case .denied: return "Denied"
        case .notListed: return "Not listed"
        case .unreadable: return "Not granted"
        case .unavailable: return "Unavailable"
        }
    }
}

public struct FullDiskAccessStatus {
    public let state: FullDiskAccessState
    public let bundleIdentifier: String
    public let authValue: Int?
    public let lastModified: Date?
    public let detail: String
    public let source: String

    public var isGranted: Bool {
        state == .granted
    }
}

public enum FullDiskAccessChecker {
    public static let tccDatabasePath = "/Library/Application Support/com.apple.TCC/TCC.db"
    private static let service = "kTCCServiceSystemPolicyAllFiles"

    public static func currentStatus(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> FullDiskAccessStatus {
        let identifier = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identifier, !identifier.isEmpty else {
            return FullDiskAccessStatus(
                state: .unavailable,
                bundleIdentifier: "Unknown",
                authValue: nil,
                lastModified: nil,
                detail: "The app bundle identifier could not be determined.",
                source: tccDatabasePath
            )
        }

        #if canImport(SQLite3)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        let openResult = sqlite3_open_v2(tccDatabasePath, &database, flags, nil)
        guard openResult == SQLITE_OK, let database else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map(String.init(cString:)) ?? "open failed"
            if let database {
                sqlite3_close(database)
            }
            return FullDiskAccessStatus(
                state: .unreadable,
                bundleIdentifier: identifier,
                authValue: nil,
                lastModified: nil,
                detail: "Could not read the system TCC database directly: \(message). This usually means Full Disk Access is not active for this app.",
                source: tccDatabasePath
            )
        }
        defer { sqlite3_close(database) }

        let query = """
        SELECT auth_value, last_modified
        FROM access
        WHERE service = ? AND client = ?
        ORDER BY last_modified DESC
        LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(database))
            return FullDiskAccessStatus(
                state: .unreadable,
                bundleIdentifier: identifier,
                authValue: nil,
                lastModified: nil,
                detail: "Could not query the system TCC database: \(message).",
                source: tccDatabasePath
            )
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, service, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, identifier, -1, SQLITE_TRANSIENT)

        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW else {
            return FullDiskAccessStatus(
                state: .notListed,
                bundleIdentifier: identifier,
                authValue: nil,
                lastModified: nil,
                detail: "\(identifier) has no Full Disk Access entry in the system TCC database.",
                source: tccDatabasePath
            )
        }

        let authValue = Int(sqlite3_column_int(statement, 0))
        let modifiedRaw = sqlite3_column_int64(statement, 1)
        let modified = modifiedRaw > 0 ? Date(timeIntervalSince1970: TimeInterval(modifiedRaw)) : nil
        let state: FullDiskAccessState = authValue == 2 ? .granted : .denied
        let detail = authValue == 2
            ? "\(identifier) is allowed for \(service)."
            : "\(identifier) is listed for \(service), but auth_value is \(authValue), not 2."

        return FullDiskAccessStatus(
            state: state,
            bundleIdentifier: identifier,
            authValue: authValue,
            lastModified: modified,
            detail: detail,
            source: tccDatabasePath
        )
        #else
        return FullDiskAccessStatus(
            state: .unavailable,
            bundleIdentifier: identifier,
            authValue: nil,
            lastModified: nil,
            detail: "SQLite3 is unavailable in this build.",
            source: tccDatabasePath
        )
        #endif
    }
}
