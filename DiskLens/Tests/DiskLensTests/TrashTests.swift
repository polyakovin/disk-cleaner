import XCTest
import Foundation
@testable import DiskLensCore
@testable import DiskLens

final class TrashTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-trash-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        temporary = temporary.resolvingSymlinksInPath()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func file(_ name: String) throws -> URL {
        let url = temporary.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: url)
        return url
    }
    private func entry(_ url: URL, kind: EntryKind = .file) -> DiskEntry {
        DiskEntry(path: url.path, kind: kind, allocatedBytes: 4096, logicalBytes: 7,
                  fileCount: 1, issueCount: 0, childCount: 0, children: [])
    }

    func testRejectsRootOutsideScanAndSiblingWithSamePrefix() throws {
        let source = try file("file")
        XCTAssertThrowsError(try FileRemovalRequest(entry: entry(temporary, kind: .folder), scanRoot: temporary.path))
        XCTAssertThrowsError(try FileRemovalRequest(entry: entry(source), scanRoot: temporary.appendingPathComponent("other").path))
        XCTAssertThrowsError(try FileRemovalRequest(entry: entry(source), scanRoot: String(temporary.path.dropLast())))
        XCTAssertNoThrow(try FileRemovalRequest(entry: entry(source), scanRoot: temporary.path).validate())
    }

    func testProtectsHomeSystemTreesTrashAndAPFSAliases() {
        let paths = ["/", "/System", "/System/Library", "/usr/bin", "/Applications", "/Users",
                     FileManager.default.homeDirectoryForCurrentUser.path,
                     "/System/Volumes/Data" + FileManager.default.homeDirectoryForCurrentUser.path,
                     "/System/Volumes/Data/usr/bin", "/System/Volumes/Data/Library",
                     temporary.appendingPathComponent(".Trash/item").path]
        for path in paths {
            XCTAssertThrowsError(try FileRemovalRequest(entry: entry(URL(fileURLWithPath: path), kind: .folder), scanRoot: "/"), path)
        }
    }

    func testDetectsReplacementAndMissingItemBeforeTrash() throws {
        let source = try file("file")
        let request = try FileRemovalRequest(entry: entry(source), scanRoot: temporary.path)
        try FileManager.default.moveItem(at: source, to: temporary.appendingPathComponent("original"))
        _ = try file("file")
        XCTAssertThrowsError(try request.moveToTrash())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.removeItem(at: source)
        XCTAssertThrowsError(try request.moveToTrash())
    }

    func testSymlinkIsCapturedWithoutFollowingDestinationAndParentRetargetIsRejected() throws {
        let destination = try file("destination")
        let link = temporary.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        XCTAssertNoThrow(try FileRemovalRequest(entry: entry(link, kind: .symlink), scanRoot: temporary.path).validate())
        XCTAssertThrowsError(try FileRemovalRequest(entry: entry(link, kind: .file), scanRoot: temporary.path))
        let first = temporary.appendingPathComponent("first")
        let second = temporary.appendingPathComponent("second")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data().write(to: folder.appendingPathComponent("item"))
        }
        let parent = temporary.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: first)
        let request = try FileRemovalRequest(entry: entry(parent.appendingPathComponent("item")), scanRoot: temporary.path)
        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: second)
        XCTAssertThrowsError(try request.moveToTrash())
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertThrowsError(try FileRemovalRequest(entry: entry(parent.appendingPathComponent("item")), scanRoot: first.path))
    }

    func testHistoryClearInvalidatesCompleteBaselineAndIsIdempotent() throws {
        _ = try file("file")
        let history = ScanHistoryStore(directory: temporary.appendingPathComponent("history"))
        try history.save(DiskScanner().scan(temporary))
        XCTAssertNotNil(try history.load())
        try history.clear()
        XCTAssertNil(try history.load())
        XCTAssertNoThrow(try history.clear())
    }

    @MainActor
    func testCancelAndConcurrentActionsNeverDelete() throws {
        let source = try file("file")
        let model = AppModel(scanHistory: ScanHistoryStore(directory: temporary.appendingPathComponent("history")))
        model.report = try DiskScanner().scan(temporary)
        model.setTarget(temporary)
        model.requestRemoval(entry(source))
        XCTAssertNotNil(model.pendingRemoval)
        model.scan()
        model.setTarget(URL(fileURLWithPath: "/"))
        XCTAssertFalse(model.scanning)
        XCTAssertEqual(model.target, temporary)
        model.cancelRemoval()
        model.confirmRemoval()
        XCTAssertFalse(model.removing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        model.scanning = true
        model.requestRemoval(entry(source))
        XCTAssertNil(model.pendingRemoval)
        model.scanning = false
        model.removing = true
        model.requestRemoval(entry(source))
        model.scan()
        XCTAssertNil(model.pendingRemoval)
        XCTAssertFalse(model.scanning)
    }

    @MainActor
    func testFailurePreservesReportAndShowsError() async throws {
        let source = try file("file")
        let model = AppModel(scanHistory: ScanHistoryStore(directory: temporary.appendingPathComponent("history")))
        model.report = try DiskScanner().scan(temporary)
        model.requestRemoval(entry(source))
        try FileManager.default.removeItem(at: source)
        model.confirmRemoval()
        let deadline = Date().addingTimeInterval(5)
        while model.removing && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.removing)
        XCTAssertNotNil(model.report)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.scanning)
        XCTAssertNil(model.pendingRemoval)
    }

    @MainActor
    func testSuccessfulActionInvalidatesHistoryAndRescansOriginalRoot() async throws {
        let source = try file("file")
        let history = ScanHistoryStore(directory: temporary.appendingPathComponent("history"))
        let saved = try DiskScanner().scan(temporary)
        try history.save(saved)
        let holdingArea = temporary.appendingPathComponent("test-only-holding-area")
        try FileManager.default.createDirectory(at: holdingArea, withIntermediateDirectories: true)
        let model = AppModel(scanHistory: history, removalOperation: { request in
            try request.validate()
            try FileManager.default.moveItem(at: URL(fileURLWithPath: request.entry.path),
                                             to: holdingArea.appendingPathComponent("moved"))
        })
        // A different selected target must not redirect the post-deletion rescan.
        model.setTarget(URL(fileURLWithPath: "/"))
        model.recommendations = "old recommendations"
        model.requestRemoval(entry(source))
        model.confirmRemoval()
        let deadline = Date().addingTimeInterval(5)
        while (model.removing || model.scanning) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.removing || model.scanning)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.report?.root.path, temporary.path)
        XCTAssertFalse(model.report?.root.children.contains { $0.path == source.path } ?? true)
        XCTAssertFalse(try history.load()?.root.children.contains { $0.path == source.path } ?? true)
        XCTAssertTrue(model.recommendations.isEmpty)
        XCTAssertNotNil(model.removalStatus)
    }

    func testSystemTrashMovesFileFolderAndSymlinkAndAllowsRestoring() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISKLENS_TEST_SYSTEM_TRASH"] == "1",
                          "Opt-in integration test: uses and restores only generated fixtures in macOS Trash.")
        let source = try file("DiskLens-file-" + UUID().uuidString)
        let folder = temporary.appendingPathComponent("DiskLens-folder-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested fixture".utf8).write(to: folder.appendingPathComponent("nested"))
        let link = temporary.appendingPathComponent("DiskLens-link-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        for (url, kind) in [(link, EntryKind.symlink), (folder, .folder), (source, .file)] {
            let request = try FileRemovalRequest(entry: entry(url, kind: kind), scanRoot: temporary.path)
            let destination = try XCTUnwrap(request.moveToTrash())
            var restored = false
            defer { if !restored { try? FileManager.default.moveItem(at: destination, to: url) } }
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            if kind == .symlink {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), source.path)
                XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
            } else if kind == .folder {
                XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("nested").path))
            } else {
                XCTAssertEqual(try Data(contentsOf: destination), Data("fixture".utf8))
            }
            try FileManager.default.moveItem(at: destination, to: url)
            restored = true
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
