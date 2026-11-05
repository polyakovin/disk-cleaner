import XCTest
import Foundation
import Darwin
import CSQLite
@testable import DiskLensCore

final class FileTreeTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("files") }
    private var directory: URL { temporary.appendingPathComponent("index") }
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-tree-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    @discardableResult private func write(_ path: String, blocks: Int = 1) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: blocks * 4096).write(to: file)
        return file
    }
    private func scanner(_ store: FileTreeStore, changes: [JournalChange] = [], full: Bool = false,
                         flag: CancellationFlag = .init(), progress: @escaping (ScanProgress) -> Void = { _ in }) -> DiskScanner {
        var config = ScannerConfiguration(); config.childrenPerFolder = 2; config.retainedDepth = 1
        config.cacheFolderLimit = 1; config.cacheByteLimit = 1; config.progressInterval = 0
        let scanner = DiskScanner(configuration: config, cancellation: flag, treeStore: store, progress: progress)
        scanner.readJournal = { _, _, _ in JournalSnapshot(uuid: "tree-test", eventID: 100, changes: changes, requiresFullScan: full) }
        return scanner
    }
    func testCompleteTreeSurvivesRestartBeyondReportDepthAndChildLimits() throws {
        for n in 0..<65 { try write("deep/a/b/c/folder\(n)/file") }
        var store: FileTreeStore? = try FileTreeStore(directory: directory)
        let first = try scanner(store!).scan(root)
        XCTAssertEqual(first.root.children.count, 1)
        XCTAssertEqual(try store!.page(root.appendingPathComponent("deep/a/b/c").path)?.total, 65)
        store = nil
        let restarted = try FileTreeStore(directory: directory)
        let page = try XCTUnwrap(restarted.page(root.appendingPathComponent("deep/a/b/c").path, limit: 10, offset: 60))
        XCTAssertEqual(page.entries.count, 5)
        XCTAssertEqual(try restarted.page(page.entries[0].path)?.entries.first?.name, "file")
        let reused = try scanner(restarted).scan(root)
        XCTAssertEqual(reused.root.allocatedBytes, first.root.allocatedBytes)
        XCTAssertEqual(reused.scanReuse?.inspectedItems, 1)
    }
    func testChangedFileUpdatesAncestorsAndKeepsUnchangedSiblings() throws {
        let changed = try write("branch/deep/file")
        for n in 0..<40 { try write("branch/deep/other\(n)", blocks: 2) }
        try write("stable/deep/file", blocks: 3)
        let store = try FileTreeStore(directory: directory)
        _ = try scanner(store).scan(root)
        let before = try XCTUnwrap(store.node(root.path)?.entry.allocatedBytes)
        try Data(repeating: 8, count: 30 * 4096).write(to: changed)
        let updated = try scanner(store, changes: [JournalChange(path: changed.path, recursive: false)]).scan(root)
        let full = try DiskScanner().scan(root)
        XCTAssertEqual(updated.root.allocatedBytes, full.root.allocatedBytes)
        XCTAssertGreaterThan(updated.root.allocatedBytes, before)
        XCTAssertLessThan(updated.scanReuse?.inspectedItems ?? 1000, 10)
        XCTAssertEqual(try store.node(root.path)?.entry.allocatedBytes, full.root.allocatedBytes)
        XCTAssertEqual(try store.page(changed.deletingLastPathComponent().path)?.entries.first?.path, changed.path)
    }
    func testRenameDeleteAndFolderReplacedByLinkRemoveOldDescendants() throws {
        try write("deleted/a/file"); try write("renamed/a/file"); try write("replaced/a/file")
        let store = try FileTreeStore(directory: directory)
        _ = try scanner(store).scan(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("renamed"), to: root.appendingPathComponent("new"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("replaced"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("replaced"), withDestinationURL: temporary)
        let changes = ["deleted", "renamed", "new", "replaced"].map { JournalChange(path: root.appendingPathComponent($0).path, recursive: true) }
        let report = try scanner(store, changes: changes).scan(root)
        XCTAssertEqual(report.root.allocatedBytes, try DiskScanner().scan(root).root.allocatedBytes)
        XCTAssertNil(try store.node(root.appendingPathComponent("deleted/a/file").path))
        XCTAssertNil(try store.node(root.appendingPathComponent("renamed/a/file").path))
        XCTAssertNil(try store.node(root.appendingPathComponent("replaced/a/file").path))
        XCTAssertEqual(try store.node(root.appendingPathComponent("replaced").path)?.entry.kind, .symlink)
    }
    func testCancellationRetainsKnownSizesAndInvalidatesCursor() throws {
        try write("a/file", blocks: 4); try write("b/file", blocks: 8)
        let store = try FileTreeStore(directory: directory)
        let first = try scanner(store).scan(root)
        let flag = CancellationFlag()
        let cancelled = scanner(store, full: true, flag: flag) { _ in flag.cancel() }
        XCTAssertTrue(try cancelled.scan(root).cancelled)
        XCTAssertEqual(try store.node(root.path)?.entry.allocatedBytes, first.root.allocatedBytes)
        XCTAssertEqual(try store.page(root.path)?.total, 2)
        XCTAssertNil(try store.cursor(root.path))
        XCTAssertEqual(try scanner(store).scan(root).root.allocatedBytes, first.root.allocatedBytes)
    }
    func testUnknownFoldersAreBrowsableAndDiscoveryDoesNotZeroMeasuredSizes() throws {
        try write("deep/a/b/c/file", blocks: 8)
        let store = try FileTreeStore(directory: directory)
        try store.discover(root)
        XCTAssertEqual(try store.page(root.path)?.entries.first?.sizeIsKnown, false)
        try store.discover(root.appendingPathComponent("deep/a/b/c"))
        XCTAssertEqual(try store.page(root.appendingPathComponent("deep/a/b/c").path)?.entries.first?.name, "file")
        _ = try scanner(store).scan(root)
        let size = try store.node(root.appendingPathComponent("deep").path)?.entry.allocatedBytes
        try store.discover(root)
        XCTAssertEqual(try store.page(root.path)?.entries.first?.allocatedBytes, size)
        XCTAssertEqual(try store.page(root.path)?.entries.first?.sizeIsKnown, true)
    }
    func testSortSearchAndPaginationCoverEveryChildIncludingCyrillic() throws {
        for n in 0..<40 { try write(String(format: "Файл-%02d", n), blocks: n + 1) }
        let store = try FileTreeStore(directory: directory)
        _ = try scanner(store).scan(root)
        let page = try XCTUnwrap(store.page(root.path, limit: 7))
        XCTAssertEqual(page.total, 40); XCTAssertEqual(page.entries.first?.name, "Файл-39")
        var paths = Set<String>()
        for offset in stride(from: 0, to: 40, by: 7) {
            let entries = try XCTUnwrap(store.page(root.path, limit: 7, offset: offset)).entries
            paths.formUnion(entries.map(\.path))
        }
        XCTAssertEqual(paths.count, 40)
        XCTAssertEqual(try store.page(root.path, order: .sizeAscending)?.entries.first?.name, "Файл-00")
        XCTAssertEqual(try store.page(root.path, search: "фАЙЛ-3")?.total, 10)
    }
    func testLostJournalForcesVerificationWithoutErasingIndexAtStart() throws {
        try write("a/file", blocks: 6)
        let store = try FileTreeStore(directory: directory)
        let first = try scanner(store).scan(root)
        let scanner = DiskScanner(treeStore: store) { _ in
            XCTAssertEqual(try? store.node(self.root.path)?.entry.allocatedBytes, first.root.allocatedBytes)
        }
        scanner.readJournal = { _, _, _ in nil }
        XCTAssertEqual(try scanner.scan(root).root.allocatedBytes, first.root.allocatedBytes)
    }
    func testHardLinksAreCountedOnceAndNotReusedOutsideSharedInodeSet() throws {
        let file = try write("a/file", blocks: 4)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("b"), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("b/link"))
        try write("stable/file", blocks: 3)
        let store = try FileTreeStore(directory: directory)
        let first = try scanner(store).scan(root), second = try scanner(store).scan(root)
        XCTAssertEqual(second.root.allocatedBytes, first.root.allocatedBytes)
        XCTAssertEqual(second.hardLinksSkipped, 1)
        XCTAssertGreaterThan(second.scanReuse?.reusedFolders ?? 0, 0)
    }
    func testNewSessionRevokesOldWriterAndLocalInvalidationUpdatesWithoutJournalEvent() throws {
        let file = try write("file")
        let store = try FileTreeStore(directory: directory)
        _ = try scanner(store).scan(root)
        let old = try store.begin(root.path), node = try XCTUnwrap(store.node(root.path))
        _ = try store.begin(root.path)
        XCTAssertThrowsError(try store.put(node, token: old))
        _ = try scanner(store).scan(root)
        try Data(repeating: 3, count: 20 * 4096).write(to: file)
        try store.invalidate([file.path])
        let report = try scanner(store).scan(root)
        XCTAssertEqual(report.root.allocatedBytes, try DiskScanner().scan(root).root.allocatedBytes)
    }
    func testImportOfOldReportPreservesKnownSizesWithoutTrustingIncompleteTree() throws {
        try write("deep/file", blocks: 4)
        let report = try DiskScanner().scan(root)
        let store = try FileTreeStore(directory: directory)
        try store.discover(root)
        try store.seed(report); try store.discover(root)
        XCTAssertEqual(try store.page(root.path)?.folder.allocatedBytes, report.root.allocatedBytes)
        XCTAssertNil(try store.cursor(root.path))
        XCTAssertFalse(try XCTUnwrap(store.node(root.path)).reusable)
    }
    func testDirectoryReplacementInvalidatesEveryOldDescendant() throws {
        try write("folder/same", blocks: 1)
        let store = try FileTreeStore(directory: directory)
        _ = try scanner(store).scan(root)
        // Keep the old inode alive, ensuring that the replacement has a new identity.
        try FileManager.default.moveItem(at: root.appendingPathComponent("folder"), to: temporary.appendingPathComponent("old"))
        try write("folder/same", blocks: 30)
        let report = try scanner(store, changes: [JournalChange(path: root.appendingPathComponent("folder").path, recursive: false)]).scan(root)
        XCTAssertEqual(report.root.allocatedBytes, try DiskScanner().scan(root).root.allocatedBytes)
        XCTAssertEqual(try store.page(root.appendingPathComponent("folder").path)?.entries.first?.allocatedBytes, 30 * 4096)
    }
    func testCompleteFolderCanBeBrowsedAfterFilesystemBecomesUnavailable() throws {
        try write("folder/file", blocks: 4)
        let store = try FileTreeStore(directory: directory)
        let report = try scanner(store).scan(root)
        try FileManager.default.removeItem(at: root)
        try store.discoverIfNeeded(root)
        XCTAssertEqual(try store.page(root.path)?.folder.allocatedBytes, report.root.allocatedBytes)
        XCTAssertEqual(try store.page(root.path)?.entries.first?.name, "folder")
    }
    func testSeparateChildMeasurementKeepsParentKnowledgeAndUpdatesAncestorTotals() throws {
        let file = try write("changed/deep/file")
        for n in 0..<40 { try write("stable/file\(n)", blocks: 2) }
        let store = try FileTreeStore(directory: directory)
        _ = try scanner(store).scan(root)
        try Data(repeating: 9, count: 20 * 4096).write(to: file)
        _ = try scanner(store, changes: [JournalChange(path: file.path, recursive: false)]).scan(root.appendingPathComponent("changed"))
        XCTAssertTrue(store.hasContinuousHistory(root.path))
        let parent = try scanner(store).scan(root)
        XCTAssertEqual(parent.root.allocatedBytes, try DiskScanner().scan(root).root.allocatedBytes)
        XCTAssertLessThan(parent.scanReuse?.inspectedItems ?? .max, 10)
    }
    func testUnicodeCanonicalFormsConnectFilesToTheirParentAndEvents() throws {
        let file = try write("Ещё глубже/Край/Файл", blocks: 2)
        let store = try FileTreeStore(directory: directory)
        _ = try scanner(store).scan(root)
        let composed = file.deletingLastPathComponent().path.precomposedStringWithCanonicalMapping
        let decomposed = composed.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        XCTAssertEqual(try store.page(composed)?.entries.count, 1)
        XCTAssertEqual(try store.page(decomposed)?.entries.count, 1)
        try Data(repeating: 4, count: 20 * 4096).write(to: file)
        let changed = JournalChange(path: file.path.decomposedStringWithCanonicalMapping, recursive: false)
        let updated = try scanner(store, changes: [changed]).scan(root)
        XCTAssertEqual(updated.root.allocatedBytes, try DiskScanner().scan(root).root.allocatedBytes)
        XCTAssertEqual(try store.page(composed)?.entries.first?.allocatedBytes, 20 * 4096)
        XCTAssertEqual(try store.page(decomposed)?.entries.first?.allocatedBytes, 20 * 4096)
    }
    func testLegacyUnicodeIndexMigratesWithoutLosingKnownMeasurements() throws {
        try write("Ещё глубже/Файл", blocks: 5)
        var store: FileTreeStore? = try FileTreeStore(directory: directory)
        let report = try scanner(store!).scan(root)
        store = nil
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(directory.appendingPathComponent("file-tree.sqlite").path, &database), SQLITE_OK)
        let sql = "UPDATE entries SET parent=replace(parent,'ё','ё'); PRAGMA user_version=0;"
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        let migrated = try FileTreeStore(directory: directory)
        XCTAssertEqual(try migrated.page(root.appendingPathComponent("Ещё глубже").path)?.entries.count, 1)
        XCTAssertEqual(try migrated.page(root.path)?.folder.allocatedBytes, report.root.allocatedBytes)
        XCTAssertFalse(migrated.hasContinuousHistory(root.path))
    }
    func testRealJournalUpdatesFullIndexAndReusesUntouchedFiles() throws {
        // macOS may omit its temporary directories from persistent FSEvents history.
        try FileManager.default.removeItem(at: temporary)
        temporary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/tree-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = try write("changed/deep/file", blocks: 1)
        for n in 0..<80 { try write("stable/file\(n)", blocks: 1) }
        let store = try FileTreeStore(directory: directory)
        _ = try DiskScanner(treeStore: store).scan(root)
        XCTAssertTrue(store.hasContinuousHistory(root.path))
        for n in 2...4 {
            try Data(repeating: 8, count: n * 4096).write(to: file)
            let updated = try DiskScanner(treeStore: store).scan(root)
            XCTAssertEqual(updated.root.allocatedBytes, try DiskScanner().scan(root).root.allocatedBytes)
            XCTAssertLessThan(updated.scanReuse?.inspectedItems ?? .max, 20)
            XCTAssertEqual(try store.page(file.deletingLastPathComponent().path)?.entries.first?.allocatedBytes, Int64(n * 4096))
        }
    }
}
