import CryptoKit
import Foundation
import SQLite3

struct ClipItem: Identifiable, Equatable {
    enum Kind: String {
        case text
        case file
        case image
    }

    let id: Int64
    let kind: Kind
    /// The text itself, newline-separated file paths, or an image's file name in `imagesDirectory`.
    let content: String
    let sourceApp: String
    let lastUsed: Date
}

/// SQLite-backed history, newest first. Identical content is stored once and moves to the top.
@MainActor
final class ClipboardStore {
    private enum Bind {
        case text(String)
        case real(Double)
        case int(Int64)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Copied images live here as PNG files, named after their content hash.
    nonisolated static let imagesDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UnifiedTools/images", isDirectory: true)

    private var db: OpaquePointer?

    init?() {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UnifiedTools", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.imagesDirectory, withIntermediateDirectories: true)

        let path = directory.appendingPathComponent("clipboard.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }

        let schema = """
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL,
            content TEXT NOT NULL,
            hash TEXT NOT NULL UNIQUE,
            source_app TEXT NOT NULL,
            last_used REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS items_last_used ON items(last_used DESC);
        """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
    }

    deinit {
        sqlite3_close(db)
    }

    func add(kind: ClipItem.Kind, content: String, sourceApp: String, limit: Int) {
        run(
            """
            INSERT INTO items (kind, content, hash, source_app, last_used) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(hash) DO UPDATE SET last_used = excluded.last_used, source_app = excluded.source_app
            """,
            [
                .text(kind.rawValue),
                .text(content),
                .text(Self.hash(kind, content)),
                .text(sourceApp),
                .real(Date().timeIntervalSince1970),
            ]
        )
        trim(to: limit)
    }

    func items(matching query: String, limit: Int = 200) -> [ClipItem] {
        var sql = "SELECT id, kind, content, source_app, last_used FROM items"
        var binds: [Bind] = []
        if !query.isEmpty {
            // Image rows hold a hash as their content, which must not match what the user types.
            sql += " WHERE kind != 'image' AND content LIKE ? ESCAPE '\\'"
            binds.append(.text("%" + Self.escapeLike(query) + "%"))
        }
        sql += " ORDER BY last_used DESC LIMIT ?"
        binds.append(.int(Int64(limit)))

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)

        var result: [ClipItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let kind = ClipItem.Kind(rawValue: column(stmt, 1)) else { continue }
            result.append(ClipItem(
                id: sqlite3_column_int64(stmt, 0),
                kind: kind,
                content: column(stmt, 2),
                sourceApp: column(stmt, 3),
                lastUsed: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
            ))
        }
        return result
    }

    func touch(_ id: Int64) {
        run("UPDATE items SET last_used = ? WHERE id = ?", [.real(Date().timeIntervalSince1970), .int(id)])
    }

    func clear() {
        let images = strings("SELECT content FROM items WHERE kind = 'image'")
        run("DELETE FROM items")
        removeImageFiles(images)
    }

    private func trim(to limit: Int) {
        let keep = "SELECT id FROM items ORDER BY last_used DESC LIMIT ?"
        let images = strings(
            "SELECT content FROM items WHERE kind = 'image' AND id NOT IN (\(keep))",
            [.int(Int64(limit))]
        )
        run("DELETE FROM items WHERE id NOT IN (\(keep))", [.int(Int64(limit))])
        removeImageFiles(images)
    }

    private func removeImageFiles(_ names: [String]) {
        for name in names {
            try? FileManager.default.removeItem(at: Self.imagesDirectory.appendingPathComponent(name))
        }
    }

    // MARK: - SQLite helpers

    @discardableResult
    private func run(_ sql: String, _ binds: [Bind] = []) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func strings(_ sql: String, _ binds: [Bind] = []) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, binds)
        var result: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            result.append(column(stmt, 0))
        }
        return result
    }

    private func bind(_ stmt: OpaquePointer?, _ binds: [Bind]) {
        for (offset, value) in binds.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(stmt, index, text, -1, Self.transient)
            case .real(let number): sqlite3_bind_double(stmt, index, number)
            case .int(let number): sqlite3_bind_int64(stmt, index, number)
            }
        }
    }

    private func column(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: text)
    }

    private static func hash(_ kind: ClipItem.Kind, _ content: String) -> String {
        let digest = SHA256.hash(data: Data((kind.rawValue + "\u{0}" + content).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func escapeLike(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
