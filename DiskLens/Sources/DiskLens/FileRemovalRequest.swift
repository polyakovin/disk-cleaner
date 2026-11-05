import Foundation
import Darwin
import DiskLensCore

enum FileRemovalMode: Equatable, Sendable {
    case trash, permanent

    var confirmationTitle: String { self == .permanent ? "Удалить безвозвратно?" : "Переместить в Корзину?" }
    var actionTitle: String { self == .permanent ? "Удалить безвозвратно" : "В Корзину" }
    var progressTitle: String { self == .permanent ? "Безвозвратное удаление…" : "Перемещение в Корзину…" }
    func successMessage(name: String) -> String {
        self == .permanent ? "Удалено безвозвратно: «\(name)»."
            : "«\(name)» в Корзине. Место обычно освобождается после её очистки."
    }
    func failureMessage(name: String, reason: String) -> String {
        self == .permanent ? "Не удалось полностью удалить «\(name)». Часть содержимого могла быть удалена. \(reason)"
            : "Не удалось переместить «\(name)» в Корзину. \(reason)"
    }
}

enum FileRemovalFailure: LocalizedError {
    case protectedPath, outsideScan, changed, unavailable(String)

    var errorDescription: String? {
        switch self {
        case .protectedPath: return "Корень замера, домашнюю папку, системные каталоги и Корзину нельзя удалить из DiskLens."
        case .outsideScan: return "Объект находится вне текущего замера. Просканируйте его папку заново."
        case .changed: return "Объект или путь к нему изменился. Повторите сканирование и выберите объект заново."
        case .unavailable(let reason): return "Не удалось проверить объект: \(reason)"
        }
    }
}

/// Captures the filesystem object shown in the confirmation, without following its final symlink.
struct FileRemovalRequest: Identifiable, Sendable {
    let id = UUID()
    let entry: DiskEntry
    let scanRoot: String
    let mode: FileRemovalMode
    private let identity: Identity
    private let resolvedParent: String

    private struct Identity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let kind: mode_t
    }

    init(entry: DiskEntry, scanRoot: String, mode: FileRemovalMode = .trash) throws {
        let url = URL(fileURLWithPath: entry.path).standardizedFileURL
        let root = URL(fileURLWithPath: scanRoot).standardizedFileURL.resolvingSymlinksInPath().path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let actual = parent.appendingPathComponent(url.lastPathComponent).path
        let canonicalRoot = Self.canonicalDataPath(root)
        let canonicalActual = Self.canonicalDataPath(actual)
        guard url.path == entry.path, Self.contains(canonicalActual, in: canonicalRoot), canonicalActual != canonicalRoot else {
            throw FileRemovalFailure.outsideScan
        }
        try Self.checkProtection(actual)
        self.entry = entry
        self.scanRoot = root
        self.mode = mode
        resolvedParent = parent.path
        identity = try Self.identity(at: url.path)
        // Data-volume firmlinks can resolve /System/Volumes/Data/Users to /Users.
        // Equivalent paths are allowed, but crossing onto another filesystem is not.
        guard identity.device == (try Self.identity(at: root)).device else { throw FileRemovalFailure.outsideScan }
        let expected: mode_t = entry.kind == .folder ? S_IFDIR : (entry.kind == .symlink ? S_IFLNK : S_IFREG)
        guard identity.kind == expected else { throw FileRemovalFailure.changed }
    }

    func validate() throws {
        let url = URL(fileURLWithPath: entry.path)
        guard url.deletingLastPathComponent().resolvingSymlinksInPath().path == resolvedParent,
              try Self.identity(at: entry.path) == identity else { throw FileRemovalFailure.changed }
    }

    @discardableResult
    func moveToTrash() throws -> URL? {
        try validate()
        // Failure stays a failure, including volumes without a usable Trash. Never fall back to unlink/remove.
        var destination: NSURL?
        try FileManager().trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: &destination)
        return destination as URL?
    }

    func perform() throws {
        if mode == .trash { try moveToTrash(); return }
        try validate()
        // Explicit permanent mode only. Foundation removes links themselves, not their destinations.
        try FileManager().removeItem(at: URL(fileURLWithPath: entry.path))
    }

    private static func identity(at path: String) throws -> Identity {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw FileRemovalFailure.unavailable(String(cString: strerror(errno)))
        }
        return Identity(device: info.st_dev, inode: info.st_ino, kind: info.st_mode & S_IFMT)
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private static func canonicalDataPath(_ path: String) -> String {
        let prefix = "/System/Volumes/Data"
        if path == prefix { return "/" }
        return path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count)) : path
    }

    private static func checkProtection(_ path: String) throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        // APFS exposes the same writable tree through /System/Volumes/Data.
        let dataPrefix = "/System/Volumes/Data"
        var canonical = Self.canonicalDataPath(path)
        // Foundation can also shorten /private/var and /private/etc to their root aliases.
        for alias in ["/var", "/etc", "/tmp"] {
            if contains(canonical, in: alias) { canonical = "/private" + canonical; break }
        }
        let roots = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/private", "/private/var", "/Network", dataPrefix]
        let systemTrees = ["/System", "/bin", "/sbin", "/usr", "/dev", "/private/etc", "/private/var/db", "/private/var/root", "/private/var/run"]
        let components = canonical.split(separator: "/")
        guard !roots.contains(canonical), !contains(home, in: canonical),
              !systemTrees.contains(where: { contains(canonical, in: $0) }),
              !components.contains(".Trash"), !components.contains(".Trashes") else {
            throw FileRemovalFailure.protectedPath
        }
    }
}
