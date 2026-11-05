import XCTest
import Foundation
@testable import DiskLensCore
@testable import DiskLens

final class AgentSafetyTests: XCTestCase {
    @MainActor
    func testPrepareKeepsQuestionUntilExplicitSendAndUsesFocusedPrompt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("fixture".utf8).write(to: folder.appendingPathComponent("selected.txt"))
        try Data("other".utf8).write(to: folder.appendingPathComponent("unrelated.txt"))
        let report = try DiskScanner().scan(folder)
        let selected = try XCTUnwrap(report.root.children.first { $0.name == "selected.txt" })
        let model = AppModel(scanHistory: ScanHistoryStore(directory: folder.appendingPathComponent("history")))
        model.report = report
        var settings = AgentSettings(); settings.mode = .command; settings.executable = "/bin/cat"
        model.settings = settings
        model.recommendations = "Старый общий ответ"
        model.recommendationDate = Date()
        model.prepareAnalysis(for: selected)
        XCTAssertEqual(model.pane, .assistant)
        XCTAssertEqual(model.analysisEntry?.path, selected.path)
        XCTAssertFalse(model.analyzing)
        XCTAssertTrue(model.recommendations.isEmpty)
        XCTAssertNil(model.recommendationDate)
        model.analyze()
        XCTAssertTrue(model.analyzing)
        model.prepareAnalysis(for: nil)
        XCTAssertEqual(model.analysisEntry?.path, selected.path)
        for _ in 0..<150 {
            if !model.analyzing { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(model.analyzing)
        XCTAssertNil(model.message)
        XCTAssertEqual(model.recommendations, try report.agentPrompt(focusedOn: selected))
        XCTAssertFalse(model.recommendations.contains("unrelated.txt"))
        model.prepareAnalysis(for: nil)
        XCTAssertNil(model.analysisEntry)
        XCTAssertTrue(model.recommendations.isEmpty)
    }

    @MainActor
    func testLockedWorkDoesNotChangeAnalysisObject() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-safety-" + UUID().uuidString)
        let model = AppModel(scanHistory: ScanHistoryStore(directory: folder))
        model.scanning = true
        model.pane = .files
        model.prepareAnalysis(for: nil)
        XCTAssertEqual(model.pane, .files)
        model.scanning = false; model.removing = true
        model.prepareAnalysis(for: nil)
        XCTAssertEqual(model.pane, .files)
    }
}
