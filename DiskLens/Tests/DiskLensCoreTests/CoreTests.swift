import XCTest
import Foundation
import Darwin
@testable import DiskLensCore

final class CoreTests: XCTestCase {
    private var temporary: URL!
    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("DiskLens-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: temporary) }
    private func write(_ relative: String, count: Int) throws -> URL {
        let url = temporary.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 120, count: count).write(to: url)
        return url
    }
    private func fixture() throws -> DiskReport {
        _ = try write(".npm/_cacache/blob", count: 32768)
        _ = try write("Музыка/track.flac", count: 16384)
        return try DiskScanner().scan(temporary)
    }

    func testMatchesSystemDuWithUnicodeHiddenFilesHardLinksAndSymlinks() throws {
        let original = try write("большая папка/data.bin", count: 65536)
        _ = try write(".hidden/data.bin", count: 4096)
        try FileManager.default.linkItem(at: original, to: temporary.appendingPathComponent("hardlink.bin"))
        try FileManager.default.createSymbolicLink(at: temporary.appendingPathComponent("symlink-folder"), withDestinationURL: original.deletingLastPathComponent())
        let report = try DiskScanner().scan(temporary)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-x", "-k", "-s", temporary.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(report.root.allocatedBytes, Int64(text.split(separator: "\t")[0])! * 1024)
        XCTAssertEqual(report.hardLinksSkipped, 1)
        XCTAssertEqual(report.root.fileCount, 2)
        XCTAssertTrue(report.root.children.contains { $0.name == ".hidden" })
        XCTAssertFalse(report.root.children.first { $0.name == "symlink-folder" }!.isFolder)
        XCTAssertEqual(report.root.children.map(\.allocatedBytes), report.root.children.map(\.allocatedBytes).sorted(by: >))
    }

    func testBoundedTreeAndGlobalLargestFiles() throws {
        for i in 1...12 { _ = try write("branch\(i)/deep/file", count: i * 4096) }
        var config = ScannerConfiguration(); config.childrenPerFolder = 3; config.largestFileLimit = 2; config.retainedDepth = 1
        let report = try DiskScanner(configuration: config).scan(temporary)
        XCTAssertEqual(report.root.children.count, 3)
        XCTAssertEqual(report.root.childCount, 12)
        XCTAssertEqual(report.largestFiles.count, 2)
        XCTAssertTrue(report.largestFiles[0].path.contains("branch12"))
        XCTAssertTrue(report.root.children.allSatisfy { $0.children.isEmpty })
        XCTAssertEqual(report.root.fileCount, 12)
    }

    func testCancelledScanIsExplicitlyPartial() throws {
        _ = try write("file", count: 8192)
        let flag = CancellationFlag(); flag.cancel()
        let report = try DiskScanner(cancellation: flag).scan(temporary)
        XCTAssertTrue(report.cancelled); XCTAssertTrue(report.isPartial)
        XCTAssertTrue(report.text().contains("Замер неполный"))
    }

    func testInaccessibleDirectoryIsNotReportedAsComplete() throws {
        let file = try write("closed/file", count: 8192)
        let closed = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: closed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: closed.path) }
        let report = try DiskScanner().scan(temporary)
        XCTAssertTrue(report.isPartial)
        XCTAssertEqual(report.issueCount, 1)
        XCTAssertEqual(report.root.children.first?.issueCount, 1)
        XCTAssertEqual(report.issues.first?.path, closed.path)
    }

    func testCandidatesDoNotIncludeUserDataOrOverlap() throws {
        _ = try write("Library/Caches/child/Library/Caches/blob", count: 8192)
        _ = try write(".codex/sessions/history", count: 8192)
        _ = try write(".cache/codex-runtimes/runtime", count: 8192)
        let report = try fixture()
        XCTAssertEqual(report.candidates.count, 2)
        XCTAssertFalse(report.candidates.contains { $0.entry.path.contains(".codex") })
        XCTAssertFalse(report.candidates.contains { $0.entry.path.contains("codex-runtimes") })
        XCTAssertTrue(report.candidates.contains { $0.entry.path.hasSuffix("/Library/Caches") })
        XCTAssertEqual(report.candidateBytes, report.candidates.reduce(0) { $0 + $1.entry.allocatedBytes })
    }

    func testExportContainsMetadataAndNoFileContents() throws {
        let marker = "DO_NOT_EXPORT_SECRET_CONTENT_987654"
        try Data(marker.utf8).write(to: temporary.appendingPathComponent("secret.env"))
        let report = try fixture()
        let json = try report.json()
        XCTAssertTrue(json.contains("secret.env"))
        XCTAssertFalse(json.contains(marker))
        let decoded = try JSONDecoder.iso.decode(DiskReport.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.root.allocatedBytes, report.root.allocatedBytes)
        var inHome = report
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        inHome.root = DiskEntry(path: home + "/Library", kind: .folder, allocatedBytes: 1, logicalBytes: 1,
                               fileCount: 1, issueCount: 0, childCount: 0, children: [])
        let compact = try inHome.json(anonymizeHome: true, compactForAgent: true)
        XCTAssertTrue(compact.contains("~/Library")); XCTAssertFalse(compact.contains(home))
    }

    func testAPIRequestsValidationResponseParsingAndErrorRedaction() throws {
        let report = try fixture()
        var settings = AgentSettings(); settings.mode = .api; settings.model = "test-model"
        let request = try APIAgent.request(settings: settings, key: "TEST_KEY", report: report)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TEST_KEY")
        XCTAssertFalse(String(decoding: request.httpBody!, as: UTF8.self).contains("TEST_KEY"))
        let responses = Data(#"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Рекомендации"}]}]}"#.utf8)
        XCTAssertEqual(try APIAgent.parse(data: responses, statusCode: 200, format: .responses), "Рекомендации")
        let chat = Data(#"{"choices":[{"message":{"content":"Проверьте кэш"},"finish_reason":"stop"}]}"#.utf8)
        XCTAssertEqual(try APIAgent.parse(data: chat, statusCode: 200, format: .chatCompletions), "Проверьте кэш")
        settings.endpoint = "http://untrusted.example/v1/responses"
        XCTAssertThrowsError(try APIAgent.request(settings: settings, key: "", report: report))
        settings.endpoint = "http://127.0.0.1:11434/v1/chat/completions"
        XCTAssertNoThrow(try APIAgent.request(settings: settings, key: "", report: report))
        XCTAssertThrowsError(try APIAgent.parse(data: Data(#"{"error":{"message":"bad TEST_KEY"}}"#.utf8), statusCode: 401, format: .responses, key: "TEST_KEY")) {
            XCTAssertFalse($0.localizedDescription.contains("TEST_KEY"))
        }
    }

    func testURLSessionTransportWithMockHTTPServer() async throws {
        let report = try fixture()
        var settings = AgentSettings(); settings.mode = .api; settings.model = "test-model"
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockAPI.self]
        let text = try await APIAgent.analyze(settings: settings, key: "fixture-key", report: report, configuration: config)
        XCTAssertEqual(text, "Проверка подключения прошла")
    }

    func testCommandStdinAndLargeConcurrentOutputWithoutDeadlock() throws {
        var settings = AgentSettings(); settings.mode = .command; settings.executable = "/bin/cat"
        let flag = CancellationFlag()
        let input = "Отчёт: " + String(repeating: "x", count: 180000)
        XCTAssertEqual(try CommandAgent.run(settings: settings, input: input, cancellation: flag, timeout: 5), input)
        settings.executable = "/bin/sh"
        settings.argumentsJSON = #"["-c","/usr/bin/head -c 180000 /dev/zero; /usr/bin/head -c 180000 /dev/zero >&2"]"#
        XCTAssertEqual(try CommandAgent.run(settings: settings, input: "", cancellation: flag, timeout: 5).utf8.count, 180000)
    }

    func testCommandTimeoutAndArgumentValidation() throws {
        var settings = AgentSettings(); settings.mode = .command; settings.executable = "/bin/sleep"; settings.argumentsJSON = "[\"10\"]"
        let start = Date()
        XCTAssertThrowsError(try CommandAgent.run(settings: settings, input: "", cancellation: .init(), timeout: 0.1))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        settings.argumentsJSON = "--bad arguments"
        XCTAssertThrowsError(try CommandAgent.run(settings: settings, input: "", cancellation: .init()))
    }
}

private extension JSONDecoder {
    static var iso: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}

private final class MockAPI: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"output":[{"type":"message","content":[{"type":"output_text","text":"Проверка подключения прошла"}]}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
