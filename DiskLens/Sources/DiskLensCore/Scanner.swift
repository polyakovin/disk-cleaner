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
    public let revision: Int
    public let items: Int
    public let allocatedBytes: Int64
    public let currentPath: String
    public let report: DiskReport
    public let largestFolders: [DiskEntry]
    public let usesPreviousScan: Bool
    public var reusedFolders: Int = 0
}

public struct ScannerConfiguration: Sendable {
    public var retainedDepth: Int = 3
    public var childrenPerFolder: Int = 40
    public var largestFileLimit: Int = 100
    public var largestFolderLimit: Int = 40
    public var progressInterval: TimeInterval = 0.3
    public var cacheFolderLimit: Int = 15_000
    public var cacheByteLimit: Int = 20 * 1024 * 1024
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

private final class FolderFrame {
    var entry: DiskEntry
    var ranked: RankedEntries
    let issueBaseline: Int
    var directFiles: RankedEntries
    var childFolders: [String] = []
    var childPathBytes = 0
    var cacheComplete = true
    init(entry: DiskEntry, limit: Int, fileLimit: Int, issueBaseline: Int) {
        self.entry = entry
        ranked = RankedEntries(limit: limit)
        directFiles = RankedEntries(limit: fileLimit)
        self.issueBaseline = issueBaseline
    }
    func include(_ child: DiskEntry) {
        entry.allocatedBytes += child.allocatedBytes
        entry.logicalBytes += child.logicalBytes
        entry.fileCount += child.fileCount
        entry.childCount += 1
        ranked.insert(child)
    }
    func snapshot(including activeChild: DiskEntry? = nil) -> DiskEntry {
        var value = entry
        var children = ranked
        if let child = activeChild {
            value.allocatedBytes += child.allocatedBytes
            value.logicalBytes += child.logicalBytes
            value.fileCount += child.fileCount
            value.childCount += 1
            value.issueCount += child.issueCount
            children.insert(child)
        }
        value.children = children.entries
        return value
    }
}

public final class DiskScanner {
    private let config: ScannerConfiguration
    private let cancellation: CancellationFlag
    private let progress: (ScanProgress) -> Void
    private let previousReport: DiskReport?
    private let history: ScanHistoryStore?
    private let reusePreviousScan: Bool
    private let treeStore: FileTreeStore?
    private var treeToken: String?
    private var reuseTree = false
    private var unstableFolders = 0
    public private(set) var scanCache: ScanCache?
    // Injectable journal boundary keeps filesystem-change tests deterministic.
    var readJournal: (String, UInt64?, String?) -> JournalSnapshot? = {
        FileSystemJournal.read(root: $0, since: $1, expectedUUID: $2)
    }
    private var oldCache: ScanCache?
    private var cachedFolders: [String: CachedFolder] = [:]
    private var cacheBytes = 0
    private var pendingCacheBytes = 0
    private var buildingCache = false
    private var cacheBudgetExhausted = false
    private var invalidation = ScanInvalidation(root: "/", changes: [])
    private var reusedFolders = 0
    private var inspectedItems = 0
    private var hardLinksObserved = 0
    private var priorityPaths: [String: [String]] = [:]
    private var frames: [FolderFrame] = []
    private var started = Date()
    private var volume: VolumeCapacity?
    private var device: Int32 = 0
    private var hardLinks = Set<InodeKey>()
    private var hardLinksSkipped = 0
    private var largest: RankedEntries
    private var folders: RankedEntries
    private var candidates: [CleanupCandidate] = []
    private var issues: [ScanIssue] = []
    private var issueCount = 0
    private var mounts: [String] = []
    private var mountCount = 0
    private var items = 0
    private var allocated: Int64 = 0
    private var lastProgress = Date.distantPast
    private var revision = 0

    public init(configuration: ScannerConfiguration = .init(), cancellation: CancellationFlag = .init(),
                previousReport: DiskReport? = nil,
                history: ScanHistoryStore? = nil,
                treeStore: FileTreeStore? = nil,
                reusePreviousScan: Bool = true,
                progress: @escaping (ScanProgress) -> Void = { _ in }) {
        config = configuration
        self.cancellation = cancellation
        self.progress = progress
        self.previousReport = previousReport
        self.history = history
        self.treeStore = treeStore
        self.reusePreviousScan = reusePreviousScan
        largest = RankedEntries(limit: configuration.largestFileLimit)
        folders = RankedEntries(limit: configuration.largestFolderLimit)
    }

    public func scan(_ url: URL) throws -> DiskReport {
        let rootURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var info = stat()
        guard lstat(rootURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw ScanFailure.invalidRoot(rootURL.path)
        }
        device = info.st_dev
        hardLinks.removeAll(); hardLinksSkipped = 0
        largest.entries = []; folders.entries = []; candidates = []; issues = []; issueCount = 0
        mounts = []; mountCount = 0; items = 0; allocated = 0; lastProgress = .distantPast
        revision = 0
        reusedFolders = 0; inspectedItems = 0; hardLinksObserved = 0
        scanCache = nil; oldCache = nil; cachedFolders = [:]; cacheBytes = 0; pendingCacheBytes = 0
        buildingCache = false; cacheBudgetExhausted = false
        started = Date()
        unstableFolders = 0; reuseTree = false; treeToken = nil
        volume = VolumeCapacity.read(at: rootURL)
        let saved = try? history?.loadSnapshot()
        let previous = previousReport ?? saved?.report
        let cache = saved?.cache
        let matching = cache?.root == rootURL.path ? cache : nil
        let cursor = try treeStore?.cursor(rootURL.path)
        let journal = history == nil && treeStore == nil ? nil : readJournal(rootURL.path,
            treeStore == nil ? matching?.eventID : cursor?.event,
            treeStore == nil ? matching?.journalUUID : cursor?.uuid)
        let signature = [config.retainedDepth, config.childrenPerFolder, config.largestFileLimit, config.largestFolderLimit]
        if reusePreviousScan, let cache, let saved, let journal, cache.isValid(for: saved.report), cache.root == rootURL.path,
           cache.journalUUID == journal.uuid, cache.configuration == signature, !journal.requiresFullScan {
            oldCache = cache
            invalidation = ScanInvalidation(root: rootURL.path, changes: journal.changes)
        }
        if treeStore != nil {
            if reusePreviousScan, let cursor, let journal, cursor.uuid == journal.uuid, !journal.requiresFullScan {
                reuseTree = true
                invalidation = ScanInvalidation(root: rootURL.path, changes: try treeStore?.changes(journal, root: rootURL.path) ?? journal.changes)
            }
            treeToken = try treeStore?.begin(rootURL.path)
            oldCache = nil
        }
        defer { try? treeStore?.flush() }
        buildingCache = journal != nil && treeStore == nil
        priorityPaths = Self.priorityPaths(previous?.root, within: rootURL.path)
        var currentInfo = stat()
        guard lstat(rootURL.path, &currentInfo) == 0, currentInfo.st_mode & S_IFMT == S_IFDIR,
              currentInfo.st_dev == info.st_dev, currentInfo.st_ino == info.st_ino else {
            throw ScanFailure.invalidRoot(rootURL.path)
        }
        let root = try walk(rootURL.path, info: currentInfo, depth: 0)
        publish(rootURL.path, root: root, force: true)
        let value = report(root: root, candidates: Self.disjointCandidates(candidates), inProgress: false)
        if !value.cancelled, let treeToken { try treeStore?.finish(rootURL.path, journal: journal, token: treeToken) }
        if buildingCache, !cachedFolders.isEmpty, !value.cancelled, let journal {
            // Keep the cursor captured BEFORE walking. Changes during a scan must
            // be replayed on the next run, even if we happened to see some of them.
            scanCache = ScanCache(root: rootURL.path, journalUUID: journal.uuid, eventID: journal.eventID,
                                  configuration: signature, folders: cachedFolders)
        }
        return value
    }

    private func report(root: DiskEntry, candidates: [CleanupCandidate], inProgress: Bool) -> DiskReport {
        var value = DiskReport(schemaVersion: 1, measuredAt: started, durationSeconds: Date().timeIntervalSince(started),
                          root: root, volume: volume, largestFiles: largest.entries,
                          candidates: candidates, issues: issues, issueCount: issueCount, skippedMounts: mounts,
                          skippedMountCount: mountCount, hardLinksSkipped: hardLinksSkipped,
                          cancelled: cancellation.isCancelled, scannedItems: items)
        value.inProgress = inProgress ? true : nil
        value.scanReuse = ScanReuse(reusedFolders: reusedFolders, inspectedItems: inspectedItems)
        return value
    }

    // The saved tree is only an ordering hint. Every existing entry is measured again.
    private static func priorityPaths(_ previous: DiskEntry?, within root: String) -> [String: [String]] {
        guard let previous else { return [:] }
        var result: [String: [String]] = [:]
        func visit(_ entry: DiskEntry) {
            guard entry.isFolder else { return }
            let children = entry.children.filter {
                $0.isFolder && $0.allocatedBytes > 0 &&
                URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == entry.path
            }.sorted {
                $0.allocatedBytes == $1.allocatedBytes ? $0.path < $1.path : $0.allocatedBytes > $1.allocatedBytes
            }
            if entry.path == root || entry.path.hasPrefix(root == "/" ? "/" : root + "/") {
                let target = children.reduce(0.0) { $0 + Double($1.allocatedBytes) } * 0.9
                var covered = 0.0
                for child in children where covered < target {
                    result[entry.path, default: []].append(child.path)
                    covered += Double(child.allocatedBytes)
                }
            }
            for child in children { visit(child) }
        }
        visit(previous)
        return result
    }

    private static func candidate(_ entry: DiskEntry) -> CleanupCandidate? {
        guard let reason = cacheReason(entry.path) else { return nil }
        var compact = entry; compact.children = []
        return CleanupCandidate(entry: compact, reason: reason,
                                caution: "Проверьте содержимое и закройте приложение. Кэш может потребоваться скачать или создать заново.")
    }

    private func publish(_ path: String, root finalRoot: DiskEntry? = nil, force: Bool = false) {
        guard force || Date().timeIntervalSince(lastProgress) >= config.progressInterval else { return }
        lastProgress = Date()
        var active: DiskEntry?
        var liveCandidates = candidates
        var liveFolders = folders
        for frame in frames.reversed() {
            active = frame.snapshot(including: active)
            active?.issueCount = issueCount - frame.issueBaseline
            guard let entry = active else { continue }
            if frame !== frames.first {
                var compact = entry; compact.children = []
                liveFolders.insert(compact)
            }
            if entry.issueCount == 0, let value = Self.candidate(entry) { liveCandidates.append(value) }
        }
        guard var root = finalRoot ?? active else { return }
        root.issueCount = issueCount
        let paths = Set(liveFolders.entries.map(\.path))
        let top = liveFolders.entries.filter { !Self.hasAncestor($0.path, in: paths) }
        revision += 1
        progress(ScanProgress(revision: revision, items: items, allocatedBytes: allocated, currentPath: path,
                              report: report(root: root, candidates: Self.disjointCandidates(liveCandidates), inProgress: true),
                              largestFolders: top, usesPreviousScan: !priorityPaths.isEmpty, reusedFolders: reusedFolders))
    }

    private func walk(_ path: String, info: stat, depth: Int) throws -> DiskEntry {
        inspectedItems += 1
        let mode = info.st_mode & S_IFMT
        let kind: EntryKind = mode == S_IFDIR ? .folder : (mode == S_IFLNK ? .symlink : .file)
        var result = DiskEntry(path: path, kind: kind, allocatedBytes: max(0, Int64(info.st_blocks) * 512),
                               logicalBytes: kind == .file ? max(0, Int64(info.st_size)) : 0,
                               fileCount: kind == .file ? 1 : 0, issueCount: 0, childCount: 0, children: [])
        if info.st_dev != device {
            mountCount += 1
            if mounts.count < 20 { mounts.append(path) }
            result.allocatedBytes = 0; result.logicalBytes = 0; result.fileCount = 0
            result.sizeIsKnown = false
            if let treeToken {
                let known = try treeStore?.node(path)?.entry ?? result
                try treeStore?.put(IndexedEntry(entry: known, identity: FolderIdentity(info), items: 1, reusable: false), token: treeToken)
            }
            return result
        }
        if kind == .folder, reuseTree, !cancellation.isCancelled, invalidation.permits(path),
           let cached = try treeStore?.node(path), cached.reusable, cached.identity == FolderIdentity(info),
           let directory = opendir(path) {
            closedir(directory)
            items += cached.items; allocated += cached.entry.allocatedBytes; reusedFolders += 1
            if let treeToken { try treeStore?.touch(path, token: treeToken) }
            for file in try treeStore?.largestFiles(path, limit: config.largestFileLimit) ?? [] { largest.insert(file) }
            for entry in try treeStore?.candidateFolders(path) ?? [] {
                if let value = Self.candidate(entry) { candidates.append(value) }
            }
            return try treeStore?.summary(path, depth: max(0, config.retainedDepth - depth), limit: config.childrenPerFolder) ?? cached.entry
        }
        if kind == .file && info.st_nlink > 1 {
            hardLinksObserved += 1
            let key = InodeKey(device: info.st_dev, inode: UInt64(info.st_ino))
            if !hardLinks.insert(key).inserted {
                hardLinksSkipped += 1
                result.allocatedBytes = 0; result.logicalBytes = 0; result.fileCount = 0
            }
        }
        if kind == .folder, !cancellation.isCancelled, let treeToken,
           try treeStore?.replaceDirectoryIfNeeded(path, identity: FolderIdentity(info), token: treeToken) == true {
            invalidation.trees.insert(path)
        }
        if kind == .folder, !cancellation.isCancelled, let cached = oldCache?.folders[path], cached.reusable,
           cached.identity == FolderIdentity(info), invalidation.permits(path), let directory = opendir(path) {
            closedir(directory)
            items += cached.scannedItems
            allocated += cached.entry.allocatedBytes
            includeCached(path, depth: depth)
            return cached.entry
        }
        let startingItems = items
        let startingLinks = hardLinksObserved
        let startingMounts = mountCount
        let startingUnstable = unstableFolders
        items += 1
        allocated += result.allocatedBytes
        if kind != .folder {
            if kind == .file && result.allocatedBytes > 0 {
                largest.insert(result)
                if buildingCache, !cacheBudgetExhausted { frames.last?.directFiles.insert(result) }
            }
            if !cancellation.isCancelled, let treeToken {
                try treeStore?.put(IndexedEntry(entry: result, identity: FolderIdentity(info), items: 1,
                                               reusable: info.st_nlink <= 1), token: treeToken)
            }
            return result
        }
        let frame = FolderFrame(entry: result, limit: depth < config.retainedDepth ? config.childrenPerFolder : 0,
                                fileLimit: buildingCache && !cacheBudgetExhausted ? config.largestFileLimit : 0,
                                issueBaseline: issueCount)
        frames.append(frame)
        defer { pendingCacheBytes -= frame.childPathBytes; frames.removeLast() }
        publish(path)
        guard !cancellation.isCancelled else { return frame.snapshot() }
        guard let directory = opendir(path) else {
            addIssue(path, String(cString: strerror(errno)))
            frame.entry.issueCount += 1
            if let treeToken {
                var known = try treeStore?.node(path)?.entry ?? frame.snapshot()
                known.issueCount = max(1, known.issueCount)
                try treeStore?.put(IndexedEntry(entry: known, identity: FolderIdentity(info), items: 1, reusable: false), token: treeToken)
            }
            return frame.snapshot()
        }
        defer { closedir(directory) }
        let beforeIssues = issueCount
        func scanChild(_ childPath: String, missingIsNormal: Bool = false) throws {
            guard !cancellation.isCancelled else { return }
            if reuseTree, invalidation.permits(childPath), let cached = try treeStore?.node(childPath),
               !cached.entry.isFolder, cached.reusable {
                items += cached.items; allocated += cached.entry.allocatedBytes
                if cached.entry.kind == .file { largest.insert(cached.entry) }
                if let treeToken { try treeStore?.touch(childPath, token: treeToken) }
                frame.include(cached.entry); publish(childPath)
                return
            }
            var childInfo = stat()
            if lstat(childPath, &childInfo) != 0 {
                if !missingIsNormal || errno != ENOENT { addIssue(childPath, String(cString: strerror(errno))) }
            } else {
                if childInfo.st_mode & S_IFMT == S_IFDIR, childInfo.st_dev == device,
                   buildingCache, !cacheBudgetExhausted, frame.cacheComplete {
                    let bytes = 128 + childPath.utf8.count * 4
                    if frame.childFolders.count < config.cacheFolderLimit,
                       cacheBytes + pendingCacheBytes + bytes <= config.cacheByteLimit {
                        frame.childFolders.append(childPath)
                        frame.childPathBytes += bytes; pendingCacheBytes += bytes
                    } else {
                        // A directory with millions of uncacheable children must
                        // not retain an unbounded list just to build the index.
                        frame.cacheComplete = false
                        pendingCacheBytes -= frame.childPathBytes; frame.childPathBytes = 0
                        frame.childFolders.removeAll()
                    }
                }
                frame.include(try walk(childPath, info: childInfo, depth: depth + 1))
            }
            frame.entry.issueCount = issueCount - beforeIssues
            publish(childPath)
        }
        // Visit only the bounded, known heavy children first; stream all other entries.
        let priorities = priorityPaths[path] ?? []
        let visited = Set(priorities)
        for childPath in priorities {
            if cancellation.isCancelled { break }
            // A removed folder is normal between scans; enumeration discovers replacements.
            try scanChild(childPath, missingIsNormal: true)
        }
        errno = 0
        while !cancellation.isCancelled, let item = readdir(directory) {
            let name = withUnsafePointer(to: &item.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(item.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { errno = 0; continue }
            let childPath = path == "/" ? "/" + name : path + "/" + name
            if !visited.contains(childPath) { try scanChild(childPath) }
            errno = 0
        }
        if errno != 0 && !cancellation.isCancelled { addIssue(path, String(cString: strerror(errno))) }
        frame.entry.issueCount = issueCount - beforeIssues
        result = frame.snapshot()
        if !cancellation.isCancelled, let treeToken {
            var after = stat()
            let stable = lstat(path, &after) == 0 && FolderIdentity(info) == FolderIdentity(after)
            if !stable { unstableFolders += 1 }
            let reusable = stable && result.issueCount == 0 && hardLinksObserved == startingLinks &&
                mountCount == startingMounts && unstableFolders == startingUnstable
            if result.issueCount == 0 { try treeStore?.reconcile(path, token: treeToken) }
            var indexed = result
            indexed.children = []
            if result.issueCount > 0 {
                if let known = try treeStore?.node(path)?.entry, known.sizeIsKnown != false {
                    indexed.allocatedBytes = max(indexed.allocatedBytes, known.allocatedBytes)
                    indexed.logicalBytes = max(indexed.logicalBytes, known.logicalBytes)
                } else { indexed.sizeIsKnown = false }
            }
            try treeStore?.put(IndexedEntry(entry: indexed, identity: FolderIdentity(info), items: items - startingItems, reusable: reusable), token: treeToken)
        }
        if !cancellation.isCancelled, result.issueCount == 0, let value = Self.candidate(result) {
            candidates.append(value)
        }
        if depth > 0 { var compact = result; compact.children = []; folders.insert(compact) }
        if buildingCache, !cacheBudgetExhausted {
            var after = stat()
            let stable = lstat(path, &after) == 0 && FolderIdentity(info) == FolderIdentity(after)
            remember(CachedFolder(identity: FolderIdentity(info), entry: result, directLargestFiles: frame.directFiles.entries,
                                  childFolders: frame.childFolders, scannedItems: items - startingItems,
                                  reusable: stable && frame.cacheComplete && result.issueCount == 0 && hardLinksObserved == startingLinks &&
                                    mountCount == startingMounts && frame.childFolders.allSatisfy { cachedFolders[$0]?.reusable == true }))
        }
        return result
    }

    private func includeCached(_ path: String, depth: Int) {
        guard let cached = oldCache?.folders[path] else { return }
        reusedFolders += 1
        for file in cached.directLargestFiles { largest.insert(file) }
        if depth > 0 { var compact = cached.entry; compact.children = []; folders.insert(compact) }
        if let value = Self.candidate(cached.entry) { candidates.append(value) }
        for child in cached.childFolders { includeCached(child, depth: depth + 1) }
        remember(cached)
    }

    private func remember(_ folder: CachedFolder) {
        guard buildingCache, !cacheBudgetExhausted, folder.reusable else { return }
        func cost(_ entry: DiskEntry) -> Int {
            512 + entry.path.utf8.count * 4 + entry.children.reduce(0) { $0 + cost($1) }
        }
        let bytes = cost(folder.entry) + folder.directLargestFiles.reduce(0) { $0 + cost($1) } +
            folder.childFolders.reduce(0) { $0 + 128 + $1.utf8.count * 4 }
        guard cachedFolders.count < config.cacheFolderLimit, cacheBytes + pendingCacheBytes + bytes <= config.cacheByteLimit else {
            cacheBudgetExhausted = true; return
        }
        cacheBytes += bytes
        cachedFolders[folder.entry.path] = folder
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
        return unique.filter { !hasAncestor($0.entry.path, in: paths) }
            .sorted { $0.entry.allocatedBytes > $1.entry.allocatedBytes }
    }

    private static func hasAncestor(_ path: String, in paths: Set<String>) -> Bool {
        guard path != "/" else { return false }
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while parent != "/" {
            if paths.contains(parent) { return true }
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
        return paths.contains("/")
    }
}
