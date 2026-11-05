import XCTest
import Foundation
@testable import DiskLensCore
@testable import DiskLens

final class FileBrowserTests: XCTestCase {
    private var temporary: URL!
    private var root: URL { temporary.appendingPathComponent("files") }
    private var history: ScanHistoryStore { ScanHistoryStore(directory: temporary.appendingPathComponent("index")) }
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-browser-" + UUID().uuidString).resolvingSymlinksInPath()
        let deep = root.appendingPathComponent("a/b/c/d/e")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        for n in 0..<52 { try Data(repeating: 7, count: 4096).write(to: deep.appendingPathComponent("file\(n)")) }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
    @MainActor func testBrowserUsesCompleteIndexBelowSummaryDepthAndCanGoAboveScanRoot() async throws {
        let tree = try FileTreeStore(directory: history.directory)
        let report = try DiskScanner(treeStore: tree).scan(root)
        try history.save(report)
        let model = AppModel(scanHistory: history)
        let path = root.appendingPathComponent("a/b/c/d/e").path
        let folder = try XCTUnwrap(tree.page(path)?.folder)
        model.navigate(folder); model.reloadTree()
        try await wait { !model.loadingTree }
        XCTAssertEqual(model.current?.children.count, 52)
        XCTAssertEqual(model.current?.path, path)
        model.openLocation(root); model.goToParent()
        XCTAssertEqual(model.openedPath, temporary.path)
        model.cancelWork()
    }
    @MainActor func testRefreshAndCancellationKeepKnownReportAndOpenedFolder() async throws {
        let tree = try FileTreeStore(directory: history.directory)
        let previous = try DiskScanner(treeStore: tree).scan(root)
        try history.save(previous)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let model = AppModel(scanHistory: history, scanOperation: { _, _, _, progress in
            progress(ScanProgress(revision: 1, items: 0, allocatedBytes: 0, currentPath: previous.root.path,
                                  report: previous, largestFolders: [], usesPreviousScan: true))
            release.wait()
            return previous
        })
        let folder = try XCTUnwrap(tree.page(root.appendingPathComponent("a/b/c/d/e").path)?.folder)
        model.navigate(folder); model.scan()
        try await wait { model.scanProgress != nil }
        XCTAssertEqual(model.current?.path, folder.path)
        XCTAssertEqual(model.displayedReport?.root.allocatedBytes, previous.root.allocatedBytes)
        XCTAssertEqual(model.navigation.last?.path, folder.path)
        model.cancelWork()
        XCTAssertEqual(model.report?.root.allocatedBytes, previous.root.allocatedBytes)
        XCTAssertEqual(try history.load()?.root.allocatedBytes, previous.root.allocatedBytes)
    }
}
