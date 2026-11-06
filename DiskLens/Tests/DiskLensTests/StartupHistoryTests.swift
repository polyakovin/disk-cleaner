import XCTest
import Foundation
@testable import DiskLensCore
@testable import DiskLens

final class StartupHistoryTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("scan") }
    private var history: ScanHistoryStore { ScanHistoryStore(directory: temporary.appendingPathComponent("history")) }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-startup-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        let cache = root.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 8192).write(to: cache.appendingPathComponent("fixture"))
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    @MainActor func testCompletedScanRestoresOnNextLaunchEvenWhenFolderIsUnavailable() async throws {
        let original = AppModel(scanHistory: history)
        original.setTarget(root)
        original.scan()
        let deadline = Date().addingTimeInterval(10)
        while original.scanning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(original.scanning)
        XCTAssertNil(original.message)
        let saved = try XCTUnwrap(original.report)
        XCTAssertFalse(saved.largestFiles.isEmpty)
        XCTAssertFalse(saved.candidates.isEmpty)
        // Opening the app must use the saved metadata, even for a disconnected folder.
        try FileManager.default.removeItem(at: root)

        let reopened = AppModel(scanHistory: history, scanOperation: { _, _, _, _ in
            XCTFail("Opening the app must not start a scan")
            throw CancellationError()
        })
        XCTAssertEqual(try reopened.displayedReport?.json(), try saved.json())
        XCTAssertEqual(reopened.current?.path, saved.root.path)
        XCTAssertEqual(reopened.target.path, saved.root.path)
        XCTAssertEqual(reopened.pane, .overview)
        XCTAssertTrue(reopened.navigation.isEmpty)
        XCTAssertFalse(reopened.scanning)
        XCTAssertFalse(reopened.analyzing)
        XCTAssertNil(reopened.message)
    }

    @MainActor func testFirstLaunchHasNoReportAndDoesNotCreateHistory() {
        let model = AppModel(scanHistory: history)
        XCTAssertNil(model.displayedReport)
        XCTAssertFalse(model.scanning)
        XCTAssertNil(model.message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.directory.path))
    }

    @MainActor func testOlderReportOnlyHistoryStillOpens() throws {
        let saved = try DiskScanner().scan(root)
        try FileManager.default.createDirectory(at: history.directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: history.directory.appendingPathComponent("last-scan.json"))
        let model = AppModel(scanHistory: history)
        XCTAssertEqual(try model.displayedReport?.json(), try saved.json())
        XCTAssertEqual(model.target.path, saved.root.path)
        XCTAssertFalse(model.scanning)
        XCTAssertNil(model.message)
    }

    @MainActor func testPartialHistoryRemainsVisiblyPartialOnLaunch() throws {
        var partial = try DiskScanner().scan(root)
        partial.cancelled = true
        try history.save(partial)
        let model = AppModel(scanHistory: history)
        XCTAssertTrue(model.displayedReport?.isPartial == true)
        XCTAssertTrue(model.displayedReport?.cancelled == true)
        XCTAssertEqual(model.target.path, root.path)
        XCTAssertFalse(model.scanning)
    }

    @MainActor func testCorruptHistoryShowsRecoveryMessageAndPreservesFile() throws {
        try FileManager.default.createDirectory(at: history.directory, withIntermediateDirectories: true)
        let file = history.directory.appendingPathComponent("last-scan.json")
        let corrupt = Data("invalid history".utf8)
        try corrupt.write(to: file)
        let model = AppModel(scanHistory: history)
        XCTAssertNil(model.displayedReport)
        XCTAssertFalse(model.scanning)
        XCTAssertEqual(model.message, "Could not open the last scan. Start a new scan.")
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
}
