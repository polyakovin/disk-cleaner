import XCTest
import Foundation
@testable import DiskLensCore
@testable import DiskLens

final class PermanentRemovalTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("scan") }
    private var history: ScanHistoryStore { ScanHistoryStore(directory: temporary.appendingPathComponent("history")) }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-permanent-tests-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("disposable test fixture".utf8).write(to: url)
        return url
    }
    private func entry(_ url: URL, kind: EntryKind = .file) -> DiskEntry {
        DiskEntry(path: url.path, kind: kind, allocatedBytes: 4096, logicalBytes: 23,
                  fileCount: 1, issueCount: 0, childCount: 0, children: [])
    }
    private func request(_ url: URL, kind: EntryKind = .file) throws -> FileRemovalRequest {
        try FileRemovalRequest(entry: entry(url, kind: kind), scanRoot: root.path, mode: .permanent)
    }
    @MainActor
    private func waitForWork(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while (model.removing || model.scanning) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.removing || model.scanning)
    }

    func testPermanentlyRemovesOnlySelectedFile() throws {
        let source = try file("selected")
        let other = try file("keep")
        let action = try request(source)
        XCTAssertEqual(action.mode, .permanent)
        try action.perform()
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try Data(contentsOf: other), Data("disposable test fixture".utf8))
    }

    func testRemovesEntireFolderIncludingHiddenFilesAndPreservesSymlinkDestination() throws {
        let outside = temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let preserved = outside.appendingPathComponent("keep")
        try Data("preserve".utf8).write(to: preserved)
        _ = try file("folder/nested/.hidden")
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("external-link"), withDestinationURL: outside)
        try request(folder, kind: .folder).perform()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: preserved), Data("preserve".utf8))
    }

    func testRemovesLinkAndBrokenLinkWithoutFollowingThem() throws {
        let destination = try file("keep")
        for (name, target) in [("link", destination), ("broken", root.appendingPathComponent("missing"))] {
            let link = root.appendingPathComponent(name)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            try request(link, kind: .symlink).perform()
            XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testPermanentModeProtectsRootsSystemPathsAndOutsideScan() throws {
        let protected = ["/", "/System/Library", "/usr/bin", "/private/etc",
                         FileManager.default.homeDirectoryForCurrentUser.path,
                         "/System/Volumes/Data" + FileManager.default.homeDirectoryForCurrentUser.path,
                         root.appendingPathComponent(".Trash/item").path]
        for path in protected {
            XCTAssertThrowsError(try FileRemovalRequest(entry: entry(URL(fileURLWithPath: path), kind: .folder), scanRoot: "/", mode: .permanent))
        }
        XCTAssertThrowsError(try request(root, kind: .folder))
        XCTAssertThrowsError(try request(temporary.appendingPathComponent("outside")))
    }

    func testReplacementAndRetargetedParentCannotBeDeleted() throws {
        let source = try file("item")
        let action = try request(source)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("original"))
        _ = try file("item")
        XCTAssertThrowsError(try action.perform())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let first = try file("first/child").deletingLastPathComponent()
        let second = try file("second/child").deletingLastPathComponent()
        let link = root.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        let nestedAction = try request(link.appendingPathComponent("child"))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        XCTAssertThrowsError(try nestedAction.perform())
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.appendingPathComponent("child").path))
    }

    func testAccessFailureThrowsWithoutEscalatingPermissions() throws {
        let source = try file("locked/file")
        let parent = source.deletingLastPathComponent()
        let action = try request(source)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        XCTAssertThrowsError(try action.perform())
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testCancellationAndBusyStateCannotPermanentlyRemove() throws {
        let source = try file("file")
        let model = AppModel(scanHistory: history)
        model.report = try DiskScanner().scan(root)
        model.requestRemoval(entry(source), mode: .permanent)
        XCTAssertEqual(model.pendingRemoval?.mode, .permanent)
        model.requestRemoval(entry(source), mode: .trash)
        XCTAssertEqual(model.pendingRemoval?.mode, .permanent)
        model.scan()
        XCTAssertFalse(model.scanning)
        model.cancelRemoval()
        model.confirmRemoval()
        XCTAssertFalse(model.removing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        model.scanning = true
        model.requestRemoval(entry(source), mode: .permanent)
        XCTAssertNil(model.pendingRemoval)
    }

    @MainActor
    func testActualPermanentRemovalInvalidatesHistoryRecommendationsAndRescans() async throws {
        let source = try file("folder/nested/file").deletingLastPathComponent().deletingLastPathComponent()
        try history.save(DiskScanner().scan(root))
        let model = AppModel(scanHistory: history)
        model.setTarget(URL(fileURLWithPath: "/"))
        model.prepareAnalysis(for: entry(source, kind: .folder))
        model.recommendations = "old recommendations"
        model.requestRemoval(entry(source, kind: .folder), mode: .permanent)
        model.confirmRemoval()
        try await waitForWork(model)
        XCTAssertNil(model.message)
        XCTAssertNil(model.analysisEntry)
        XCTAssertTrue(model.recommendations.isEmpty)
        XCTAssertEqual(model.report?.root.path, root.path)
        XCTAssertEqual(model.report?.root.childCount, 0)
        XCTAssertEqual(try history.load()?.root.childCount, 0)
        XCTAssertEqual(model.removalStatus, "Удалено безвозвратно: «folder».")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    @MainActor
    func testPartialFailureInvalidatesStaleMeasurementsAndKeepsErrorAfterRescan() async throws {
        let removed = try file("folder/removed")
        let retained = try file("folder/retained")
        let folder = retained.deletingLastPathComponent()
        try history.save(DiskScanner().scan(root))
        let model = AppModel(scanHistory: history, removalOperation: { request in
            try request.validate()
            XCTAssertEqual(request.mode, .permanent)
            try FileManager.default.removeItem(at: removed)
            throw CocoaError(.fileWriteNoPermission)
        })
        model.recommendations = "stale"
        model.requestRemoval(entry(folder, kind: .folder), mode: .permanent)
        model.confirmRemoval()
        try await waitForWork(model)
        XCTAssertTrue(model.message?.contains("Не удалось полностью удалить") == true)
        XCTAssertTrue(model.message?.contains("Часть содержимого могла быть удалена") == true)
        XCTAssertEqual(model.report?.root.fileCount, 1)
        XCTAssertEqual(try history.load()?.root.fileCount, 1)
        XCTAssertTrue(model.recommendations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertTrue(model.removalStatus?.contains("Удаление не завершено") == true)
    }
}
