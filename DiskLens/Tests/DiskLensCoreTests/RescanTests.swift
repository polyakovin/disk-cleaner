import XCTest
import Foundation
import Darwin
@testable import DiskLensCore

final class RescanTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("scan") }
    private var live: ScannerConfiguration {
        var value = ScannerConfiguration()
        value.progressInterval = 0
        return value
    }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-rescan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    @discardableResult private func write(_ relative: String, blocks: Int) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 42, count: blocks * 4096).write(to: url)
        return url
    }

    func testRescanVisitsKnownHeavyFoldersFirstAndStillFindsNewData() throws {
        let linked = try write("largest/blob", blocks: 60)
        try write("second/blob", blocks: 35)
        try write("small/blob", blocks: 5)
        try FileManager.default.linkItem(at: linked, to: root.appendingPathComponent("second/link"))
        let previous = try DiskScanner().scan(root)
        try write("new-largest/blob", blocks: 200)
        try write("largest/added", blocks: 10)
        var visited: [String] = []
        let result = try DiskScanner(configuration: live, previousReport: previous) { update in
            let path = URL(fileURLWithPath: update.currentPath)
            if path.deletingLastPathComponent().path == self.root.path, !visited.contains(path.lastPathComponent) {
                visited.append(path.lastPathComponent)
            }
        }.scan(root)
        XCTAssertEqual(Array(visited.prefix(2)), ["largest", "second"])
        XCTAssertTrue(visited.contains("new-largest"))
        XCTAssertTrue(visited.contains("small"))
        XCTAssertEqual(result.root.allocatedBytes, try DiskScanner().scan(root).root.allocatedBytes)
        XCTAssertEqual(result.root.fileCount, 5)
        XCTAssertEqual(result.hardLinksSkipped, 1)
        XCTAssertEqual(result.root.children.first?.name, "new-largest")
        XCTAssertFalse(result.isPartial)
    }

    func testNestedPriorityAndSeparateSubfolderScan() throws {
        try write("container/big/blob", blocks: 95)
        try write("container/small/blob", blocks: 5)
        let previous = try DiskScanner().scan(root)
        let container = root.appendingPathComponent("container")
        var firstChild: String?
        let result = try DiskScanner(configuration: live, previousReport: previous) { update in
            if firstChild == nil, URL(fileURLWithPath: update.currentPath).deletingLastPathComponent() == container {
                firstChild = URL(fileURLWithPath: update.currentPath).lastPathComponent
            }
        }.scan(container)
        XCTAssertEqual(firstChild, "big")
        XCTAssertEqual(result.root.fileCount, 2)
    }

    func testChangedNestedFileIsMeasuredEvenWhenFolderMetadataIsUnchanged() throws {
        let file = try write("container/deep/blob", blocks: 1)
        let parent = file.deletingLastPathComponent()
        var before = stat()
        XCTAssertEqual(lstat(parent.path, &before), 0)
        let previous = try DiskScanner().scan(root)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(repeating: 55, count: 40 * 4096))
        try handle.close()
        var after = stat()
        XCTAssertEqual(lstat(parent.path, &after), 0)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        let result = try DiskScanner(previousReport: previous).scan(root)
        XCTAssertGreaterThan(result.root.allocatedBytes, previous.root.allocatedBytes)
        XCTAssertEqual(result.root.logicalBytes, 40 * 4096)
    }

    func testDeletedRenamedAndSymlinkReplacementsAreNotReused() throws {
        try write("deleted/blob", blocks: 100)
        try write("replaced/blob", blocks: 90)
        try write("renamed/blob", blocks: 80)
        let previous = try DiskScanner().scan(root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("deleted"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("replaced"))
        let outside = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 500 * 4096).write(to: outside.appendingPathComponent("not-scanned"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("replaced"), withDestinationURL: outside)
        try FileManager.default.moveItem(at: root.appendingPathComponent("renamed"), to: root.appendingPathComponent("new-name"))
        let result = try DiskScanner(previousReport: previous).scan(root)
        XCTAssertFalse(result.isPartial)
        XCTAssertEqual(result.root.fileCount, 1)
        XCTAssertFalse(result.root.children.contains { $0.name == "deleted" || $0.name == "renamed" })
        XCTAssertEqual(result.root.children.first { $0.name == "replaced" }?.kind, .symlink)
        XCTAssertEqual(result.root.allocatedBytes, try DiskScanner().scan(root).root.allocatedBytes)
    }

    func testLiveSnapshotsContainGrowingFoldersFilesAndDisjointCaches() throws {
        for i in 1...10 { try write("Library/Caches/nested/Library/Caches/blob\(i)", blocks: i) }
        try write("other/blob", blocks: 2)
        var updates: [ScanProgress] = []
        let result = try DiskScanner(configuration: live) { updates.append($0) }.scan(root)
        let during = try XCTUnwrap(updates.first { $0.report.candidateBytes > 0 && $0.report.root.fileCount < result.root.fileCount })
        XCTAssertFalse(during.report.largestFiles.isEmpty)
        XCTAssertFalse(during.largestFolders.isEmpty)
        XCTAssertEqual(during.report.candidates.count, 1)
        XCTAssertTrue(try XCTUnwrap(during.report.candidates.first).entry.path.hasSuffix("/Library/Caches"))
        XCTAssertGreaterThan(during.report.candidateBytes, 0)
        XCTAssertLessThan(during.report.candidateBytes, result.candidateBytes)
        for update in updates {
            XCTAssertTrue(update.report.isPartial)
            XCTAssertTrue(update.report.inProgress == true)
            XCTAssertFalse(update.report.cancelled)
            XCTAssertEqual(update.report.root.allocatedBytes, update.allocatedBytes)
            XCTAssertLessThanOrEqual(update.report.candidateBytes, update.allocatedBytes)
            XCTAssertEqual(update.largestFolders.map(\.allocatedBytes), update.largestFolders.map(\.allocatedBytes).sorted(by: >))
            for a in update.largestFolders {
                XCTAssertNotEqual(a.path, root.path)
                XCTAssertFalse(update.largestFolders.contains { $0.path.hasPrefix(a.path + "/") })
            }
        }
        XCTAssertEqual(updates.map(\.revision), Array(1...updates.count))
        XCTAssertEqual(updates.map(\.allocatedBytes), updates.map(\.allocatedBytes).sorted())
        XCTAssertEqual(updates.last?.report.root.allocatedBytes, result.root.allocatedBytes)
        XCTAssertEqual(updates.last?.report.candidateBytes, result.candidateBytes)
        XCTAssertFalse(result.isPartial)
    }

    func testCancellationDuringLiveCandidateKeepsPartialSizes() throws {
        for i in 1...20 { try write("Library/Caches/blob\(i)", blocks: 1) }
        let flag = CancellationFlag()
        var observed: ScanProgress?
        let result = try DiskScanner(configuration: live, cancellation: flag) { update in
            if update.report.candidates.first?.entry.fileCount ?? 0 > 0, observed == nil {
                observed = update
                flag.cancel()
            }
        }.scan(root)
        XCTAssertNotNil(observed)
        XCTAssertTrue(result.isPartial)
        XCTAssertTrue(result.cancelled)
        XCTAssertEqual(result.root.fileCount, 1)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testHistorySurvivesRestartAndDoesNotReplaceCompleteBaselineWithCancellation() throws {
        try write("Library/Caches/blob", blocks: 10)
        let storeURL = temporary.appendingPathComponent("history")
        let store = ScanHistoryStore(directory: storeURL)
        XCTAssertNil(try store.load())
        let complete = try DiskScanner().scan(root)
        try store.save(complete)
        let reloaded = try XCTUnwrap(ScanHistoryStore(directory: storeURL).load())
        XCTAssertEqual(reloaded.root.path, complete.root.path)
        XCTAssertEqual(reloaded.root.allocatedBytes, complete.root.allocatedBytes)
        let flag = CancellationFlag(); flag.cancel()
        try store.save(DiskScanner(cancellation: flag).scan(root))
        XCTAssertEqual(try store.load()?.scannedItems, complete.scannedItems)
        let attributes = try FileManager.default.attributesOfItem(atPath: storeURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let file = storeURL.appendingPathComponent("last-scan.json")
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try Data("corrupt".utf8).write(to: file)
        XCTAssertThrowsError(try store.load())
    }

    func testPartialFirstScanCanStillSupplyPriorities() throws {
        try write("Library/Caches/blob", blocks: 10)
        let closed = root.appendingPathComponent("closed")
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: closed.path) }
        let partial = try DiskScanner().scan(root)
        XCTAssertTrue(partial.isPartial)
        let store = ScanHistoryStore(directory: temporary.appendingPathComponent("history"))
        try store.save(partial)
        var prioritized = false
        _ = try DiskScanner(configuration: live, previousReport: store.load()) { update in
            prioritized = prioritized || update.usesPreviousScan
        }.scan(root)
        XCTAssertTrue(prioritized)
    }

    func testReusingScannerResetsTotalsAndHardLinks() throws {
        let file = try write("folder/blob", blocks: 10)
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent("link"))
        let scanner = DiskScanner()
        let first = try scanner.scan(root)
        let second = try scanner.scan(root)
        XCTAssertEqual(first.root.allocatedBytes, second.root.allocatedBytes)
        XCTAssertEqual(first.scannedItems, second.scannedItems)
        XCTAssertEqual(second.hardLinksSkipped, 1)
    }
}
