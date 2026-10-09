import SwiftUI
import AppKit
import Security
import DiskLensCore

enum Pane: String, CaseIterable, Identifiable {
    case overview = "Обзор", files = "Крупные файлы", candidates = "Кандидаты", assistant = "ИИ-помощник"
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
    @Published var pane: Pane = .overview
    @Published var target = FileManager.default.homeDirectoryForCurrentUser
    @Published var capacity: VolumeCapacity?
    @Published var report: DiskReport?
    @Published var navigation: [DiskEntry] = []
    @Published var search = ""
    @Published var selection: String?
    @Published var scanning = false
    @Published var scanProgress: ScanProgress?
    @Published var analyzing = false
    @Published var recommendations = ""
    @Published var recommendationDate: Date?
    @Published var settings: AgentSettings
    @Published var showingSettings = false
    @Published var message: String?
    private var scanFlag: CancellationFlag?
    private var agentFlag: CancellationFlag?
    private var analysisTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: "agentSettings"),
           let saved = try? JSONDecoder().decode(AgentSettings.self, from: data) { settings = saved }
        else { settings = AgentSettings(); settings.executable = AgentSettings.detectCodex() ?? "" }
        capacity = VolumeCapacity.read(at: target)
    }

    var current: DiskEntry? { navigation.last ?? report?.root }
    var selected: DiskEntry? {
        let entries = (current?.children ?? []) + (report?.largestFiles ?? []) + (report?.candidates.map(\.entry) ?? [])
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
    func setTarget(_ url: URL) { target = url; capacity = VolumeCapacity.read(at: url) }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.message = "Выберите папку или диск для анализа"
        if panel.runModal() == .OK, let url = panel.url { setTarget(url) }
    }
    func scan() {
        guard !scanning else { return }
        cancelAnalysis()
        scanning = true; scanProgress = nil; message = nil
        let flag = CancellationFlag(); scanFlag = flag
        let root = target
        Task {
            let result = await Task.detached(priority: .utility) { [weak self] () -> Result<DiskReport, Error> in
                do {
                    return .success(try DiskScanner(cancellation: flag, progress: { value in
                        Task { @MainActor [weak self] in self?.scanProgress = value }
                    }).scan(root))
                } catch { return .failure(error) }
            }.value
            scanning = false; scanFlag = nil
            switch result {
            case .success(let value):
                report = value; capacity = value.volume; navigation = []; selection = nil
                recommendations = ""; recommendationDate = nil
            case .failure(let error): message = error.localizedDescription
            }
        }
    }
    func cancelScan() { scanFlag?.cancel() }
    func cancelAnalysis() { agentFlag?.cancel(); analysisTask?.cancel() }
    func cancelWork() { cancelScan(); cancelAnalysis() }
    func navigate(_ entry: DiskEntry) {
        if entry.isFolder { navigation.append(entry); selection = nil; search = "" }
        else { reveal(entry) }
    }
    func reveal(_ entry: DiskEntry) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)]) }
    func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
    func analyze() {
        guard let report, !analyzing else { return }
        let config = settings
        if config.executable.isEmpty && config.mode != .api { showingSettings = true; return }
        analyzing = true; message = nil
        let flag = CancellationFlag(); agentFlag = flag
        let key = config.mode == .api ? KeyStore.read(endpoint: config.endpoint) : ""
        analysisTask = Task {
            defer { analyzing = false; agentFlag = nil; analysisTask = nil }
            do {
                let text: String
                if config.mode == .api { text = try await APIAgent.analyze(settings: config, key: key, report: report) }
                else { text = try await CommandAgent.analyze(settings: config, report: report, cancellation: flag) }
                if !Task.isCancelled && self.report?.measuredAt == report.measuredAt { recommendations = text; recommendationDate = Date() }
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
        guard let report else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = json ? "DiskLens-report.json" : "DiskLens-report.txt"
        panel.message = "Отчёт содержит пути и размеры, без содержимого файлов"
        if panel.runModal() == .OK, let url = panel.url {
            do { try (json ? report.json() : report.text()).write(to: url, atomically: true, encoding: .utf8) }
            catch { message = error.localizedDescription }
        }
    }
}
