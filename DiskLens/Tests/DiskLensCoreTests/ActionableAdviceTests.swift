import XCTest
import Foundation
@testable import DiskLensCore

final class ActionableAdviceTests: XCTestCase {
    private func entry(_ path: String, bytes: Int64 = 8192, children: [DiskEntry] = [], folder: Bool = false) -> DiskEntry {
        DiskEntry(path: path, kind: folder || !children.isEmpty ? .folder : .file,
                  allocatedBytes: bytes, logicalBytes: bytes, fileCount: 1, issueCount: 0,
                  childCount: children.count, children: children)
    }

    private func report(_ root: DiskEntry, files: [DiskEntry] = [], candidates: [CleanupCandidate] = []) -> DiskReport {
        DiskReport(schemaVersion: 1, measuredAt: Date(timeIntervalSince1970: 1000), durationSeconds: 1,
                   root: root, volume: nil, largestFiles: files, candidates: candidates,
                   issues: [], issueCount: 0, skippedMounts: [], skippedMountCount: 0,
                   hardLinksSkipped: 0, cancelled: false, scannedItems: 10)
    }

    private func payload(_ report: DiskReport, _ selected: DiskEntry) throws -> [String: Any] {
        let json = try report.agentData(focusedOn: selected)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testFocusRecoversDeepContentsScopedFilesAndCandidatesWithoutSiblingData() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = home + "/Projects/fixture/work"
        let frame = entry(path + "/day-01/frames/0001.png")
        let frames = entry(path + "/day-01/frames", children: [frame])
        let selected = entry(path, children: [entry(path + "/day-01", children: [frames])])
        let render = entry(path + "/day-02/final.mp4")
        let cache = entry(path + "/.cache/pip", folder: true)
        let unrelated = (0..<60).map { entry(home + "/Elsewhere/private-\($0).mov") }
        let sibling = entry(path + "-archive/private.mov")
        let value = report(entry(home + "/Projects", children: [selected, sibling]),
                           files: unrelated + [sibling, render], candidates: [
                            CleanupCandidate(entry: cache, reason: "Кэш", caution: "Повторная загрузка"),
                            CleanupCandidate(entry: sibling, reason: "Чужой объект", caution: "Чужой риск")
                           ])
        // The selected row may be stripped while the report tree still has its descendants.
        var compact = selected; compact.children = []
        let data = try payload(value, compact)
        let contents = try XCTUnwrap(data["contents"] as? [[String: Any]])
        let paths = contents.compactMap { $0["path"] as? String }
        XCTAssertTrue(paths.contains("~/Projects/fixture/work/day-01/frames/0001.png"))
        XCTAssertTrue(paths.contains("~/Projects/fixture/work/day-02/final.mp4"))
        XCTAssertEqual(Set(paths).count, paths.count)
        let files = try XCTUnwrap(data["largestFiles"] as? [[String: Any]])
        XCTAssertEqual(files.count, 1, "Filter by selection before applying the global file limit")
        let candidates = try XCTUnwrap(data["relatedCandidates"] as? [[String: Any]])
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first?["caution"] as? String, "Повторная загрузка")
        let json = try value.agentData(focusedOn: compact)
        XCTAssertFalse(json.contains(home))
        XCTAssertFalse(json.contains("Elsewhere"))
        XCTAssertFalse(json.contains("private.mov"))
        XCTAssertFalse(json.contains("Чужой"))
    }

    func testDetailedContentsAreBoundedFlatAndExplicitAboutOmissions() throws {
        let path = "/fixture/work"
        let selected = entry(path, children: (0..<300).map { entry(path + "/render-\($0).mp4", bytes: Int64($0 + 1)) })
        let data = try payload(report(selected), selected)
        let contents = try XCTUnwrap(data["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 240)
        XCTAssertEqual(data["omittedKnownEntries"] as? Int, 60)
        XCTAssertEqual(contents.first?["path"] as? String, path + "/render-299.mp4")
        XCTAssertTrue(contents.allSatisfy { ($0["children"] as? [Any])?.isEmpty == true })
        XCTAssertEqual((data["entry"] as? [String: Any])?["childCount"] as? Int, 300)
    }

    func testFileFocusDoesNotImportAdjacentObjects() throws {
        let file = entry("/fixture/work/output.mp4")
        let value = report(entry("/fixture/work", children: [file, entry("/fixture/work/original.mov")]),
                           files: [file, entry(file.path + "/not-a-child")])
        let data = try payload(value, file)
        XCTAssertEqual((data["contents"] as? [Any])?.count, 0)
        XCTAssertEqual((data["largestFiles"] as? [Any])?.count, 0)
    }

    func testFocusedPayloadDoesNotReadFileContents() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-advice-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "PRIVATE_CONTENT_MUST_STAY_LOCAL_123456"
        try Data(marker.utf8).write(to: directory.appendingPathComponent("source.env"))
        let value = try DiskScanner().scan(directory)
        let json = try value.agentData(focusedOn: value.root)
        XCTAssertTrue(json.contains("source.env"))
        XCTAssertFalse(json.contains(marker))
    }
}
