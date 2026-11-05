import Foundation
import DiskLensCore

struct CandidateRemovalRequest: Identifiable, Sendable {
    enum Scope: Sendable { case allCandidates, aiRecommended }
    let id = UUID()
    let requests: [FileRemovalRequest]
    let unavailable: [UnavailableCandidate]
    let scanRoot: String
    let mode: FileRemovalMode
    let scope: Scope
    var totalBytes: Int64 { requests.reduce(0) { $0 + $1.entry.allocatedBytes } }

    init(report: DiskReport, mode: FileRemovalMode, scope: Scope = .allCandidates) throws {
        guard !report.candidates.isEmpty,
              DiskScanner.disjointCandidates(report.candidates).count == report.candidates.count else {
            throw AgentFailure.message("Список кандидатов пуст или содержит пересекающиеся пути. Повторите сканирование.")
        }
        var available: [FileRemovalRequest] = []
        var blocked: [UnavailableCandidate] = []
        for candidate in report.candidates {
            do { available.append(try FileRemovalRequest(entry: candidate.entry, scanRoot: report.root.path, mode: mode)) }
            catch { blocked.append(UnavailableCandidate(entry: candidate.entry, reason: error.localizedDescription)) }
        }
        requests = available
        unavailable = blocked
        scanRoot = report.root.path
        self.mode = mode
        self.scope = scope
    }
}

struct UnavailableCandidate: Identifiable, Sendable {
    var id: String { entry.path }
    let entry: DiskEntry
    let reason: String
}
