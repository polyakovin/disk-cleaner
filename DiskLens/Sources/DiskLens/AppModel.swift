import SwiftUI
import AppKit
import Security
import DiskLensCore

enum Pane: String, CaseIterable, Identifiable {
    case overview = "Файлы и папки", files = "Крупные файлы", candidates = "Кандидаты", assistant = "ИИ-помощник"
    var id: Self { self }
    var icon: String {
        switch self { case .overview: return "chart.pie"; case .files: return "doc.text.magnifyingglass"
        case .candidates: return "archivebox"; case .assistant: return "sparkles" }
    }
}

enum KeyStore {
    private static func query(_ endpoint: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.polyakovin.DiskLens.api",
         kSecAttrAccount as String: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)]
    }
    static func read(endpoint: String) -> String {
        var q = query(endpoint)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    static func save(_ key: String, endpoint: String) throws {
        let q = query(endpoint)
        if key.isEmpty { SecItemDelete(q as CFDictionary); return }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = q
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AgentFailure.message("Не удалось сохранить ключ в Связке ключей (\(status)).") }
    }
}

@MainActor
final class AppModel: ObservableObject {
    typealias ScanOperation = @Sendable (URL, CancellationFlag, DiskReport?, @escaping @Sendable (ScanProgress) -> Void) throws -> DiskReport
    @Published var pane: Pane = .overview
    @Published var target = URL(fileURLWithPath: "/System/Volumes/Data")
    @Published var capacity: VolumeCapacity?
    @Published var report: DiskReport?
    @Published var navigation: [DiskEntry] = []
    @Published var search = ""
    @Published var selection: String?
    @Published var scanning = false
    @Published var scanProgress: ScanProgress?
    @Published var treeOrder: FileTreeOrder = .sizeDescending
    @Published var treeKind: EntryKind?
    @Published private(set) var treePage: FileTreePage?
    @Published private(set) var loadingTree = false
    @Published private(set) var treeError: String?
    @Published private(set) var automaticRefreshAvailable = false
    @Published private(set) var automaticRefreshPaused = false
    @Published var treeLimit = 500
    @Published var treeOffset = 0
    @Published var analyzing = false
    @Published private(set) var preparingAnalysis = false
    @Published var recommendations = ""
    @Published var recommendationDate: Date?
    @Published private(set) var analysisEntry: DiskEntry?
    @Published private(set) var analysisReport: DiskReport?
    @Published private(set) var reviewingCandidates = false
    @Published private(set) var candidateReviewResult: CandidateReviewResult?
    @Published var selectedReviewIDs = Set<String>()
    @Published private var appliedAIRecommendations: DiskReport?
    @Published var settings: AgentSettings
    @Published var showingSettings = false
    @Published var showingDiskAccess = false
    @Published var message: String?
    @Published var pendingRemoval: FileRemovalRequest?
    @Published var pendingCandidateRemoval: CandidateRemovalRequest?
    @Published var removing = false
    @Published var removalStatus: String?
    @Published private(set) var removalMode: FileRemovalMode?
    private var scanFlag: CancellationFlag?
    private var agentFlag: CancellationFlag?
    private var analysisTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailFlag: CancellationFlag?
    private var detailID: UUID?
    private let scanHistory: ScanHistoryStore
    private let removalOperation: @Sendable (FileRemovalRequest) throws -> Void
    private let scanOperation: ScanOperation?
    private let detailScanOperation: (@Sendable (URL, CancellationFlag) throws -> DiskReport)?
    private var previousScan: DiskReport?
    private var scanID: UUID?
    private var progressRevision = 0
    private(set) var treeStore: FileTreeStore?
    private var treeRequest: UUID?
    private var treeTask: Task<Void, Never>?
    private var treeFlag: CancellationFlag?
    private var refreshTask: Task<Void, Never>?
    private var lastTreeRefresh = Date.distantPast
    private var attemptedRoots = Set<String>()

    init(scanHistory: ScanHistoryStore = ScanHistoryStore(),
         removalOperation: @escaping @Sendable (FileRemovalRequest) throws -> Void = { try $0.perform() },
         scanOperation: ScanOperation? = nil,
         detailScanOperation: (@Sendable (URL, CancellationFlag) throws -> DiskReport)? = nil) {
        self.scanHistory = scanHistory
        self.removalOperation = removalOperation
        self.scanOperation = scanOperation
        self.detailScanOperation = detailScanOperation
        if FileManager.default.fileExists(atPath: scanHistory.directory.path) {
            do { treeStore = try FileTreeStore(directory: scanHistory.directory) }
            catch { treeError = error.localizedDescription }
        }
        if let data = UserDefaults.standard.data(forKey: "agentSettings"),
           let saved = try? JSONDecoder().decode(AgentSettings.self, from: data) { settings = saved }
        else { settings = AgentSettings(); settings.executable = AgentSettings.detectCodex() ?? "" }
        do {
            previousScan = try scanHistory.load()
            if let saved = previousScan {
                report = saved
                target = URL(fileURLWithPath: saved.root.path)
            }
        } catch { message = "Не удалось открыть последний замер. Запустите новое сканирование." }
        capacity = VolumeCapacity.read(at: target)
        automaticRefreshAvailable = treeStore?.hasContinuousHistory(target.standardizedFileURL.resolvingSymlinksInPath().path) == true
    }

    var displayedReport: DiskReport? {
        if scanning {
            // A new traversal does not erase the last complete measurement.
            if let report, report.root.path == target.standardizedFileURL.resolvingSymlinksInPath().path { return report }
            return scanProgress?.report
        }
        return report
    }
    var openedPath: String { navigation.last?.path ?? target.standardizedFileURL.resolvingSymlinksInPath().path }
    var treeQuery: String { [openedPath, treeOrder.rawValue, treeKind?.rawValue ?? "", search, String(treeLimit), String(treeOffset)].joined(separator: "\n") }
    var interactionLocked: Bool { removing || pendingRemoval != nil || pendingCandidateRemoval != nil }
    var workLocked: Bool { scanning || interactionLocked }
    var aiRecommendedCandidates: [CleanupCandidate] {
        guard !scanning, let current = report else { return [] }
        if reviewingCandidates, let result = candidateReviewResult, let snapshot = analysisReport {
            guard sameScan(current, snapshot) else { return [] }
            return (try? CandidateReview(report: snapshot).recommendedCandidates(result, selectedIDs: selectedReviewIDs)) ?? []
        }
        guard let applied = appliedAIRecommendations, sameScan(current, applied) else { return [] }
        return applied.candidates
    }
    private func sameScan(_ current: DiskReport, _ snapshot: DiskReport) -> Bool {
        current.measuredAt == snapshot.measuredAt && current.root.path == snapshot.root.path
    }
    var current: DiskEntry? {
        if let treePage, treePage.folder.path == openedPath { return treePage.folder }
        guard let opened = navigation.last else { return displayedReport?.root }
        func find(_ entry: DiskEntry) -> DiskEntry? {
            if entry.path == opened.path { return entry }
            guard opened.path.hasPrefix(entry.path == "/" ? "/" : entry.path + "/") else { return nil }
            for child in entry.children {
                if let found = find(child) { return found }
            }
            return nil
        }
        return displayedReport.flatMap { find($0.root) } ?? opened
    }
    var selected: DiskEntry? {
        let entries = (current?.children ?? []) + (displayedReport?.largestFiles ?? []) + (displayedReport?.candidates.map(\.entry) ?? [])
        return entries.first { $0.path == selection }
    }
    var targetName: String {
        if target.path == FileManager.default.homeDirectoryForCurrentUser.path { return "Домашняя папка" }
        if target.path == "/System/Volumes/Data" { return "Весь Mac" }
        return target.lastPathComponent
    }
    var agentName: String {
        switch settings.mode { case .codex: return "Codex CLI"; case .command: return "Локальная команда"; case .api: return "API · " + settings.model }
    }
    func setTarget(_ url: URL) {
        guard !workLocked else { return }
        target = url; capacity = VolumeCapacity.read(at: url)
        navigation = []; selection = nil; treeOffset = 0
    }
    func chooseFolder() {
        guard !interactionLocked else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Выберите папку или диск для анализа"
        if panel.runModal() == .OK, let url = panel.url { openLocation(url) }
    }
    func scan(completionMessage: String? = nil, forceFull: Bool = false) {
        guard !workLocked else { return }
        ensureTreeStore()
        automaticRefreshPaused = false
        cancelAnalysis()
        scanning = true; scanProgress = nil; message = nil
        attemptedRoots.insert(target.standardizedFileURL.resolvingSymlinksInPath().path)
        recommendations = ""; recommendationDate = nil
        analysisEntry = nil; analysisReport = nil
        reviewingCandidates = false; candidateReviewResult = nil; selectedReviewIDs = []
        appliedAIRecommendations = nil
        if pane == .assistant { pane = .overview }
        let id = UUID(); scanID = id; progressRevision = 0
        let flag = CancellationFlag(); scanFlag = flag
        let root = target
        let baseline = previousScan
        let history = scanHistory
        let performScan = scanOperation
        let tree = treeStore
        let onProgress: @Sendable (ScanProgress) -> Void = { [weak self] value in
            guard let self else { return }
            Task { @MainActor in
                guard self.scanning, self.scanID == id, value.revision > self.progressRevision else { return }
                self.progressRevision = value.revision
                self.scanProgress = value
                self.refreshTreeWhileScanning()
            }
        }
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<(DiskReport, String?), Error> in
                do {
                    let scanner = DiskScanner(cancellation: flag, previousReport: baseline, history: history, treeStore: tree,
                                              reusePreviousScan: !forceFull, progress: onProgress)
                    let value: DiskReport
                    if let performScan { value = try performScan(root, flag, baseline, onProgress) }
                    else { value = try scanner.scan(root) }
                    var warning: String?
                    do { try history.save(value, cache: scanner.scanCache, unlessCancelled: flag) }
                    catch { warning = "Замер готов, но сохранить его для следующего запуска не удалось: \(error.localizedDescription)" }
                    return .success((value, warning))
                } catch { return .failure(error) }
            }.value
            guard scanID == id else { return }
            scanning = false; scanFlag = nil; scanID = nil
            switch result {
            case .success(let (value, warning)):
                report = value; capacity = value.volume
                automaticRefreshAvailable = tree?.hasContinuousHistory(value.root.path) == true
                reloadTree(discover: true)
                if previousScan?.root.path != value.root.path || !value.isPartial || previousScan?.isPartial != false {
                    previousScan = value
                }
                let messages = [completionMessage, warning].compactMap { $0 }.joined(separator: "\n")
                message = messages.isEmpty ? nil : messages
            case .failure(let error):
                message = [completionMessage, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            }
        }
    }
    func cancelScan() {
        scanFlag?.cancel()
        guard scanning else { return }
        automaticRefreshPaused = true
        if report?.root.path != target.standardizedFileURL.resolvingSymlinksInPath().path, var partial = scanProgress?.report {
            partial.inProgress = nil
            partial.cancelled = true
            report = partial; capacity = partial.volume
            if previousScan?.root.path != partial.root.path || previousScan?.isPartial != false { previousScan = partial }
        }
        // A POSIX call may still be waiting in the worker. Its result is now obsolete.
        scanning = false; scanID = nil; scanFlag = nil
        reloadTree(discover: false)
    }
    func scanFolder(_ entry: DiskEntry) {
        guard entry.isFolder, !interactionLocked else { return }
        cancelScan()
        setTarget(URL(fileURLWithPath: entry.path))
        scan()
    }
    func cancelAnalysis() {
        agentFlag?.cancel(); analysisTask?.cancel()
        cancelAnalysisDetails()
    }
    private func cancelAnalysisDetails() {
        detailFlag?.cancel(); detailTask?.cancel()
        detailFlag = nil; detailTask = nil; detailID = nil; preparingAnalysis = false
    }
    func cancelWork() { cancelScan(); automaticRefreshPaused = true; cancelAnalysis(); refreshTask?.cancel(); refreshTask = nil; treeTask?.cancel(); treeFlag?.cancel() }
    func navigate(_ entry: DiskEntry) {
        if entry.isFolder {
            guard !interactionLocked else { return }
            navigation.append(entry); selection = nil; search = ""
            treeOffset = 0
        }
        else { reveal(entry) }
    }
    func goToParent() {
        guard !interactionLocked, openedPath != "/" else { return }
        let path = URL(fileURLWithPath: openedPath).deletingLastPathComponent().path
        navigate(DiskEntry(path: path, kind: .folder, allocatedBytes: 0, logicalBytes: 0,
                           fileCount: 0, issueCount: 0, childCount: 0, children: [], sizeIsKnown: false))
    }
    func openLocation(_ url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        navigate(DiskEntry(path: path, kind: .folder, allocatedBytes: 0, logicalBytes: 0,
                           fileCount: 0, issueCount: 0, childCount: 0, children: [], sizeIsKnown: false))
        pane = .overview
    }
    func reloadTree(discover: Bool = true) {
        ensureTreeStore()
        guard let treeStore else { return }
        treeTask?.cancel(); treeFlag?.cancel()
        let flag = CancellationFlag(); treeFlag = flag
        let id = UUID(); treeRequest = id
        let path = openedPath, query = treeQuery, order = treeOrder, kind = treeKind, search = search, limit = treeLimit, offset = treeOffset
        let measurementRoot = target.standardizedFileURL.resolvingSymlinksInPath().path
        loadingTree = true
        treeTask = Task {
            let result = await Task.detached(priority: .utility) {
                Result { () -> (FileTreePage?, Bool) in
                    if discover { try treeStore.discoverIfNeeded(URL(fileURLWithPath: path), cancellation: flag) }
                    return try (treeStore.page(path, order: order, search: search, kind: kind, limit: limit, offset: offset),
                                treeStore.containsMeasurement(path, root: measurementRoot))
                }
            }.value
            guard treeRequest == id, treeQuery == query, !Task.isCancelled else { return }
            loadingTree = false
            switch result {
            case .success(let (page, inScope)):
                treePage = page; treeError = nil
                if let page, !scanning, !interactionLocked, !automaticRefreshPaused, pane == .overview,
                   (!inScope || ((page.folder.sizeIsKnown == false || report == nil) && !attemptedRoots.contains(path))) {
                    setTarget(URL(fileURLWithPath: path)); scan()
                }
            case .failure(let error): treeError = error.localizedDescription
            }
        }
    }
    private func ensureTreeStore() {
        guard treeStore == nil else { return }
        do { treeStore = try FileTreeStore(directory: scanHistory.directory) }
        catch { treeError = error.localizedDescription }
    }
    private func refreshTreeWhileScanning() {
        guard !loadingTree, Date().timeIntervalSince(lastTreeRefresh) >= 0.7 else { return }
        lastTreeRefresh = Date(); reloadTree(discover: false)
    }
    func startFileBrowser() {
        guard refreshTask == nil else { return }
        if let tree = treeStore, let report {
            Task {
                let needsIndex = await Task.detached(priority: .utility) {
                    let needsIndex = !tree.hasContinuousHistory(report.root.path)
                    if needsIndex { try? tree.seed(report) }
                    return needsIndex
                }.value
                reloadTree()
                if needsIndex, !workLocked, !automaticRefreshPaused, !attemptedRoots.contains(report.root.path) { scan() }
            }
        } else { reloadTree() }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self else { return }
                guard !self.workLocked, !self.automaticRefreshPaused, !self.analyzing, self.pane != .assistant,
                      let tree = self.treeStore, self.report != nil else { continue }
                let root = self.target
                let changed = await Task.detached(priority: .utility) { tree.needsRefresh(root) }.value
                guard !Task.isCancelled, !self.workLocked, !self.automaticRefreshPaused, self.target == root, !self.analyzing, self.pane != .assistant else { continue }
                if changed { self.scan() }
            }
        }
    }
    func reveal(_ entry: DiskEntry) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func requestRemoval(_ entry: DiskEntry, mode: FileRemovalMode = .trash) {
        guard !interactionLocked, !scanning || scanID != nil, let snapshot = displayedReport else { return }
        do {
            let request = try FileRemovalRequest(entry: entry, scanRoot: snapshot.root.path, mode: mode)
            cancelScan()
            pendingRemoval = request
        } catch { message = error.localizedDescription }
    }
    func cancelRemoval() { pendingRemoval = nil }
    func confirmRemoval() {
        guard let request = pendingRemoval, !scanning, !removing else { return }
        pendingRemoval = nil
        removing = true; message = nil
        removalMode = request.mode
        cancelAnalysis()
        let history = scanHistory
        let tree = treeStore
        let performRemoval = removalOperation
        Task {
            let (result, warning) = await Task.detached(priority: .userInitiated) { () -> (Result<Void, Error>, String?) in
                let result = Result { try performRemoval(request) }
                // A recursive permanent removal may fail after removing part of a folder.
                let invalidate: Bool
                if case .success = result { invalidate = true }
                else { invalidate = request.mode == .permanent }
                var warning: String?
                if invalidate {
                    do {
                        if let tree { try tree.invalidate([request.entry.path]) }
                        else { try history.clear() }
                    }
                    catch { warning = "Не удалось удалить старый сохранённый замер: \(error.localizedDescription)" }
                }
                return (result, warning)
            }.value
            removing = false; removalMode = nil
            switch result {
            case .success:
                removalStatus = request.mode.successMessage(name: request.entry.name)
                refreshAfterRemoval(root: request.scanRoot, completionMessage: warning)
            case .failure(let error):
                let failure = request.mode.failureMessage(name: request.entry.name, reason: error.localizedDescription)
                if request.mode == .permanent {
                    removalStatus = "Удаление не завершено. Проверяем, что осталось на диске."
                    refreshAfterRemoval(root: request.scanRoot,
                                        completionMessage: [failure, warning].compactMap { $0 }.joined(separator: "\n"))
                } else { message = failure }
            }
        }
    }
    private func refreshAfterRemoval(root: String, completionMessage: String?) {
        selection = nil
        recommendations = ""; recommendationDate = nil
        target = URL(fileURLWithPath: root)
        scan(completionMessage: completionMessage)
    }
    func requestCandidateRemoval(mode: FileRemovalMode = .trash) {
        guard !interactionLocked, let snapshot = displayedReport else { return }
        do {
            let request = try CandidateRemovalRequest(report: snapshot, mode: mode)
            cancelScan()
            pendingCandidateRemoval = request
        } catch { message = error.localizedDescription }
    }
    func cancelCandidateRemoval() { pendingCandidateRemoval = nil }
    func requestAIRecommendedRemoval() {
        guard !workLocked, !analyzing, var snapshot = report else { return }
        let recommended = aiRecommendedCandidates
        guard !recommended.isEmpty else {
            message = "Нет выбранных рекомендаций ИИ для текущего замера. Повторите пересмотр кандидатов."
            return
        }
        snapshot.candidates = recommended
        do { pendingCandidateRemoval = try CandidateRemovalRequest(report: snapshot, mode: .trash, scope: .aiRecommended) }
        catch { message = error.localizedDescription }
    }
    func confirmCandidateRemoval() {
        guard let batch = pendingCandidateRemoval, !batch.requests.isEmpty, !scanning, !removing else { return }
        pendingCandidateRemoval = nil
        removing = true; removalMode = batch.mode; message = nil
        cancelAnalysis()
        let history = scanHistory, performRemoval = removalOperation
        let tree = treeStore
        Task {
            let (completed, failure, warning, invalidated) = await Task.detached(priority: .userInitiated) { () -> (Int, String?, String?, Bool) in
                var completed = 0
                var failure: String?
                var attempted = false
                do {
                    // Fail before touching any object if the confirmation is already stale.
                    for request in batch.requests { try request.validate() }
                    for request in batch.requests {
                        do {
                            try request.validate()
                            attempted = true
                            try performRemoval(request)
                            completed += 1
                        } catch {
                            failure = batch.mode.failureMessage(name: request.entry.name, reason: error.localizedDescription)
                            break
                        }
                    }
                } catch { failure = "Ни один объект не удалён: \(error.localizedDescription)" }
                let invalidated = completed > 0 || (attempted && batch.mode == .permanent)
                var warning: String?
                if invalidated {
                    do {
                        if let tree { try tree.invalidate(batch.requests.map { $0.entry.path }) }
                        else { try history.clear() }
                    }
                    catch { warning = "Не удалось удалить старый сохранённый замер: \(error.localizedDescription)" }
                }
                return (completed, failure, warning, invalidated)
            }.value
            removing = false; removalMode = nil
            let status = batch.mode == .permanent ? "Удалено безвозвратно" : "Перемещено в Корзину"
            let skipped = batch.unavailable.isEmpty ? "" : " Пропущено недоступных: \(batch.unavailable.count)."
            removalStatus = "\(status): \(completed) из \(batch.requests.count)." + skipped
            let details = [failure, warning].compactMap { $0 }.joined(separator: "\n")
            if invalidated {
                refreshAfterRemoval(root: batch.scanRoot, completionMessage: details.isEmpty ? nil : details)
            } else { message = details.isEmpty ? nil : details }
        }
    }
    func prepareAnalysis(for entry: DiskEntry?) {
        guard !interactionLocked, !analyzing, let snapshot = displayedReport else { return }
        cancelAnalysisDetails()
        analysisEntry = entry
        analysisReport = snapshot
        reviewingCandidates = false; candidateReviewResult = nil; selectedReviewIDs = []
        recommendations = ""; recommendationDate = nil
        pane = .assistant
        // A folder deep in the bounded overview may have no useful contents.
        // Refine locally before the user reviews and sends the request, without replacing the main scan.
        if let entry, entry.isFolder, entry.childCount > 0,
           entry.children.isEmpty || entry.children.contains(where: { $0.isFolder && $0.childCount > 0 && $0.children.isEmpty }) {
            prepareAnalysisDetails(for: entry, snapshot: snapshot)
        }
    }
    private func prepareAnalysisDetails(for entry: DiskEntry, snapshot: DiskReport) {
        let id = UUID(), flag = CancellationFlag()
        detailID = id; detailFlag = flag; preparingAnalysis = true
        let operation = detailScanOperation
        detailTask = Task {
            let result = await Task.detached(priority: .utility) {
                Result { () -> DiskReport in
                    let url = URL(fileURLWithPath: entry.path)
                    if let operation { return try operation(url, flag) }
                    return try DiskScanner(cancellation: flag).scan(url)
                }
            }.value
            guard detailID == id else { return }
            detailID = nil; detailFlag = nil; detailTask = nil; preparingAnalysis = false
            guard !flag.isCancelled, !Task.isCancelled else { return }
            switch result {
            case .success(var details):
                if !details.candidates.contains(where: { $0.entry.path == entry.path }),
                   let inherited = snapshot.candidates.first(where: {
                       $0.entry.path == entry.path || entry.path.hasPrefix($0.entry.path + "/")
                   }) {
                    var candidate = inherited
                    candidate.entry = details.root
                    details.candidates.append(candidate)
                }
                analysisReport = details
                analysisEntry = details.root
            case .failure(let error):
                message = "Не удалось уточнить состав папки: \(error.localizedDescription). Доступен запрос по исходному замеру."
            }
        }
    }
    func prepareCandidateReview() {
        guard !workLocked, !analyzing, let snapshot = report else { return }
        prepareAnalysis(for: nil)
        analysisReport = snapshot
        reviewingCandidates = true
    }
    var analysisPrompt: String {
        (try? analysisReport?.agentPrompt(anonymizeHome: settings.anonymizeHome, focusedOn: analysisEntry,
                                          reviewingCandidates: reviewingCandidates)) ?? ""
    }
    func applyCandidateReview() {
        guard !workLocked, !analyzing, reviewingCandidates, let snapshot = analysisReport,
              var current = report, let result = candidateReviewResult else { return }
        guard sameScan(current, snapshot) else {
            message = "Замер изменился. Повторите ИИ-пересмотр для текущего списка."
            return
        }
        do {
            let review = CandidateReview(report: snapshot)
            let candidates = try review.applying(result, selectedIDs: selectedReviewIDs)
            let recommended = try review.recommendedCandidates(result, selectedIDs: selectedReviewIDs)
            // Apply the same path and protection checks used by file actions, without deleting anything.
            let existing = Set(snapshot.candidates.map(\.id))
            for candidate in candidates where !existing.contains(candidate.id) {
                _ = try FileRemovalRequest(entry: candidate.entry, scanRoot: current.root.path)
            }
            current.candidates = candidates
            var aiReport = current
            aiReport.candidates = recommended
            appliedAIRecommendations = aiReport
            report = current
            analysisReport = current
            candidateReviewResult = nil; selectedReviewIDs = []
            pane = .candidates; selection = nil; search = ""
        } catch { message = error.localizedDescription }
    }
    func analyze() {
        guard let report = analysisReport ?? displayedReport, !analyzing, !preparingAnalysis, !interactionLocked else { return }
        analysisReport = report
        let config = settings
        let entry = analysisEntry
        let review = reviewingCandidates
        if config.executable.isEmpty && config.mode != .api { showingSettings = true; return }
        analyzing = true; message = nil
        candidateReviewResult = nil; selectedReviewIDs = []
        let flag = CancellationFlag(); agentFlag = flag
        let key = config.mode == .api ? KeyStore.read(endpoint: config.endpoint) : ""
        analysisTask = Task {
            defer { analyzing = false; agentFlag = nil; analysisTask = nil }
            do {
                let text: String
                if config.mode == .api { text = try await APIAgent.analyze(settings: config, key: key, report: report, focusedOn: entry, reviewingCandidates: review) }
                else { text = try await CommandAgent.analyze(settings: config, report: report, focusedOn: entry, reviewingCandidates: review, cancellation: flag) }
                if !Task.isCancelled && self.analysisReport?.measuredAt == report.measuredAt {
                    if review {
                        let result = try CandidateReview(report: report).parse(text)
                        candidateReviewResult = result
                        selectedReviewIDs = Set(result.decisions.filter { $0.action != .keep }.map(\.id))
                        recommendations = result.summary
                    } else { recommendations = text }
                    recommendationDate = Date()
                }
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled { message = error.localizedDescription }
            }
        }
    }
    func saveSettings(_ value: AgentSettings, key: String) throws {
        if value.mode == .api { try KeyStore.save(key, endpoint: value.endpoint) }
        UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: "agentSettings")
        settings = value
    }
    func export(json: Bool) {
        guard let report, !workLocked else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = json ? "DiskLens-report.json" : "DiskLens-report.txt"
        panel.message = "Отчёт содержит пути и размеры, без содержимого файлов"
        if panel.runModal() == .OK, let url = panel.url {
            do { try (json ? report.json() : report.text()).write(to: url, atomically: true, encoding: .utf8) }
            catch { message = error.localizedDescription }
        }
    }
}
