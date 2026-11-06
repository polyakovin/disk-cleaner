import Foundation
import Darwin
import CSQLite

public enum FileTreeOrder: String, CaseIterable, Sendable {
    case sizeDescending = "Largest First", sizeAscending = "Smallest First", name = "By Name"
}

public struct FileTreePage: Sendable {
    public var folder: DiskEntry
    public var entries: [DiskEntry]
    public var total: Int
}

struct IndexedEntry {
    var entry: DiskEntry
    var identity: FolderIdentity
    var items: Int
    var reusable: Bool
}

enum FileTreeFailure: LocalizedError {
    case database(String), obsolete
    var errorDescription: String? {
        switch self {
        case .database(let reason): return "Could not update the file index: \(reason)"
        case .obsolete: return "The index update was superseded by a new scan."
        }
    }
}

/// Complete metadata lives on disk. UI queries one page; reports remain bounded.
/// One serialized connection also makes a new scan revoke every obsolete writer.
public final class FileTreeStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private var pendingWrites = 0
    private var activeToken: String?
    private let directory: URL
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(directory: URL) throws {
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = directory.appendingPathComponent("file-tree.sqlite")
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let reason = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite is unavailable"
            if let database { sqlite3_close(database) }; database = nil
            throw FileTreeFailure.database(reason)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        sqlite3_busy_timeout(database, 5000)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=NORMAL")
        try execute("CREATE TABLE IF NOT EXISTS entries(path TEXT PRIMARY KEY, parent TEXT NOT NULL, name TEXT NOT NULL, folded TEXT NOT NULL, kind TEXT NOT NULL, allocated INTEGER NOT NULL, logical INTEGER NOT NULL, files INTEGER NOT NULL, issues INTEGER NOT NULL, children INTEGER NOT NULL, known INTEGER NOT NULL, identity BLOB NOT NULL, items INTEGER NOT NULL, reusable INTEGER NOT NULL, seen TEXT NOT NULL) WITHOUT ROWID")
        try execute("CREATE INDEX IF NOT EXISTS entries_parent_size ON entries(parent, allocated DESC, folded, path)")
        try execute("CREATE INDEX IF NOT EXISTS entries_parent_name ON entries(parent, folded, path)")
        try execute("CREATE INDEX IF NOT EXISTS entries_kind_size ON entries(kind, allocated DESC, path)")
        try execute("CREATE TABLE IF NOT EXISTS roots(path TEXT PRIMARY KEY, uuid TEXT, event TEXT) WITHOUT ROWID")
        try execute("CREATE TABLE IF NOT EXISTS dirty(path TEXT PRIMARY KEY) WITHOUT ROWID")
        try execute("CREATE TABLE IF NOT EXISTS dirty_ancestors(path TEXT PRIMARY KEY) WITHOUT ROWID")
        try normalizeLegacyPaths()
        // WAL/SHM inherit the private directory, and are private themselves too.
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: file.path + suffix) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path + suffix)
        }
    }
    deinit {
        if pendingWrites > 0 { try? execute("COMMIT") }
        for statement in statements.values { sqlite3_finalize(statement) }
        if let database { sqlite3_close(database) }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> FileTreeFailure { .database(String(cString: sqlite3_errmsg(database))) }
    private func statement(_ sql: String, _ values: [Any] = []) throws -> OpaquePointer {
        let value: OpaquePointer
        if let cached = statements[sql] { value = cached; sqlite3_reset(value); sqlite3_clear_bindings(value) }
        else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
            statements[sql] = prepared; value = prepared
        }
        for (index, item) in values.enumerated() {
            let position = Int32(index + 1)
            if let data = item as? Data {
                _ = data.withUnsafeBytes { sqlite3_bind_blob(value, position, $0.baseAddress, Int32(data.count), transient) }
            } else if let number = item as? Int64 { sqlite3_bind_int64(value, position, number) }
            else if let number = item as? Int { sqlite3_bind_int64(value, position, Int64(number)) }
            else if let text = item as? String {
                // Foundation's parent URLs and POSIX directory names can have
                // canonically equivalent but byte-distinct Unicode spellings.
                sqlite3_bind_text(value, position, text.precomposedStringWithCanonicalMapping, -1, transient)
            }
            else { sqlite3_bind_null(value, position) }
        }
        return value
    }
    private func change(_ sql: String, _ values: [Any] = []) throws {
        let value = try statement(sql, values)
        defer { sqlite3_reset(value) }
        guard sqlite3_step(value) == SQLITE_DONE else { throw failure() }
    }
    private func normalizeLegacyPaths() throws {
        let version = try statement("PRAGMA user_version")
        guard sqlite3_step(version) == SQLITE_ROW else { sqlite3_reset(version); throw failure() }
        let current = sqlite3_column_int(version, 0); sqlite3_reset(version)
        guard current == 0 else { return }
        let flags = SQLITE_UTF8 | SQLITE_DETERMINISTIC
        guard sqlite3_create_function_v2(database, "disklens_nfc", 1, flags, nil, { context, count, arguments in
            guard count == 1, let argument = arguments?[0], let bytes = sqlite3_value_text(argument) else {
                sqlite3_result_null(context); return
            }
            let normalized = String(cString: bytes).precomposedStringWithCanonicalMapping
            sqlite3_result_text(context, normalized, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }, nil, nil, nil) == SQLITE_OK else { throw failure() }
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("CREATE TABLE entries_nfc AS SELECT * FROM entries WHERE 0")
            try execute("CREATE UNIQUE INDEX entries_nfc_path ON entries_nfc(path)")
            try execute("INSERT OR REPLACE INTO entries_nfc SELECT disklens_nfc(path),disklens_nfc(parent),disklens_nfc(name),disklens_nfc(folded),kind,allocated,logical,files,issues,children,known,identity,items,0,seen FROM entries ORDER BY known,items,allocated")
            // Keep the original schema and constraints, replacing data in place.
            try execute("DELETE FROM entries")
            try execute("INSERT INTO entries SELECT * FROM entries_nfc")
            try execute("DROP TABLE entries_nfc")
            try execute("DELETE FROM roots")
            try execute("DELETE FROM dirty")
            try execute("DELETE FROM dirty_ancestors")
            try execute("PRAGMA user_version=1")
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }
    private func rows(_ sql: String, _ values: [Any] = []) throws -> [IndexedEntry] {
        let value = try statement(sql, values)
        defer { sqlite3_reset(value) }
        var result: [IndexedEntry] = []
        while true {
            let status = sqlite3_step(value)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            func string(_ col: Int32) -> String { String(cString: sqlite3_column_text(value, col)) }
            func int(_ col: Int32) -> Int64 { sqlite3_column_int64(value, col) }
            let data = Data(bytes: sqlite3_column_blob(value, 9), count: Int(sqlite3_column_bytes(value, 9)))
            var entry = DiskEntry(path: string(0), kind: EntryKind(rawValue: string(1)) ?? .file,
                                  allocatedBytes: int(2), logicalBytes: int(3), fileCount: Int(int(4)),
                                  issueCount: Int(int(5)), childCount: Int(int(6)), children: [])
            entry.sizeIsKnown = int(7) != 0
            result.append(IndexedEntry(entry: entry, identity: try JSONDecoder().decode(FolderIdentity.self, from: data),
                                       items: Int(int(8)), reusable: int(10) != 0))
        }
    }
    private let columns = "path,kind,allocated,logical,files,issues,children,known,items,identity,reusable"
    private func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "ru_RU")) }
    private func batch() throws {
        if pendingWrites == 0 { try execute("BEGIN IMMEDIATE") }
        pendingWrites += 1
    }
    func flush() throws {
        lock.lock(); defer { lock.unlock() }
        if pendingWrites > 0 { try execute("COMMIT"); pendingWrites = 0 }
    }
    private func check(_ token: String) throws {
        guard activeToken == token else { throw FileTreeFailure.obsolete }
    }
    func cursor(_ root: String) throws -> (uuid: String, event: UInt64)? {
        lock.lock(); defer { lock.unlock() }
        let value = try statement("SELECT uuid,event FROM roots WHERE uuid IS NOT NULL AND event IS NOT NULL AND (path=? OR (? >= path || '/' AND ? < path || '0') OR path='/') ORDER BY length(path) DESC LIMIT 1", [root, root, root])
        defer { sqlite3_reset(value) }
        guard sqlite3_step(value) == SQLITE_ROW, let uuid = sqlite3_column_text(value, 0), let event = sqlite3_column_text(value, 1),
              let id = UInt64(String(cString: event)), id > 0, id < UInt64.max else { return nil }
        return (String(cString: uuid), id)
    }
    public func hasContinuousHistory(_ root: String) -> Bool { (try? cursor(root)) != nil }
    func begin(_ root: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        try flush()
        let token = UUID().uuidString; activeToken = token
        // A crash/cancellation must never leave a trusted cursor for half an update.
        try change("UPDATE roots SET uuid=NULL,event=NULL WHERE \(subtree)", bounds(root))
        try change("INSERT OR IGNORE INTO dirty VALUES(?)", [root])
        // Ancestor totals will need adjustment after a separately measured child.
        // Their earlier journal cursor still covers all filesystem changes.
        var parent = root
        while parent != "/" {
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            try change("INSERT OR IGNORE INTO dirty_ancestors VALUES(?)", [parent])
        }
        return token
    }
    func finish(_ root: String, journal: JournalSnapshot?, token: String) throws {
        lock.lock(); defer { lock.unlock() }
        try check(token); try flush()
        if let journal {
            try change("INSERT OR REPLACE INTO roots VALUES(?,?,?)", [root, journal.uuid, String(journal.eventID)])
        }
        try change("DELETE FROM dirty WHERE \(subtree)", bounds(root))
        try change("DELETE FROM dirty_ancestors WHERE \(subtree)", bounds(root))
    }
    func node(_ path: String) throws -> IndexedEntry? {
        lock.lock(); defer { lock.unlock() }
        return try rows("SELECT \(columns) FROM entries WHERE path=?", [path]).first
    }
    func put(_ node: IndexedEntry, token: String) throws {
        lock.lock(); defer { lock.unlock() }
        try check(token); try batch()
        // A directory replaced by a file/link or another inode loses its old descendants.
        if !node.entry.isFolder, let old = try self.node(node.entry.path), old.entry.isFolder {
            try removeTree(node.entry.path)
        }
        try write(node, seen: token)
        if pendingWrites >= 256 { try flush() }
    }
    func replaceDirectoryIfNeeded(_ path: String, identity: FolderIdentity, token: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        try check(token)
        guard let old = try node(path), old.entry.isFolder,
              old.identity.device != identity.device || old.identity.inode != identity.inode else { return false }
        try batch(); try removeTree(path)
        return true
    }
    private func write(_ node: IndexedEntry, seen: String, onlyNew: Bool = false) throws {
        let entry = node.entry
        let parent = entry.path == "/" ? "" : URL(fileURLWithPath: entry.path).deletingLastPathComponent().path
        let action = onlyNew ? "INSERT OR IGNORE" : "INSERT OR REPLACE"
        try change("\(action) INTO entries VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                   [entry.path, parent, entry.name, fold(entry.name), entry.kind.rawValue, entry.allocatedBytes,
                    entry.logicalBytes, entry.fileCount, entry.issueCount, entry.childCount, entry.sizeIsKnown == false ? 0 : 1,
                    try JSONEncoder().encode(node.identity), node.items, node.reusable ? 1 : 0, seen])
    }
    func touch(_ path: String, token: String) throws {
        lock.lock(); defer { lock.unlock() }
        try check(token); try batch(); try change("UPDATE entries SET seen=? WHERE path=?", [token, path])
        if pendingWrites >= 256 { try flush() }
    }
    /// Reconcile only a successfully enumerated directory, including removed subtrees.
    func reconcile(_ path: String, token: String) throws {
        lock.lock(); defer { lock.unlock() }
        try check(token)
        while true {
            let removed = try rows("SELECT \(columns) FROM entries WHERE parent=? AND seen<>? LIMIT 256", [path, token])
            if removed.isEmpty { return }
            try batch()
            for child in removed { try removeTree(child.entry.path) }
            try flush()
        }
    }
    private func bounds(_ path: String) -> [Any] { [path, path == "/" ? "/" : path + "/", path == "/" ? "0" : path + "0"] }
    private let subtree = "(path=? OR (path>=? AND path<?))"
    private func removeTree(_ path: String) throws { try change("DELETE FROM entries WHERE \(subtree)", bounds(path)) }

    func summary(_ path: String, depth: Int, limit: Int) throws -> DiskEntry? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = try node(path)?.entry else { return nil }
        if depth > 0 {
            entry.children = try rows("SELECT \(columns) FROM entries WHERE parent=? ORDER BY allocated DESC,folded,path LIMIT ?", [path, limit]).map {
                try summary($0.entry.path, depth: depth - 1, limit: limit) ?? $0.entry
            }
        }
        return entry
    }
    func largestFiles(_ path: String, limit: Int) throws -> [DiskEntry] {
        lock.lock(); defer { lock.unlock() }
        return try rows("SELECT \(columns) FROM entries WHERE \(subtree) AND kind='file' AND allocated>0 ORDER BY allocated DESC,path LIMIT ?", bounds(path) + [limit]).map(\.entry)
    }
    func candidateFolders(_ path: String) throws -> [DiskEntry] {
        lock.lock(); defer { lock.unlock() }
        let suffixes = ["/Library/Caches", "/.npm/_cacache", "/.npm/_npx", "/.gradle/caches", "/Library/Developer/Xcode/DerivedData", "/CapCut/User Data/Cache", "/.cache/uv", "/.cache/pip"]
        let filter = suffixes.map { _ in "substr(path,-length(?))=?" }.joined(separator: " OR ")
        return try rows("SELECT \(columns) FROM entries WHERE \(subtree) AND kind='folder' AND issues=0 AND known=1 AND (\(filter))", bounds(path) + suffixes.flatMap { [$0, $0] }).map(\.entry)
    }

    /// Discover immediate names even outside measured roots. Never reads contents,
    /// follows links, or overwrites an existing measurement with an unknown size.
    public func discover(_ url: URL, cancellation: CancellationFlag = .init()) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let directory = opendir(path) else { throw ScanFailure.invalidRoot(path) }
        defer { closedir(directory) }
        func insert(_ path: String) throws {
            var info = stat(); guard lstat(path, &info) == 0 else { return }
            let mode = info.st_mode & S_IFMT
            let kind: EntryKind = mode == S_IFDIR ? .folder : mode == S_IFLNK ? .symlink : .file
            var entry = DiskEntry(path: path, kind: kind, allocatedBytes: kind == .folder ? 0 : max(0, Int64(info.st_blocks) * 512),
                                  logicalBytes: kind == .file ? max(0, Int64(info.st_size)) : 0,
                                  fileCount: kind == .file ? 1 : 0, issueCount: 0, childCount: 0, children: [])
            entry.sizeIsKnown = kind != .folder
            lock.lock(); defer { lock.unlock() }
            try batch()
            try write(IndexedEntry(entry: entry, identity: FolderIdentity(info), items: 1, reusable: false), seen: "discovered", onlyNew: true)
            if pendingWrites >= 256 { try flush() }
        }
        try insert(path)
        while !cancellation.isCancelled, let item = readdir(directory) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { try insert(path == "/" ? "/" + name : path + "/" + name) }
        }
        try flush()
    }

    public func discoverIfNeeded(_ url: URL, cancellation: CancellationFlag = .init()) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        lock.lock()
        do {
            if let folder = try node(path), folder.entry.sizeIsKnown != false {
                let count = try statement("SELECT count(*) FROM entries WHERE parent=?", [path])
                let complete = sqlite3_step(count) == SQLITE_ROW && Int(sqlite3_column_int64(count, 0)) == folder.entry.childCount
                sqlite3_reset(count)
                if complete { lock.unlock(); return }
            }
            lock.unlock()
        } catch { lock.unlock(); throw error }
        try discover(url, cancellation: cancellation)
    }

    public func seed(_ report: DiskReport) throws {
        func visit(_ entry: DiskEntry) throws {
            var info = stat(); guard lstat(entry.path, &info) == 0 else { return }
            lock.lock()
            do {
                // Discovery may have inserted an unknown folder before migration.
                // Upgrade that placeholder, but preserve every actual newer measurement.
                if try node(entry.path)?.entry.sizeIsKnown != true {
                    try batch()
                    try write(IndexedEntry(entry: entry, identity: FolderIdentity(info), items: 1, reusable: false), seen: "imported")
                    if pendingWrites >= 256 { try flush() }
                }
                lock.unlock()
            } catch { lock.unlock(); throw error }
            for child in entry.children { try visit(child) }
        }
        try visit(report.root); try flush()
    }

    public func invalidate(_ paths: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        try flush()
        for path in paths { try change("INSERT OR IGNORE INTO dirty VALUES(?)", [path]) }
    }
    func changes(_ journal: JournalSnapshot?, root: String) throws -> [JournalChange] {
        lock.lock(); defer { lock.unlock() }
        let value = try statement("SELECT path FROM dirty WHERE \(subtree)", bounds(root))
        defer { sqlite3_reset(value) }
        func logical(_ path: String) -> String {
            let data = "/System/Volumes/Data"
            return ScanInvalidation.contains(path, in: data) ? String(path.dropFirst(data.count)).isEmpty ? "/" : String(path.dropFirst(data.count)) : path
        }
        var changes = (journal?.changes ?? []).filter { !ScanInvalidation.contains(logical($0.path), in: logical(directory.path)) }
        while sqlite3_step(value) == SQLITE_ROW {
            changes.append(JournalChange(path: String(cString: sqlite3_column_text(value, 0)), recursive: true))
        }
        sqlite3_reset(value)
        let ancestors = try statement("SELECT path FROM dirty_ancestors WHERE \(subtree)", bounds(root))
        defer { sqlite3_reset(ancestors) }
        while sqlite3_step(ancestors) == SQLITE_ROW {
            changes.append(JournalChange(path: String(cString: sqlite3_column_text(ancestors, 0)), recursive: false))
        }
        return changes
    }

    public func containsMeasurement(_ path: String, root: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard ScanInvalidation.contains(path, in: root) else { return false }
        guard let folder = try node(path), let top = try node(root) else { return path == root }
        return folder.identity.device == top.identity.device
    }

    public func page(_ path: String, order: FileTreeOrder = .sizeDescending, search: String = "", kind: EntryKind? = nil,
                     limit: Int = 500, offset: Int = 0) throws -> FileTreePage? {
        lock.lock(); defer { lock.unlock() }
        guard var folder = try node(path)?.entry else { return nil }
        let filter = "parent=? AND instr(folded,?)>0" + (kind == nil ? "" : " AND kind=?")
        var values: [Any] = [path, fold(search)]
        if let kind { values.append(kind.rawValue) }
        let count = try statement("SELECT count(*) FROM entries WHERE \(filter)", values)
        guard sqlite3_step(count) == SQLITE_ROW else { sqlite3_reset(count); throw failure() }
        let total = Int(sqlite3_column_int64(count, 0)); sqlite3_reset(count)
        let sorting: String
        switch order {
        case .sizeDescending: sorting = "known DESC,allocated DESC,folded,path"
        case .sizeAscending: sorting = "known DESC,allocated ASC,folded,path"
        case .name: sorting = "folded,path"
        }
        let entries = try rows("SELECT \(columns) FROM entries WHERE \(filter) ORDER BY \(sorting) LIMIT ? OFFSET ?", values + [max(1, min(limit, 10_000)), max(0, offset)]).map(\.entry)
        folder.children = entries
        return FileTreePage(folder: folder, entries: entries, total: total)
    }

    public func needsRefresh(_ url: URL) -> Bool {
        let root = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let cursor = try? cursor(root) else { return false }
        guard let journal = FileSystemJournal.read(root: root, since: cursor.event, expectedUUID: cursor.uuid) else { return false }
        return journal.requiresFullScan || ((try? changes(journal, root: root).isEmpty) != true)
    }
}
