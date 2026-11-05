import XCTest
import Foundation
@testable import DiskLensCore

final class SafetyAssessmentTests: XCTestCase {
    private func entry(_ path: String, children: [DiskEntry] = []) -> DiskEntry {
        DiskEntry(path: path, kind: children.isEmpty ? .file : .folder, allocatedBytes: 8192,
                  logicalBytes: 4000, fileCount: 1, issueCount: 0, childCount: children.count, children: children)
    }

    private func fixture() -> DiskReport {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let children = (0..<40).map { entry(home + "/Downloads/item-\($0)") }
        return DiskReport(schemaVersion: 1, measuredAt: Date(timeIntervalSince1970: 123456), durationSeconds: 1,
                          root: entry(home, children: children), volume: nil, largestFiles: children,
                          candidates: [], issues: [], issueCount: 1, skippedMounts: [], skippedMountCount: 0,
                          hardLinksSkipped: 0, cancelled: true, scannedItems: 40)
    }

    func testFocusSurvivesGeneralReportLimitsAndExcludesUnrelatedPaths() throws {
        let report = fixture(), selected = report.root.children[39]
        XCTAssertFalse(try report.agentData().contains("item-39"))
        let data = try report.agentData(focusedOn: selected)
        let payload = try JSONSerialization.jsonObject(with: Data(data.utf8)) as! [String: Any]
        let metadata = payload["entry"] as! [String: Any]
        XCTAssertEqual(metadata["path"] as? String, "~/Downloads/item-39")
        XCTAssertEqual(metadata["allocatedBytes"] as? Int, 8192)
        XCTAssertEqual(payload["scanIsPartial"] as? Bool, true)
        XCTAssertEqual(payload["scanCancelled"] as? Bool, true)
        XCTAssertNotNil(payload["measuredAt"])
        XCTAssertFalse(data.contains("item-0"))
        XCTAssertFalse(data.contains(FileManager.default.homeDirectoryForCurrentUser.path))
        XCTAssertTrue(try report.agentData(focusedOn: selected, anonymizeHome: false).contains(selected.path))
    }

    func testFocusedFolderBoundsAndAnonymizesDescendantsAndIncludesCacheCaution() throws {
        var report = fixture()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folder = entry(home + "/Library/Caches", children: (0..<20).map { i in
            entry(home + "/Library/Caches/\(i)", children: [
                entry(home + "/Library/Caches/\(i)/nested", children: [entry(home + "/Library/Caches/\(i)/nested/deeper")])
            ])
        })
        report.candidates = [CleanupCandidate(entry: folder, reason: "Кэш", caution: "Потребуется создать заново")]
        let text = try report.agentData(focusedOn: folder)
        let payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let metadata = payload["entry"] as! [String: Any]
        let children = metadata["children"] as! [[String: Any]]
        XCTAssertEqual(metadata["childCount"] as? Int, 20)
        XCTAssertEqual(children.count, 12)
        XCTAssertFalse(text.contains(home))
        XCTAssertFalse(String(describing: metadata).contains("deeper"), "The preview tree stays compact")
        XCTAssertTrue(text.contains("deeper"), "Detailed contents retain useful deeper metadata")
        XCTAssertEqual(payload["candidateCaution"] as? String, "Потребуется создать заново")
        XCTAssertEqual(report.agentInstructions(), AgentInstructions.text)
        XCTAssertNotEqual(report.agentInstructions(focusedOn: folder), AgentInstructions.text)
    }

    func testBothAPIFormatsSendSelectedObjectAndDedicatedInstructions() throws {
        let report = fixture(), selected = report.root.children[39]
        var settings = AgentSettings(); settings.mode = .api; settings.model = "test-model"
        for format in APIFormat.allCases {
            settings.format = format
            let request = try APIAgent.request(settings: settings, key: "", report: report, focusedOn: selected)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let input: String
            let instructions: String
            if format == .responses {
                input = body["input"] as! String; instructions = body["instructions"] as! String
            } else {
                let messages = body["messages"] as! [[String: String]]
                instructions = messages[0]["content"]!; input = messages[1]["content"]!
            }
            XCTAssertEqual(input, try report.agentData(focusedOn: selected))
            XCTAssertEqual(instructions, report.agentInstructions(focusedOn: selected))
            XCTAssertFalse(instructions.contains(selected.path))
        }
    }

    func testCommandTransportUsesSameFocusedPromptAsPreview() async throws {
        let report = fixture(), selected = report.root.children[39]
        var settings = AgentSettings(); settings.mode = .command; settings.executable = "/bin/cat"
        let output = try await CommandAgent.analyze(settings: settings, report: report, focusedOn: selected,
                                                    cancellation: .init(), timeout: 5)
        XCTAssertEqual(output, try report.agentPrompt(focusedOn: selected))
        XCTAssertFalse(output.contains("item-0"))
    }
}
