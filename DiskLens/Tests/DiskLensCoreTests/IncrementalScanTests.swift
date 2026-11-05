import XCTest
import Foundation
import Darwin
@testable import DiskLensCore

final class IncrementalScanTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("scan") }
    private var history: ScanHistoryStore { ScanHistoryStore(directory: temporary.appendingPathComponent("history")) }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-incremental-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    @discardableResult private func write(_ path: String, blocks: Int = 1) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: blocks * 4096).write(to: url)
        return url
    }

    private func scanner(changes: [JournalChange] = [], full: Bool = false,
                         configuration: ScannerConfiguration = .init(), flag: CancellationFlag = .init()) -> DiskScanner {
        let value = DiskScanner(configuration: configuration, cancellation: flag, history: history)
        value.readJournal = { _, _, _ in JournalSnapshot(uuid: "test-journal", eventID: 100, changes: changes, requiresFullScan: full) }
        return value
    }

    @discardableResult private func baseline() throws -> DiskReport {
        let value = scanner()
        let report = try value.scan(root)
        XCTAssertNotNil(value.scanCache)
        try history.save(report, cache: value.scanCache)
        return report
    }

    private func assertEquivalent(_ actual: DiskReport, _ expected: DiskReport, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.root.allocatedBytes, expected.root.allocatedBytes, file: file, line: line)
        XCTAssertEqual(actual.root.logicalBytes, expected.root.logicalBytes, file: file, line: line)
        XCTAssertEqual(actual.root.fileCount, expected.root.fileCount, file: file, line: line)
        XCTAssertEqual(actual.scannedItems, expected.scannedItems, file: file, line: line)
        XCTAssertEqual(actual.hardLinksSkipped, expected.hardLinksSkipped, file: file, line: line)
        XCTAssertEqual(actual.largestFiles.map(\.allocatedBytes).sorted(), expected.largestFiles.map(\.allocatedBytes).sorted(), file: file, line: line)
        // Either name may be the first discovered representative of a hard link.
        if expected.hardLinksSkipped == 0 {
            XCTAssertEqual(Set(actual.largestFiles.map(\.path)), Set(expected.largestFiles.map(\.path)), file: file, line: line)
        }
        XCTAssertEqual(actual.candidates.map(\.entry.path), expected.candidates.map(\.entry.path), file: file, line: line)
    }

    func testUnchangedScanRestoresAllSummariesWithoutWalkingFilesAfterRestart() throws {
        try write("Library/Caches/deep/file", blocks: 10)
        try write("other/file", blocks: 20)
        let first = try baseline()
        let restarted = scanner()
        let result = try restarted.scan(root)
        assertEquivalent(result, first)
        XCTAssertEqual(result.scanReuse?.inspectedItems, 1)
        XCTAssertEqual(result.scanReuse?.reusedFolders, 5)
        XCTAssertNotNil(restarted.scanCache)
        // The private folder index must never be exported or sent to an agent.
        XCTAssertFalse(try result.json().contains("directLargestFiles"))
        XCTAssertFalse(try result.agentPrompt().contains("journalUUID"))
    }

    func testChangedDeepFileWithUnchangedParentDateOnlyRescansChangedBranch() throws {
        let changed = try write("changed/a/b/c/d/file")
        try write("stable/deep/file", blocks: 20)
        try write("Library/Caches/deep/file", blocks: 10)
        _ = try baseline()
        let parent = changed.deletingLastPathComponent()
        var before = stat(); XCTAssertEqual(lstat(parent.path, &before), 0)
        let handle = try FileHandle(forWritingTo: changed)
        try handle.write(contentsOf: Data(repeating: 7, count: 50 * 4096)); try handle.close()
        var after = stat(); XCTAssertEqual(lstat(parent.path, &after), 0)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        let update = scanner(changes: [JournalChange(path: changed.path, recursive: false)])
        let result = try update.scan(root)
        let full = try DiskScanner().scan(root)
        assertEquivalent(result, full)
        XCTAssertGreaterThan(result.scanReuse?.reusedFolders ?? 0, 0)
        XCTAssertLessThan(result.scanReuse?.inspectedItems ?? .max, full.scannedItems)
        try history.save(result, cache: update.scanCache)
        let third = try scanner().scan(root)
        assertEquivalent(third, full)
        XCTAssertEqual(third.scanReuse?.inspectedItems, 1)
    }

    func testCreatedDeletedRenamedAndSymlinkReplacedDirectories() throws {
        try write("deleted/file", blocks: 4)
        try write("renamed/file", blocks: 5)
        try write("replaced/file", blocks: 6)
        try write("stable/deep/file", blocks: 7)
        _ = try baseline()
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("renamed"), to: root.appendingPathComponent("moved"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("replaced"))
        let outside = temporary.appendingPathComponent("outside")
        try Data(repeating: 42, count: 100 * 4096).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("replaced"), withDestinationURL: outside)
        let created = try write("new/file", blocks: 8)
        let changes = ["deleted", "renamed", "moved", "replaced"].map {
            JournalChange(path: root.appendingPathComponent($0).path, recursive: true)
        } + [JournalChange(path: created.path, recursive: false)]
        let result = try scanner(changes: changes).scan(root)
        assertEquivalent(result, try DiskScanner().scan(root))
        XCTAssertGreaterThan(result.scanReuse?.reusedFolders ?? 0, 0)
        XCTAssertFalse(result.largestFiles.contains { $0.path == outside.path })
    }

    func testHardLinkedSubtreesAreRewalkedWhileIndependentBranchesAreReused() throws {
        let source = try write("linked/file", blocks: 10)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("second"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: source, to: root.appendingPathComponent("second/link"))
        try write("stable/file", blocks: 20)
        _ = try baseline()
        let result = try scanner().scan(root)
        assertEquivalent(result, try DiskScanner().scan(root))
        XCTAssertEqual(result.hardLinksSkipped, 1)
        XCTAssertEqual(result.scanReuse?.reusedFolders, 1)
    }

    func testMissingOrDiscontinuousJournalAndIncompatibleConfigurationForceFullScan() throws {
        try write("folder/deep/file")
        _ = try baseline()
        let unavailable = scanner(); unavailable.readJournal = { _, _, _ in nil }
        let missing = try unavailable.scan(root)
        XCTAssertEqual(missing.scanReuse?.reusedFolders, 0)
        XCTAssertNil(unavailable.scanCache)
        let dropped = try scanner(full: true).scan(root)
        XCTAssertEqual(dropped.scanReuse?.reusedFolders, 0)
        var config = ScannerConfiguration(); config.retainedDepth = 6
        let incompatible = try scanner(configuration: config).scan(root)
        XCTAssertEqual(incompatible.scanReuse?.reusedFolders, 0)
        let changedUUID = scanner()
        changedUUID.readJournal = { _, _, _ in JournalSnapshot(uuid: "new-journal", eventID: 200, changes: [], requiresFullScan: false) }
        XCTAssertEqual(try changedUUID.scan(root).scanReuse?.reusedFolders, 0)
    }

    func testBoundedCacheCancellationAndMutationInvalidation() throws {
        try write("folder/deep/file")
        let first = try baseline()
        var config = ScannerConfiguration(); config.cacheFolderLimit = 1
        let bounded = scanner(configuration: config)
        let boundedReport = try bounded.scan(root)
        XCTAssertEqual(bounded.scanCache?.folders.count, 1)
        XCTAssertTrue(bounded.scanCache?.isValid(for: boundedReport) == true)
        try history.save(boundedReport, cache: bounded.scanCache)
        let reused = try scanner(configuration: config).scan(root)
        assertEquivalent(reused, first)
        XCTAssertEqual(reused.scanReuse?.reusedFolders, 1)
        let flag = CancellationFlag(); flag.cancel()
        let cancelled = scanner(flag: flag)
        let partial = try cancelled.scan(root)
        XCTAssertTrue(partial.isPartial)
        XCTAssertNil(cancelled.scanCache)
        try history.save(partial, unlessCancelled: flag)
        XCTAssertEqual(try history.load()?.scannedItems, first.scannedItems)
        XCTAssertNotNil(try history.loadSnapshot()?.cache)
        try history.clear()
        XCTAssertNil(try history.loadSnapshot())
    }

    func testLegacyReportOnlyHistoryMigrates() throws {
        try write("folder/file")
        let first = try DiskScanner().scan(root)
        try FileManager.default.createDirectory(at: history.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(first).write(to: history.directory.appendingPathComponent("last-scan.json"))
        let migrated = scanner()
        assertEquivalent(try migrated.scan(root), first)
        XCTAssertNotNil(migrated.scanCache)
        XCTAssertEqual(try history.load()?.root.path, first.root.path)
    }

    func testBrokenIndexAndForcedFullScanDoNotReuseMeasurements() throws {
        try write("folder/deep/file")
        let first = try baseline()
        var broken = try XCTUnwrap(history.loadSnapshot()?.cache)
        broken.folders.removeValue(forKey: root.appendingPathComponent("folder/deep").path)
        try history.save(first, cache: broken)
        XCTAssertEqual(try scanner().scan(root).scanReuse?.reusedFolders, 0)
        _ = try baseline()
        let forced = DiskScanner(history: history, reusePreviousScan: false)
        forced.readJournal = scanner().readJournal
        let result = try forced.scan(root)
        assertEquivalent(result, first)
        XCTAssertEqual(result.scanReuse?.reusedFolders, 0)
        XCTAssertEqual(result.scanReuse?.inspectedItems, result.scannedItems)
        XCTAssertNotNil(forced.scanCache)
        var config = ScannerConfiguration(); config.cacheByteLimit = 1
        let limited = scanner(configuration: config)
        _ = try limited.scan(root)
        XCTAssertNil(limited.scanCache)
    }

    func testInaccessibleFoldersAreRetriedAndAccessibleSubtreesRemainReusable() throws {
        try write("stable/deep/file", blocks: 10)
        try write("closed/file", blocks: 20)
        let closed = root.appendingPathComponent("closed")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: closed.path) }
        let first = try baseline()
        XCTAssertTrue(first.isPartial)
        let next = try scanner().scan(root)
        XCTAssertTrue(next.isPartial)
        XCTAssertEqual(next.issueCount, first.issueCount)
        XCTAssertEqual(next.scanReuse?.reusedFolders, 2)
        assertEquivalent(next, try DiskScanner().scan(root))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: closed.path)
        let opened = try scanner(changes: [JournalChange(path: closed.path, recursive: true)]).scan(root)
        XCTAssertFalse(opened.isPartial)
        XCTAssertEqual(opened.root.fileCount, 2)
        XCTAssertEqual(opened.scanReuse?.reusedFolders, 2)
    }

    func testMalformedCacheDoesNotLoseReadableReport() throws {
        try write("folder/file")
        let first = try baseline()
        let file = history.directory.appendingPathComponent("last-scan.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["cache"] = ["folders": "invalid-index"]
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertEqual(try history.load()?.root.allocatedBytes, first.root.allocatedBytes)
        XCTAssertNil(try history.loadSnapshot()?.cache)
        XCTAssertEqual(try scanner().scan(root).scanReuse?.reusedFolders, 0)
    }

    func testChangesDuringWalkKeepEarlierJournalCursorForNextRun() throws {
        let file = try write("stable/deep/file")
        var changedDuringWalk = false
        var writeError: Error?
        var config = ScannerConfiguration(); config.progressInterval = 0
        let scanner = DiskScanner(configuration: config, history: history) { update in
            guard update.currentPath == file.path, !changedDuringWalk else { return }
            changedDuringWalk = true
            do {
                let handle = try FileHandle(forWritingTo: file)
                try handle.write(contentsOf: Data(repeating: 7, count: 50 * 4096)); try handle.close()
            } catch { writeError = error }
        }
        scanner.readJournal = { _, _, _ in JournalSnapshot(uuid: "test-journal", eventID: 50, changes: [], requiresFullScan: false) }
        let report = try scanner.scan(root)
        XCTAssertTrue(changedDuringWalk)
        XCTAssertNil(writeError)
        XCTAssertEqual(report.root.logicalBytes, 4096)
        XCTAssertEqual(scanner.scanCache?.eventID, 50)
        try history.save(report, cache: scanner.scanCache)
        let next = self.scanner(changes: [JournalChange(path: file.path, recursive: false)])
        var observed: UInt64?
        let read = next.readJournal
        next.readJournal = { path, since, uuid in observed = since; return read(path, since, uuid) }
        assertEquivalent(try next.scan(root), try DiskScanner().scan(root))
        XCTAssertEqual(observed, 50)
    }

    func testRealFSEventsReplayDetectsFileWritesAndSupportsRestart() throws {
        // Keep the system-journal fixture in the ignored project build directory.
        try FileManager.default.removeItem(at: temporary)
        temporary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/journal-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let changed = try write("changed/deep/file")
        try write("stable/deep/file", blocks: 10)
        let first = DiskScanner(history: history)
        let report = try first.scan(root)
        let cache = try XCTUnwrap(first.scanCache, "Local macOS volume must provide a complete FSEvents replay")
        try history.save(report, cache: cache)
        let unchanged = try DiskScanner(history: history).scan(root)
        XCTAssertGreaterThan(unchanged.scanReuse?.reusedFolders ?? 0, 0)
        for blocks in [60, 80, 100, 120, 140] {
            let handle = try FileHandle(forWritingTo: changed)
            try handle.write(contentsOf: Data(repeating: 7, count: blocks * 4096)); try handle.close()
            let next = DiskScanner(history: history)
            let updated = try next.scan(root)
            assertEquivalent(updated, try DiskScanner().scan(root))
            XCTAssertGreaterThan(updated.scanReuse?.reusedFolders ?? 0, 0)
            XCTAssertLessThan(updated.scanReuse?.inspectedItems ?? .max, updated.scannedItems)
            XCTAssertGreaterThan(updated.root.logicalBytes, report.root.logicalBytes)
            try history.save(updated, cache: next.scanCache)
        }
        let saved = try XCTUnwrap(history.loadSnapshot())
        var reset = try XCTUnwrap(saved.cache)
        reset.journalUUID = "discarded-journal"
        reset.eventID = UInt64.max - 1
        try history.save(saved.report, cache: reset)
        let recovering = DiskScanner(history: history)
        let recovered = try recovering.scan(root)
        assertEquivalent(recovered, try DiskScanner().scan(root))
        XCTAssertEqual(recovered.scanReuse?.reusedFolders, 0)
        XCTAssertNotEqual(recovering.scanCache?.eventID, reset.eventID)
        try history.save(recovered, cache: recovering.scanCache)
        XCTAssertGreaterThan(try DiskScanner(history: history).scan(root).scanReuse?.reusedFolders ?? 0, 0)
        try FileManager.default.linkItem(at: changed, to: root.appendingPathComponent("stable/deep/new-link"))
        let linked = try DiskScanner(history: history).scan(root)
        assertEquivalent(linked, try DiskScanner().scan(root))
        XCTAssertEqual(linked.scanReuse?.reusedFolders, 0)
    }
}
