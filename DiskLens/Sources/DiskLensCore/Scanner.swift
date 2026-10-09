import Foundation
import Darwin

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
}

public struct ScanProgress: Sendable {
    public let items: Int
    public let allocatedBytes: Int64
    public let currentPath: String
}

public struct ScannerConfiguration: Sendable {
    public var retainedDepth: Int = 3
    public var childrenPerFolder: Int = 40
    public var largestFileLimit: Int = 100
    public init() {}
}

public enum ScanFailure: LocalizedError {
    case invalidRoot(String)
    public var errorDescription: String? {
        switch self { case .invalidRoot(let p): return "Не удалось открыть папку \(p). Проверьте путь и доступ." }
    }
}

private struct InodeKey: Hashable { let device: Int32; let inode: UInt64 }

private struct RankedEntries {
    let limit: Int
    var entries: [DiskEntry] = []
    mutating func insert(_ entry: DiskEntry) {
        guard limit > 0 else { return }
        if entries.count >= limit && entry.allocatedBytes <= (entries.last?.allocatedBytes ?? 0) { return }
        let position = entries.firstIndex { $0.allocatedBytes < entry.allocatedBytes } ?? entries.endIndex
        entries.insert(entry, at: position)
        if entries.count > limit { entries.removeLast() }
    }
}

public final class DiskScanner {
    private let config: ScannerConfiguration
    private let cancellation: CancellationFlag
    private let progress: (ScanProgress) -> Void
    private var device: Int32 = 0
    private var hardLinks = Set<InodeKey>()
    private var hardLinksSkipped = 0
    private var largest: RankedEntries
    private var candidates: [CleanupCandidate] = []
    private var issues: [ScanIssue] = []
    private var issueCount = 0
    private var mounts: [String] = []
    private var mountCount = 0
    private var items = 0
    private var allocated: Int64 = 0
    private var lastProgress = Date.distantPast

    public init(configuration: ScannerConfiguration = .init(), cancellation: CancellationFlag = .init(),
                progress: @escaping (ScanProgress) -> Void = { _ in }) {
        config = configuration
        self.cancellation = cancellation
        self.progress = progress
        largest = RankedEntries(limit: configuration.largestFileLimit)
    }

    public func scan(_ url: URL) throws -> DiskReport {
        let rootURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(rootURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw ScanFailure.invalidRoot(rootURL.path)
        }
        device = info.st_dev
        let started = Date()
        let root = walk(rootURL.path, info: info, depth: 0)
        let disjoint = Self.disjointCandidates(candidates)
        progress(ScanProgress(items: items, allocatedBytes: allocated, currentPath: rootURL.path))
        return DiskReport(schemaVersion: 1, measuredAt: started, durationSeconds: Date().timeIntervalSince(started),
                          root: root, volume: VolumeCapacity.read(at: rootURL), largestFiles: largest.entries,
                          candidates: disjoint, issues: issues, issueCount: issueCount, skippedMounts: mounts,
                          skippedMountCount: mountCount, hardLinksSkipped: hardLinksSkipped,
                          cancelled: cancellation.isCancelled, scannedItems: items)
    }

    private func walk(_ path: String, info: stat, depth: Int) -> DiskEntry {
        let mode = info.st_mode & S_IFMT
        let kind: EntryKind = mode == S_IFDIR ? .folder : (mode == S_IFLNK ? .symlink : .file)
        var result = DiskEntry(path: path, kind: kind, allocatedBytes: max(0, Int64(info.st_blocks) * 512),
                               logicalBytes: kind == .file ? max(0, Int64(info.st_size)) : 0,
                               fileCount: kind == .file ? 1 : 0, issueCount: 0, childCount: 0, children: [])
        if info.st_dev != device {
            mountCount += 1
            if mounts.count < 20 { mounts.append(path) }
            result.allocatedBytes = 0; result.logicalBytes = 0; result.fileCount = 0
            return result
        }
        if kind == .file && info.st_nlink > 1 {
            let key = InodeKey(device: info.st_dev, inode: UInt64(info.st_ino))
            if !hardLinks.insert(key).inserted {
                hardLinksSkipped += 1
                result.allocatedBytes = 0; result.logicalBytes = 0; result.fileCount = 0
            }
        }
        items += 1
        allocated += result.allocatedBytes
        if Date().timeIntervalSince(lastProgress) > 0.3 {
            lastProgress = Date()
            progress(ScanProgress(items: items, allocatedBytes: allocated, currentPath: path))
        }
        if kind != .folder {
            if kind == .file && result.allocatedBytes > 0 { largest.insert(result) }
            return result
        }
        guard !cancellation.isCancelled else { return result }
        guard let directory = opendir(path) else {
            addIssue(path, String(cString: strerror(errno)))
            result.issueCount += 1
            return result
        }
        defer { closedir(directory) }
        var ranked = RankedEntries(limit: depth < config.retainedDepth ? config.childrenPerFolder : 0)
        let beforeIssues = issueCount
        errno = 0
        while !cancellation.isCancelled, let item = readdir(directory) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { errno = 0; continue }
            let childPath = path == "/" ? "/" + name : path + "/" + name
            var childInfo = stat()
            if lstat(childPath, &childInfo) != 0 {
                addIssue(childPath, String(cString: strerror(errno)))
            } else {
                let child = walk(childPath, info: childInfo, depth: depth + 1)
                result.allocatedBytes += child.allocatedBytes
                result.logicalBytes += child.logicalBytes
                result.fileCount += child.fileCount
                result.childCount += 1
                ranked.insert(child)
            }
            errno = 0
        }
        if errno != 0 && !cancellation.isCancelled { addIssue(path, String(cString: strerror(errno))) }
        result.children = ranked.entries
        result.issueCount = issueCount - beforeIssues
        if !cancellation.isCancelled, result.issueCount == 0, let reason = Self.cacheReason(path) {
            var compact = result; compact.children = []
            candidates.append(CleanupCandidate(entry: compact, reason: reason,
                              caution: "Проверьте содержимое и закройте приложение. Кэш может потребоваться скачать или создать заново."))
        }
        return result
    }

    private func addIssue(_ path: String, _ message: String) {
        issueCount += 1
        if issues.count < 20 { issues.append(ScanIssue(path: path, message: message)) }
    }

    public static func cacheReason(_ path: String) -> String? {
        let suffixes = ["/Library/Caches", "/.npm/_cacache", "/.npm/_npx", "/.gradle/caches",
                        "/Library/Developer/Xcode/DerivedData", "/CapCut/User Data/Cache",
                        "/.cache/uv", "/.cache/pip"]
        return suffixes.contains(where: path.hasSuffix) ? "Известный каталог кэша" : nil
    }

    public static func disjointCandidates(_ input: [CleanupCandidate]) -> [CleanupCandidate] {
        let unique = Dictionary(input.map { ($0.entry.path, $0) }, uniquingKeysWith: { a, _ in a }).values
        let paths = Set(unique.map { $0.entry.path })
        return unique.filter { candidate in
            var parent = URL(fileURLWithPath: candidate.entry.path).deletingLastPathComponent().path
            while parent != "/" {
                if paths.contains(parent) { return false }
                parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
            }
            return !paths.contains("/") || candidate.entry.path == "/"
        }.sorted { $0.entry.allocatedBytes > $1.entry.allocatedBytes }
    }
}
