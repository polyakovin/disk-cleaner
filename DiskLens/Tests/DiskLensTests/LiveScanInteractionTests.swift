import XCTest
import Foundation
@testable import DiskLensCore
@testable import DiskLens

/// Holds the first worker after it publishes a result, like a delayed filesystem call.
private final class SuspendedScan: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0
    private var returned = false
    var hasReturned: Bool { lock.lock(); defer { lock.unlock() }; return returned }

    func run(_ root: URL, _ flag: CancellationFlag, _ previous: DiskReport?,
             _ progress: @escaping @Sendable (ScanProgress) -> Void) throws -> DiskReport {
        lock.lock(); calls += 1; let first = calls == 1; lock.unlock()
        var configuration = ScannerConfiguration(); configuration.progressInterval = 0
        let result = try DiskScanner(configuration: configuration, cancellation: flag,
                                     previousReport: previous, progress: progress).scan(root)
        if first {
            release.wait()
            lock.lock(); returned = true; lock.unlock()
        }
        return result
    }
}

final class LiveScanInteractionTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("scan") }
    private var history: ScanHistoryStore { ScanHistoryStore(directory: temporary.appendingPathComponent("history")) }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-live-actions-" + UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("folder/file"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for the scan state")
    }

    @MainActor private func startedModel(_ suspended: SuspendedScan) async throws -> AppModel {
        let model = AppModel(scanHistory: history, scanOperation: { try suspended.run($0, $1, $2, $3) })
        model.setTarget(root); model.scan()
        try await waitUntil { model.scanProgress?.report.root.fileCount == 1 }
        return model
    }

    @MainActor func testOpenFolderKeepsUpdatingAndAnalysisUsesReviewedSnapshot() async throws {
        let suspended = SuspendedScan(); defer { suspended.release.signal() }
        let model = try await startedModel(suspended)
        let folder = try XCTUnwrap(model.current?.children.first { $0.isFolder })
        model.navigate(folder)
        XCTAssertEqual(model.current?.path, folder.path)
        XCTAssertEqual(model.current?.fileCount, 1)
        model.prepareAnalysis(for: folder)
        XCTAssertTrue(model.scanning)
        XCTAssertEqual(model.analysisReport?.root.fileCount, 1)

        try Data("new fixture".utf8).write(to: root.appendingPathComponent("folder/added"))
        var updated = try DiskScanner().scan(root); updated.inProgress = true
        model.scanProgress = ScanProgress(revision: 1000, items: updated.scannedItems,
                                           allocatedBytes: updated.root.allocatedBytes, currentPath: root.path,
                                           report: updated, largestFolders: [], usesPreviousScan: false)
        XCTAssertEqual(model.current?.fileCount, 2)
        XCTAssertEqual(model.current?.children.count, 2)
        XCTAssertEqual(model.analysisReport?.root.fileCount, 1, "The reviewed AI request must not change under the user")
        model.cancelScan()
        XCTAssertFalse(model.scanning)
        XCTAssertTrue(model.report?.cancelled == true)
        XCTAssertEqual(model.current?.fileCount, 2)
    }

    @MainActor func testRemovalFromLiveTableStopsScanAndCancelDoesNotRemoveAnything() async throws {
        let suspended = SuspendedScan(); defer { suspended.release.signal() }
        let model = try await startedModel(suspended)
        let folder = try XCTUnwrap(model.current?.children.first { $0.isFolder })
        model.requestRemoval(folder)
        XCTAssertFalse(model.scanning)
        XCTAssertEqual(model.pendingRemoval?.entry.path, folder.path)
        XCTAssertEqual(model.pendingRemoval?.scanRoot, root.path)
        XCTAssertTrue(model.report?.isPartial == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("folder/file").path))
        model.cancelRemoval()
        XCTAssertFalse(model.removing)
        XCTAssertNil(model.pendingRemoval)
    }

    @MainActor func testLateWorkerCannotRestoreRemovedObjectOrHistory() async throws {
        let suspended = SuspendedScan(); defer { suspended.release.signal() }
        let holding = temporary.appendingPathComponent("holding")
        let model = AppModel(scanHistory: history, removalOperation: { request in
            try request.validate()
            try FileManager.default.moveItem(at: URL(fileURLWithPath: request.entry.path), to: holding)
        }, scanOperation: { try suspended.run($0, $1, $2, $3) })
        model.setTarget(root); model.scan()
        try await waitUntil { model.scanProgress?.report.root.fileCount == 1 }
        let folder = try XCTUnwrap(model.current?.children.first { $0.isFolder })
        model.requestRemoval(folder)
        model.confirmRemoval()
        try await waitUntil { !model.removing && !model.scanning }
        XCTAssertEqual(model.report?.root.fileCount, 0)
        XCTAssertEqual(try history.load()?.root.fileCount, 0)
        let acceptedDate = model.report?.measuredAt
        suspended.release.signal()
        try await waitUntil { suspended.hasReturned }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.report?.measuredAt, acceptedDate)
        XCTAssertEqual(model.report?.root.fileCount, 0)
        XCTAssertEqual(try history.load()?.root.fileCount, 0)
        XCTAssertNil(model.message)
    }

    @MainActor func testSeparateFolderScanReplacesSessionWithoutWaitingForOldWorker() async throws {
        let suspended = SuspendedScan(); defer { suspended.release.signal() }
        let model = try await startedModel(suspended)
        let folder = try XCTUnwrap(model.current?.children.first { $0.isFolder })
        model.scanFolder(folder)
        try await waitUntil { !model.scanning }
        XCTAssertEqual(model.report?.root.path, folder.path)
        XCTAssertEqual(model.target.path, folder.path)
        let acceptedDate = model.report?.measuredAt
        suspended.release.signal()
        try await waitUntil { suspended.hasReturned }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.report?.measuredAt, acceptedDate)
        XCTAssertEqual(try history.load()?.root.path, folder.path)
    }
}
