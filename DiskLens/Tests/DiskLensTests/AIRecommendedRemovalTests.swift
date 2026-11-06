import XCTest
@testable import DiskLensCore
@testable import DiskLens

final class AIRecommendedRemovalTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("scan") }
    private var history: ScanHistoryStore { ScanHistoryStore(directory: temporary.appendingPathComponent("history")) }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-ai-removal-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["approved", "excluded", "unmentioned", "additional"] {
            try Data("fixture".utf8).write(to: root.appendingPathComponent(name))
        }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    @MainActor
    private func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while (model.analyzing || model.removing || model.scanning) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.analyzing || model.removing || model.scanning)
    }

    @MainActor
    private func reviewedModel(removalOperation: @escaping @Sendable (FileRemovalRequest) throws -> Void = { try $0.perform() }) async throws -> AppModel {
        let model = AppModel(scanHistory: history, removalOperation: removalOperation)
        var report = try DiskScanner().scan(root)
        report.candidates = ["approved", "excluded", "unmentioned"].map { name in
            CleanupCandidate(entry: report.root.children.first { $0.name == name }!, reason: "Кэш", caution: "Проверить")
        }
        model.report = report
        model.prepareCandidateReview()
        let review = CandidateReview(report: report)
        let decisions = try [("approved", "keep"), ("excluded", "remove"), ("additional", "add")].map { name, action -> [String: String] in
            let index = try XCTUnwrap(review.entries.firstIndex { $0.name == name })
            return ["id": "entry-\(index)", "action": action, "reason": "Тестовая рекомендация", "caution": "Проверить содержимое"]
        }
        let response = String(decoding: try JSONSerialization.data(withJSONObject: ["summary": "Тест", "decisions": decisions]), as: UTF8.self)
        var settings = AgentSettings()
        settings.mode = .command; settings.executable = "/bin/echo"
        settings.argumentsJSON = String(decoding: try JSONEncoder().encode([response]), as: UTF8.self)
        model.settings = settings
        model.analyze()
        try await wait(model)
        XCTAssertNotNil(model.candidateReviewResult)
        return model
    }

    @MainActor
    func testSeparateConfirmationExcludesUnmentionedAndRejectedCandidates() async throws {
        let model = try await reviewedModel()
        model.search = "unmentioned"
        model.requestAIRecommendedRemoval()
        let request = try XCTUnwrap(model.pendingCandidateRemoval)
        XCTAssertEqual(request.scope, .aiRecommended)
        XCTAssertEqual(request.mode, .trash)
        XCTAssertEqual(Set(request.requests.map { $0.entry.name }), ["approved", "additional"])
        XCTAssertEqual(model.report?.candidates.count, 3, "Opening confirmation must not apply list changes")
        model.cancelCandidateRemoval()
        model.confirmCandidateRemoval()
        XCTAssertFalse(model.removing)
        for name in ["approved", "excluded", "unmentioned", "additional"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
        }
    }

    @MainActor
    func testUncheckedAdditionIsExcludedAndAllCandidatesActionRemainsSeparate() async throws {
        let model = try await reviewedModel()
        let addition = try XCTUnwrap(model.candidateReviewResult?.decisions.first { $0.action == .add })
        model.selectedReviewIDs.remove(addition.id)
        model.requestAIRecommendedRemoval()
        XCTAssertEqual(model.pendingCandidateRemoval?.requests.map { $0.entry.name }, ["approved"])
        model.cancelCandidateRemoval()
        model.requestCandidateRemoval()
        XCTAssertEqual(model.pendingCandidateRemoval?.scope, .allCandidates)
        XCTAssertEqual(Set(model.pendingCandidateRemoval?.requests.map { $0.entry.name } ?? []), ["approved", "excluded", "unmentioned"])
    }

    @MainActor
    func testRecommendationsRemainSeparateAfterApplyingAndChangingAssistantMode() async throws {
        let model = try await reviewedModel()
        model.applyCandidateReview()
        XCTAssertEqual(Set(model.report?.candidates.map { $0.entry.name } ?? []), ["approved", "unmentioned", "additional"])
        XCTAssertNil(model.candidateReviewResult)
        model.prepareAnalysis(for: nil)
        model.requestAIRecommendedRemoval()
        XCTAssertEqual(Set(model.pendingCandidateRemoval?.requests.map { $0.entry.name } ?? []), ["approved", "additional"])
    }

    @MainActor
    func testConfirmationProcessesOnlyRecommendedObjectsAndRescans() async throws {
        // Simulate Trash inside this test's temporary directory, without touching the user's Trash.
        let trash = temporary.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let model = try await reviewedModel { request in
            XCTAssertEqual(request.mode, .trash)
            try request.validate()
            try FileManager.default.moveItem(at: URL(fileURLWithPath: request.entry.path),
                                            to: trash.appendingPathComponent(request.entry.name))
        }
        model.requestAIRecommendedRemoval()
        model.confirmCandidateRemoval()
        try await wait(model)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["excluded", "unmentioned"])
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: trash.path)), ["approved", "additional"])
        XCTAssertEqual(model.report?.root.fileCount, 2)
        XCTAssertEqual(model.removalStatus, "Moved to Trash: 2 of 2.")
        XCTAssertTrue(model.aiRecommendedCandidates.isEmpty)
        XCTAssertNil(model.message)
    }

    @MainActor
    func testReviewCannotDeleteFromAnotherScan() async throws {
        let model = try await reviewedModel()
        model.report = try DiskScanner().scan(root)
        XCTAssertTrue(model.aiRecommendedCandidates.isEmpty)
        model.requestAIRecommendedRemoval()
        XCTAssertNil(model.pendingCandidateRemoval)
        XCTAssertNotNil(model.message)
    }

    @MainActor
    func testAppliedRecommendationsCannotDeleteFromAnotherRoot() async throws {
        let model = try await reviewedModel()
        model.applyCandidateReview()
        var changed = try XCTUnwrap(model.report)
        let old = changed.root
        changed.root = DiskEntry(path: temporary.path, kind: old.kind, allocatedBytes: old.allocatedBytes,
                                 logicalBytes: old.logicalBytes, fileCount: old.fileCount, issueCount: old.issueCount,
                                 childCount: old.childCount, children: old.children)
        model.report = changed
        XCTAssertTrue(model.aiRecommendedCandidates.isEmpty)
        model.requestAIRecommendedRemoval()
        XCTAssertNil(model.pendingCandidateRemoval)
    }

    @MainActor
    func testFreeTextDoesNotBecomeAnExecutableRecommendation() throws {
        let model = AppModel(scanHistory: history)
        model.report = try DiskScanner().scan(root)
        model.recommendations = "Удалите \(root.path)/unmentioned"
        model.requestAIRecommendedRemoval()
        XCTAssertNil(model.pendingCandidateRemoval)
        XCTAssertTrue(model.aiRecommendedCandidates.isEmpty)
    }

    @MainActor
    func testNewScanClearsAppliedRecommendations() async throws {
        let model = try await reviewedModel()
        model.applyCandidateReview()
        model.setTarget(root)
        model.scan(forceFull: true)
        XCTAssertTrue(model.aiRecommendedCandidates.isEmpty)
        model.requestAIRecommendedRemoval()
        XCTAssertNil(model.pendingCandidateRemoval)
        try await wait(model)
        XCTAssertTrue(model.aiRecommendedCandidates.isEmpty)
    }
}
