import Foundation
import CoreServices
import Darwin

/// Short-lived, device-relative replay. No daemon, file reads or persistent watch.
enum FileSystemJournal {
    private final class Replay {
        var changes: [JournalChange] = []
        var complete = false
        var unsafe = false
        var latest: UInt64 = 0
        var lastDelivery = DispatchTime.now().uptimeNanoseconds
        let historyDone = DispatchSemaphore(value: 0)
        let mount: String
        let collectChanges: Bool
        init(mount: String, collectChanges: Bool) { self.mount = mount; self.collectChanges = collectChanges }

        func receive(path: String, flags: UInt32, id: UInt64) {
            lastDelivery = DispatchTime.now().uptimeNanoseconds
            latest = max(latest, id)
            if flags & UInt32(kFSEventStreamEventFlagHistoryDone) != 0 {
                complete = true; historyDone.signal(); return
            }
            let invalid = kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged |
                kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount |
                kFSEventStreamEventFlagItemIsHardlink | kFSEventStreamEventFlagItemIsLastHardlink
            if flags & UInt32(invalid) != 0 { unsafe = true }
            guard collectChanges, !unsafe else { return }
            guard changes.count < 50_000 else { unsafe = true; changes.removeAll(); return }
            let absolute = URL(fileURLWithPath: mount, isDirectory: true)
                .appendingPathComponent(path).standardizedFileURL.path
            let types = kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemIsSymlink | kFSEventStreamEventFlagItemIsDir
            let recursive = flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs) != 0 || flags & UInt32(types) == 0
            changes.append(JournalChange(path: absolute, recursive: recursive))
        }
    }

    static func read(root: String, since eventID: UInt64?, expectedUUID: String? = nil) -> JournalSnapshot? {
        var info = stat()
        var filesystem = statfs()
        guard lstat(root, &info) == 0, statfs(root, &filesystem) == 0,
              filesystem.f_flags & UInt32(MNT_LOCAL) != 0,
              let uuid = FSEventsCopyUUIDForDevice(info.st_dev) else { return nil }
        let uuidString = CFUUIDCreateString(nil, uuid) as String
        // A cursor belongs to its journal UUID. Never carry an old high event ID
        // into a reset database, even when this run is going to do a full scan.
        let journalChanged = expectedUUID.map { $0 != uuidString } ?? false
        let replayID = journalChanged ? nil : eventID
        let mount = withUnsafePointer(to: &filesystem.f_mntonname) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        // Verify the physical alias of an APFS firmlink by device and inode.
        let physical: String
        if ScanInvalidation.contains(root, in: mount) { physical = root }
        else {
            let candidate = mount + root
            var alias = stat()
            guard lstat(candidate, &alias) == 0, alias.st_dev == info.st_dev, alias.st_ino == info.st_ino else { return nil }
            physical = candidate
        }
        let relative = String(physical.dropFirst(mount == "/" ? 1 : mount.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let replay = Replay(mount: mount, collectChanges: replayID != nil)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(replay).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot |
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreateRelativeToDevice(nil, { _, context, count, paths, flags, ids in
            guard let context else { return }
            let replay = Unmanaged<Replay>.fromOpaque(context).takeUnretainedValue()
            let strings = unsafeBitCast(paths, to: NSArray.self) as! [String]
            for index in 0..<count { replay.receive(path: strings[index], flags: flags[index], id: ids[index]) }
        }, &context, info.st_dev, [relative] as CFArray, replayID ?? 0, 0.01, UInt32(flags)) else { return nil }
        let queue = DispatchQueue(label: "com.polyakovin.DiskLens.journal")
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return nil
        }
        // FlushSync drains fseventsd, not the kernel's pending event queue. Require
        // a quiet delivery window as well (as recommended by Watchman's FSEvents
        // synchronization guidance). A busy/late stream falls back to a full walk.
        let ready = replay.historyDone.wait(timeout: .now() + 5) == .success
        var settled = false
        if ready {
            let began = DispatchTime.now().uptimeNanoseconds
            while DispatchTime.now().uptimeNanoseconds - began < 3_000_000_000 {
                FSEventStreamFlushSync(stream)
                let last = queue.sync { replay.lastDelivery }
                let now = DispatchTime.now().uptimeNanoseconds
                if now - last >= 500_000_000, now - began >= 500_000_000 { settled = true; break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        queue.sync {}
        let latest = max(replay.latest, FSEventStreamGetLatestEventId(stream))
        FSEventStreamRelease(stream)
        guard ready, replay.complete, latest > 0, latest != UInt64.max,
              let afterUUID = FSEventsCopyUUIDForDevice(info.st_dev), CFEqual(uuid, afterUUID) else { return nil }
        // Translate the physical Data-volume prefix back to the caller's logical path.
        let changes = replay.changes.map { change -> JournalChange in
            guard physical != root, ScanInvalidation.contains(change.path, in: physical) else { return change }
            return JournalChange(path: root + change.path.dropFirst(physical.count), recursive: change.recursive)
        }
        let unexpectedPath = changes.contains { !ScanInvalidation.contains($0.path, in: root) }
        return JournalSnapshot(uuid: uuidString, eventID: latest, changes: changes,
                               requiresFullScan: journalChanged || !settled || replay.unsafe || unexpectedPath ||
                                (replayID.map { latest < $0 } ?? false))
    }
}
