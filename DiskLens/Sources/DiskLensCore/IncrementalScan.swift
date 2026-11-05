import Foundation
import Darwin

/// Private scan data stays in local history, never in exported/agent reports.
public struct ScanCache: Codable, Sendable {
    var version = 1
    var root: String
    var journalUUID: String
    var eventID: UInt64
    var configuration: [Int]
    var folders: [String: CachedFolder]

    func isValid(for report: DiskReport) -> Bool {
        guard version == 1, eventID > 0, eventID < UInt64.max, !report.cancelled, report.inProgress != true, report.root.path == root,
              !folders.isEmpty, folders.count <= 15_000 else { return false }
        if let top = folders[root] {
            guard top.entry.allocatedBytes == report.root.allocatedBytes, top.scannedItems == report.scannedItems else { return false }
        }
        for (path, folder) in folders {
            guard folder.entry.path == path, folder.entry.isFolder, folder.reusable,
                  ScanInvalidation.contains(path, in: root), folder.scannedItems > 0,
                  folder.entry.allocatedBytes >= 0, folder.entry.logicalBytes >= 0,
                  folder.entry.childCount >= folder.childFolders.count else { return false }
            guard Set(folder.childFolders).count == folder.childFolders.count else { return false }
            for child in folder.childFolders {
                guard folders[child] != nil, URL(fileURLWithPath: child).deletingLastPathComponent().path == path,
                      child != root else { return false }
            }
            for file in folder.directLargestFiles {
                guard file.kind == .file, file.allocatedBytes > 0,
                      URL(fileURLWithPath: file.path).deletingLastPathComponent().path == path else { return false }
            }
        }
        // A bounded forest is valid: large scans may retain only some complete
        // subtrees. Missing ancestors are walked; retained descendants still help.
        return true
    }
}

struct FolderIdentity: Codable, Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
    let blocks: Int64

    init(_ info: stat) {
        device = info.st_dev; inode = UInt64(info.st_ino); mode = info.st_mode
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanos = Int64(info.st_mtimespec.tv_nsec)
        changedSeconds = Int64(info.st_ctimespec.tv_sec); changedNanos = Int64(info.st_ctimespec.tv_nsec)
        blocks = Int64(info.st_blocks)
    }
}

struct CachedFolder: Codable, Sendable {
    var identity: FolderIdentity
    var entry: DiskEntry
    var directLargestFiles: [DiskEntry]
    var childFolders: [String]
    var scannedItems: Int
    // Hard links must pass through the scanner's shared inode set; mounts and
    // inaccessible/unstable directories must be checked again as well.
    var reusable: Bool
}

struct JournalSnapshot {
    var uuid: String
    var eventID: UInt64
    var changes: [JournalChange]
    var requiresFullScan: Bool
}

struct JournalChange {
    var path: String
    var recursive: Bool
}

struct ScanInvalidation {
    var folders = Set<String>()
    var trees = Set<String>()

    init(root: String, changes: [JournalChange]) {
        for change in changes {
            guard Self.contains(change.path, in: root) else { continue }
            if change.recursive { trees.insert(change.path) }
            var path = change.path
            while Self.contains(path, in: root) {
                folders.insert(path)
                if path == root { break }
                path = URL(fileURLWithPath: path).deletingLastPathComponent().path
            }
        }
    }

    func permits(_ path: String) -> Bool {
        guard !folders.contains(path) else { return false }
        var ancestor = path
        while true {
            if trees.contains(ancestor) { return false }
            if ancestor == "/" { return true }
            ancestor = URL(fileURLWithPath: ancestor).deletingLastPathComponent().path
        }
    }

    static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}
