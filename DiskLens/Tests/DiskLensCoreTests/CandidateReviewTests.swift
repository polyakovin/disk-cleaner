import XCTest
@testable import DiskLensCore

final class CandidateReviewTests: XCTestCase {
    private func entry(_ path: String, bytes: Int64 = 4096, children: [DiskEntry] = []) -> DiskEntry {
        DiskEntry(path: path, kind: children.isEmpty ? .file : .folder, allocatedBytes: bytes,
                  logicalBytes: bytes, fileCount: 1, issueCount: 0, childCount: children.count, children: children)
    }
    private func fixture(count: Int = 45) -> DiskReport {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let children = (0..<count).map { entry(home + "/fixture/item-\($0)", bytes: Int64(10000 - $0)) }
        return DiskReport(schemaVersion: 1, measuredAt: Date(), durationSeconds: 1,
                          root: entry(home + "/fixture", children: children), volume: nil, largestFiles: [],
                          candidates: [CleanupCandidate(entry: children[0], reason: "Кэш", caution: "Проверить")],
                          issues: [], issueCount: 0, skippedMounts: [], skippedMountCount: 0,
                          hardLinksSkipped: 0, cancelled: false, scannedItems: count)
    }
    private func json(_ id: String, action: String = "add") -> String {
        """
        {"summary":"Проверить перед очисткой","decisions":[{"id":"\(id)","action":"\(action)","reason":"Кэш","caution":"Закрыть приложение и проверить"}]}
        """
    }

    func testReviewIncludesObjectsOutsideCompactReportAndBoundsPayload() throws {
        let report = fixture(count: 500), review = CandidateReview(report: report)
        XCTAssertEqual(review.entries.count, 401)
        XCTAssertEqual(review.omittedCount, 99)
        XCTAssertEqual(review.entries.first?.path, report.candidates.first?.id)
        let input = try review.data()
        XCTAssertTrue(input.contains("item-399"))
        XCTAssertFalse(input.contains("item-401\""))
        XCTAssertFalse(input.contains(FileManager.default.homeDirectoryForCurrentUser.path))
        XCTAssertFalse(try report.agentData().contains("item-399"))
        XCTAssertEqual(try report.agentData(reviewingCandidates: true), input)
    }

    func testRejectsInventedPathsDuplicateIDsWrongActionsAndProse() throws {
        let review = CandidateReview(report: fixture())
        for text in [json("/tmp/invented"), json("entry-999"), json("entry-01"), json("entry--1"),
                     json("entry-0"), json("entry-1", action: "remove"), "Сначала удалим " + json("entry-1"),
                     "{\"summary\":\"x\",\"decisions\":[{\"id\":\"entry-1\",\"action\":\"add\",\"reason\":\"x\",\"caution\":\"x\"},{\"id\":\"entry-1\",\"action\":\"add\",\"reason\":\"x\",\"caution\":\"x\"}]}"] {
            XCTAssertThrowsError(try review.parse(text), text)
        }
        XCTAssertNoThrow(try review.parse("```json\n" + json("entry-1") + "\n```"))
    }

    func testLargeExistingListStillIncludesOtherScanEntries() {
        var report = fixture(count: 500)
        report.candidates = report.root.children.prefix(450).map { CleanupCandidate(entry: $0, reason: "Кэш", caution: "Проверить") }
        let review = CandidateReview(report: report)
        XCTAssertEqual(review.entries.count, 500)
        XCTAssertEqual(review.omittedCount, 0)
        XCTAssertTrue(review.entries.contains { $0.name == "item-499" })
    }

    func testAnonymizesHomeInDataVolumeAliasesWithoutChangingResolvedIDs() throws {
        var report = fixture()
        let original = report.root.children[1]
        let alias = entry("/System/Volumes/Data" + original.path)
        report.root.children = [alias]; report.candidates = []
        let review = CandidateReview(report: report)
        XCTAssertFalse(try review.data().contains(FileManager.default.homeDirectoryForCurrentUser.path))
        XCTAssertTrue(try review.data().contains("~/fixture/item-1"))
        XCTAssertTrue(try review.data(anonymizeHome: false).contains(alias.path))
        XCTAssertEqual(review.entry(for: "entry-0")?.path, alias.path)
    }

    func testOnlySelectedChangesApplyAndUnmentionedCandidatesStay() throws {
        let report = fixture(), review = CandidateReview(report: report)
        let result = try review.parse(json("entry-1"))
        XCTAssertEqual(try review.applying(result, selectedIDs: []).map(\.id), report.candidates.map(\.id))
        let added = try review.applying(result, selectedIDs: ["entry-1"])
        XCTAssertEqual(added.count, 2)
        XCTAssertEqual(added.last?.id, review.entry(for: "entry-1")?.path)
        XCTAssertTrue(added.last?.reason.hasPrefix("ИИ:") == true)
        let removal = try review.parse(json("entry-0", action: "remove"))
        XCTAssertTrue(try review.applying(removal, selectedIDs: ["entry-0"]).isEmpty)
    }

    func testOverlapsRequireExplicitExclusionOfExistingCandidate() throws {
        var report = fixture()
        let parent = entry(report.root.path + "/cache", bytes: 90000,
                           children: [entry(report.root.path + "/cache/nested", bytes: 80000)])
        report.root.children = [parent]
        report.candidates = [CleanupCandidate(entry: parent.children[0], reason: "Кэш", caution: "Проверить")]
        let review = CandidateReview(report: report)
        XCTAssertEqual(review.entries[0].path, parent.children[0].path)
        let text = """
        {"summary":"Объединить","decisions":[
        {"id":"entry-0","action":"remove","reason":"Вложен","caution":"Родитель включает файлы"},
        {"id":"entry-1","action":"add","reason":"Родитель","caution":"Проверить всё содержимое"}]}
        """
        let result = try review.parse(text)
        XCTAssertThrowsError(try review.applying(result, selectedIDs: ["entry-1"]))
        XCTAssertEqual(try review.applying(result, selectedIDs: ["entry-0", "entry-1"]).map(\.id), [parent.path])
    }

    func testReviewPreviewMatchesBothAPIFormatsAndCommandInput() async throws {
        let report = fixture()
        var settings = AgentSettings(); settings.mode = .api; settings.model = "fixture"
        for format in APIFormat.allCases {
            settings.format = format
            let request = try APIAgent.request(settings: settings, key: "", report: report, reviewingCandidates: true)
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            if format == .responses {
                XCTAssertEqual(body["instructions"] as? String, CandidateReview.instructions)
                XCTAssertEqual(body["input"] as? String, try CandidateReview(report: report).data())
            } else {
                let messages = body["messages"] as! [[String: String]]
                XCTAssertEqual(messages[0]["content"], CandidateReview.instructions)
                XCTAssertEqual(messages[1]["content"], try CandidateReview(report: report).data())
            }
        }
        settings.mode = .command; settings.executable = "/bin/cat"
        let text = try await CommandAgent.analyze(settings: settings, report: report, reviewingCandidates: true, cancellation: .init())
        XCTAssertEqual(text, try report.agentPrompt(reviewingCandidates: true))
    }
}
