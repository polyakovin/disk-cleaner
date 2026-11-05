import XCTest
import Foundation
@testable import DiskLensCore
@testable import DiskLens

private final class HeldDetailScan: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = false
    var hasStarted: Bool { lock.lock(); defer { lock.unlock() }; return started }
    func run(_ root: URL, _ flag: CancellationFlag) throws -> DiskReport {
        let report = try DiskScanner().scan(root)
        lock.lock(); started = true; lock.unlock()
        release.wait()
        return report
    }
}

final class AnalysisDetailsTests: XCTestCase {
    private var temporary: URL!
    private var work: URL { temporary.appendingPathComponent("work") }
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-detail-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: work.appendingPathComponent("day-01/frames"), withIntermediateDirectories: true)
        try Data("synthetic image".utf8).write(to: work.appendingPathComponent("day-01/frames/0001.png"))
        try Data("other".utf8).write(to: temporary.appendingPathComponent("unrelated.txt"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func shallowReport() throws -> DiskReport {
        var config = ScannerConfiguration(); config.retainedDepth = 1
        return try DiskScanner(configuration: config).scan(temporary)
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "Timed out waiting for analysis preparation")
    }

    @MainActor func testShallowFolderIsRefinedBeforeExplicitSendAndMainReportIsPreserved() async throws {
        let original = try shallowReport()
        let selected = try XCTUnwrap(original.root.children.first { $0.name == "work" })
        XCTAssertTrue(selected.children.isEmpty)
        let model = AppModel(scanHistory: ScanHistoryStore(directory: temporary.appendingPathComponent("history")))
        model.report = original
        var settings = AgentSettings(); settings.mode = .command; settings.executable = "/bin/cat"
        model.settings = settings
        model.prepareAnalysis(for: selected)
        XCTAssertTrue(model.preparingAnalysis)
        model.analyze()
        XCTAssertFalse(model.analyzing, "Sending is blocked until the detailed preview is ready")
        try await waitUntil { !model.preparingAnalysis }
        XCTAssertFalse(model.analyzing, "Local preparation must never send the report automatically")
        XCTAssertTrue(model.recommendations.isEmpty)
        XCTAssertEqual(model.analysisReport?.root.path, work.path)
        XCTAssertEqual(model.report?.root.path, original.root.path)
        XCTAssertEqual(model.report?.measuredAt, original.measuredAt)
        XCTAssertTrue(model.analysisPrompt.contains("0001.png"))
        XCTAssertFalse(model.analysisPrompt.contains("unrelated.txt"))
        let reviewedPrompt = model.analysisPrompt
        model.analyze()
        try await waitUntil { !model.analyzing }
        XCTAssertEqual(model.recommendations, reviewedPrompt)
        XCTAssertNil(model.message)
    }

    @MainActor func testCancelledLateRefinementCannotReplaceAnotherSelection() async throws {
        let held = HeldDetailScan(); defer { held.release.signal() }
        let original = try shallowReport()
        let selected = try XCTUnwrap(original.root.children.first { $0.name == "work" })
        let other = try XCTUnwrap(original.root.children.first { $0.name == "unrelated.txt" })
        let model = AppModel(scanHistory: ScanHistoryStore(directory: temporary.appendingPathComponent("history")),
                             detailScanOperation: { try held.run($0, $1) })
        model.report = original
        model.prepareAnalysis(for: selected)
        try await waitUntil { held.hasStarted }
        model.cancelAnalysis()
        XCTAssertFalse(model.preparingAnalysis)
        model.prepareAnalysis(for: other)
        let prompt = model.analysisPrompt
        held.release.signal()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.analysisEntry?.path, other.path)
        XCTAssertEqual(model.analysisPrompt, prompt)
        XCTAssertFalse(model.analyzing)
        XCTAssertNil(model.message)
    }

    @MainActor func testFailedRefinementKeepsOriginalPreview() async throws {
        let original = try shallowReport()
        let selected = try XCTUnwrap(original.root.children.first { $0.name == "work" })
        let model = AppModel(scanHistory: ScanHistoryStore(directory: temporary.appendingPathComponent("history")),
                             detailScanOperation: { _, _ in throw CocoaError(.fileReadNoPermission) })
        model.report = original
        model.prepareAnalysis(for: selected)
        try await waitUntil { !model.preparingAnalysis }
        XCTAssertEqual(model.analysisReport?.measuredAt, original.measuredAt)
        XCTAssertEqual(model.analysisEntry?.path, selected.path)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.analyzing)
    }
}
