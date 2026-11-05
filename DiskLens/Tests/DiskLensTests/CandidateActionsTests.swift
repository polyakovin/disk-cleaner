import XCTest
@testable import DiskLensCore
@testable import DiskLens

final class CandidateActionsTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("scan") }
    private var history: ScanHistoryStore { ScanHistoryStore(directory: temporary.appendingPathComponent("history")) }

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-candidates-tests-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["first", "second", "third", "keep"] { try Data("fixture".utf8).write(to: root.appendingPathComponent(name)) }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }

    private func fixture() throws -> DiskReport {
        var report = try DiskScanner().scan(root)
        report.candidates = ["first", "second", "third"].map { name in
            CleanupCandidate(entry: report.root.children.first { $0.name == name }!, reason: "Тестовый объект", caution: "Только тест")
        }
        return report
    }
    @MainActor
    private func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(5)
        while (model.removing || model.scanning || model.analyzing) && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.removing || model.scanning || model.analyzing)
    }
    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) }

    @MainActor
    func testBatchConfirmationIncludesAllDespiteSearchAndCancelDoesNothing() throws {
        let model = AppModel(scanHistory: history)
        model.report = try fixture(); model.search = "first"
        model.requestCandidateRemoval(mode: .permanent)
        XCTAssertEqual(model.pendingCandidateRemoval?.requests.count, 3)
        XCTAssertEqual(model.pendingCandidateRemoval?.mode, .permanent)
        XCTAssertTrue(model.interactionLocked)
        model.scan()
        XCTAssertFalse(model.scanning)
        model.requestRemoval(model.report!.candidates[0].entry)
        XCTAssertNil(model.pendingRemoval)
        model.cancelCandidateRemoval()
        model.confirmCandidateRemoval()
        XCTAssertFalse(model.removing)
        XCTAssertTrue(exists("first") && exists("second") && exists("third"))
    }

    @MainActor
    func testActualBatchPermanentRemovalOnlyRemovesCandidatesAndRescans() async throws {
        let report = try fixture()
        try history.save(report)
        let model = AppModel(scanHistory: history)
        model.recommendations = "Старый ответ"
        model.requestCandidateRemoval(mode: .permanent)
        model.confirmCandidateRemoval()
        try await wait(model)
        XCTAssertFalse(exists("first") || exists("second") || exists("third"))
        XCTAssertTrue(exists("keep"))
        XCTAssertEqual(model.report?.root.fileCount, 1)
        XCTAssertEqual(try history.load()?.root.fileCount, 1)
        XCTAssertTrue(model.recommendations.isEmpty)
        XCTAssertEqual(model.removalStatus, "Удалено безвозвратно: 3 из 3.")
        XCTAssertNil(model.message)
    }

    @MainActor
    func testPreflightIdentityFailurePreventsEntireBatch() async throws {
        let model = AppModel(scanHistory: history)
        model.report = try fixture()
        model.requestCandidateRemoval(mode: .permanent)
        try FileManager.default.moveItem(at: root.appendingPathComponent("second"), to: root.appendingPathComponent("original-second"))
        try Data("replacement".utf8).write(to: root.appendingPathComponent("second"))
        model.confirmCandidateRemoval()
        try await wait(model)
        XCTAssertTrue(exists("first") && exists("second") && exists("third"))
        XCTAssertEqual(model.removalStatus, "Удалено безвозвратно: 0 из 3.")
        XCTAssertTrue(model.message?.contains("Ни один объект") == true)
    }

    @MainActor
    func testBatchStopsOnFirstFailureAndRefreshesAfterPartialSuccess() async throws {
        let model = AppModel(scanHistory: history, removalOperation: { request in
            if request.entry.name == "second" { throw CocoaError(.fileWriteNoPermission) }
            try request.perform()
        })
        model.report = try fixture()
        model.requestCandidateRemoval(mode: .permanent)
        model.confirmCandidateRemoval()
        try await wait(model)
        XCTAssertFalse(exists("first"))
        XCTAssertTrue(exists("second") && exists("third") && exists("keep"))
        XCTAssertEqual(model.report?.root.fileCount, 3)
        XCTAssertEqual(model.removalStatus, "Удалено безвозвратно: 1 из 3.")
        XCTAssertTrue(model.message?.contains("second") == true)
    }

    @MainActor
    func testTrashModeDoesNotFallBackToPermanentRemoval() async throws {
        let model = AppModel(scanHistory: history, removalOperation: { request in
            XCTAssertEqual(request.mode, .trash)
            throw CocoaError(.fileWriteNoPermission)
        })
        model.report = try fixture()
        model.requestCandidateRemoval()
        model.confirmCandidateRemoval()
        try await wait(model)
        XCTAssertTrue(exists("first") && exists("second") && exists("third"))
        XCTAssertNotNil(model.message)
        XCTAssertEqual(model.report?.candidates.count, 3)
    }

    func testEmptyAndOverlappingBatchesAreRejectedAndProtectedCandidatesAreReported() throws {
        var report = try fixture()
        report.candidates = []
        XCTAssertThrowsError(try CandidateRemovalRequest(report: report, mode: .permanent))
        let original = try fixture()
        report = original; report.candidates += [original.candidates[0]]
        XCTAssertThrowsError(try CandidateRemovalRequest(report: report, mode: .permanent))
        report.candidates = [CleanupCandidate(entry: report.root, reason: "test", caution: "test")]
        let blocked = try CandidateRemovalRequest(report: report, mode: .permanent)
        XCTAssertTrue(blocked.requests.isEmpty)
        XCTAssertEqual(blocked.unavailable.count, 1)
    }

    @MainActor
    func testMissingCandidateIsDisclosedBeforeConfirmAndOtherCandidatesCanBeRemoved() async throws {
        let model = AppModel(scanHistory: history)
        model.report = try fixture()
        try FileManager.default.removeItem(at: root.appendingPathComponent("second"))
        model.requestCandidateRemoval(mode: .permanent)
        XCTAssertEqual(model.pendingCandidateRemoval?.requests.count, 2)
        XCTAssertEqual(model.pendingCandidateRemoval?.unavailable.map(\.entry.name), ["second"])
        XCTAssertTrue(exists("first") && exists("third"))
        model.confirmCandidateRemoval()
        try await wait(model)
        XCTAssertFalse(exists("first") || exists("third"))
        XCTAssertTrue(exists("keep"))
        XCTAssertTrue(model.removalStatus?.contains("Пропущено недоступных: 1") == true)
    }

    @MainActor
    func testEachIdentityIsRevalidatedAfterPriorRemoval() async throws {
        let second = root.appendingPathComponent("second")
        let original = root.appendingPathComponent("original-second")
        let model = AppModel(scanHistory: history, removalOperation: { request in
            try request.perform()
            if request.entry.name == "first" {
                try FileManager.default.moveItem(at: second, to: original)
                try Data("replacement".utf8).write(to: second)
            }
        })
        model.report = try fixture()
        model.requestCandidateRemoval(mode: .permanent)
        model.confirmCandidateRemoval()
        try await wait(model)
        XCTAssertFalse(exists("first"))
        XCTAssertTrue(exists("second") && exists("third") && exists("keep"))
        XCTAssertEqual(try Data(contentsOf: second), Data("replacement".utf8))
        XCTAssertEqual(model.removalStatus, "Удалено безвозвратно: 1 из 3.")
        XCTAssertNotNil(model.message)
    }

    func testDataVolumeScanAcceptsFirmlinkAliasesWithoutAllowingEscapeFromNarrowRoot() throws {
        var item = try fixture().candidates[0].entry
        let alias = "/System/Volumes/Data" + (item.path.hasPrefix("/var/") ? "/private" + item.path : item.path)
        item = DiskEntry(path: alias, kind: item.kind, allocatedBytes: item.allocatedBytes, logicalBytes: item.logicalBytes,
                         fileCount: item.fileCount, issueCount: 0, childCount: 0, children: [])
        let request = try FileRemovalRequest(entry: item, scanRoot: "/System/Volumes/Data")
        XCTAssertNoThrow(try request.validate())
        XCTAssertTrue(exists("first"))
        XCTAssertThrowsError(try FileRemovalRequest(entry: item, scanRoot: "/System/Volumes/Data" + root.appendingPathComponent("other").path))
        var volume = try fixture()
        volume.root = DiskEntry(path: "/System/Volumes/Data", kind: .folder, allocatedBytes: 1, logicalBytes: 1,
                                fileCount: 1, issueCount: 0, childCount: 1, children: [item])
        volume.candidates = [CleanupCandidate(entry: item, reason: "test", caution: "test")]
        XCTAssertEqual(try CandidateRemovalRequest(report: volume, mode: .trash).requests.count, 1)
    }

    func testResolvedPrivateDirectoryAliasesRemainProtectedBeforeMetadataLookup() throws {
        for path in ["/var/db/DiskLens-fixture/Library/Caches", "/etc/DiskLens-fixture", "/var/root/DiskLens-fixture",
                     "/System/Volumes/Data/private/var/db/DiskLens-fixture/Library/Caches"] {
            let entry = DiskEntry(path: path, kind: .folder, allocatedBytes: 0, logicalBytes: 0,
                                  fileCount: 0, issueCount: 0, childCount: 0, children: [])
            do {
                _ = try FileRemovalRequest(entry: entry, scanRoot: "/System/Volumes/Data")
                XCTFail("Protected alias accepted")
            } catch FileRemovalFailure.protectedPath { }
            catch { XCTFail("Expected protection before lookup, got \(error)") }
        }
    }

    @MainActor
    private func reviewedModel() async throws -> AppModel {
        let model = AppModel(scanHistory: history)
        model.report = try fixture()
        model.prepareCandidateReview()
        XCTAssertFalse(model.analyzing)
        let review = CandidateReview(report: model.report!)
        let index = try XCTUnwrap(review.entries.firstIndex { $0.name == "keep" })
        let response = """
        {"summary":"Предложение","decisions":[{"id":"entry-\(index)","action":"add","reason":"Тестовое предложение","caution":"Проверить перед удалением"}]}
        """
        var settings = AgentSettings(); settings.mode = .command; settings.executable = "/bin/echo"
        settings.argumentsJSON = String(decoding: try JSONEncoder().encode([response]), as: UTF8.self)
        model.settings = settings
        model.analyze()
        try await wait(model)
        XCTAssertNotNil(model.candidateReviewResult)
        return model
    }

    @MainActor
    func testAIChangesRequireExplicitApplyAndNeverRemoveFiles() async throws {
        let model = try await reviewedModel()
        XCTAssertEqual(model.report?.candidates.count, 3)
        model.applyCandidateReview()
        XCTAssertEqual(model.report?.candidates.count, 4)
        XCTAssertEqual(model.analysisReport?.candidates.count, 4)
        XCTAssertEqual(model.pane, .candidates)
        XCTAssertTrue(exists("first") && exists("second") && exists("third") && exists("keep"))
        XCTAssertNil(model.candidateReviewResult)
    }

    @MainActor
    func testStaleReviewCannotChangeNewScan() async throws {
        let model = try await reviewedModel()
        model.report = try fixture()
        model.applyCandidateReview()
        XCTAssertEqual(model.report?.candidates.count, 3)
        XCTAssertTrue(model.message?.contains("Замер изменился") == true)
    }
}
