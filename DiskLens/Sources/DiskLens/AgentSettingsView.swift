import SwiftUI
import AppKit
import DiskLensCore

struct AgentSettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AgentSettings
    @State private var key = ""
    @State private var error: String?
    init(model: AppModel) { self.model = model; _draft = State(initialValue: model.settings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Подключение ИИ").font(.system(size: 23, weight: .semibold, design: .rounded))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Picker("Способ подключения", selection: $draft.mode) {
                Text("Codex CLI").tag(AgentMode.codex)
                Text("Команда").tag(AgentMode.command)
                Text("API").tag(AgentMode.api)
            }.pickerStyle(.segmented)
            if draft.mode != .api {
                field("Исполняемый файл") {
                    HStack {
                        TextField("/absolute/path/to/agent", text: $draft.executable).textFieldStyle(.roundedBorder)
                        Button("Выбрать…") {
                            let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url { draft.executable = url.path }
                        }
                    }
                }
                if draft.mode == .codex {
                    Button("Найти установленный Codex") {
                        if let path = AgentSettings.detectCodex() { draft.executable = path }
                        else { error = "Codex CLI не найден. Выберите установленный CLI или используйте API." }
                    }
                    Text("Используется авторизация установленного CLI. Режим только чтения, временная сессия; hooks и пользовательская конфигурация отключены.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    field("Аргументы как JSON-массив") {
                        TextField("[\"--print\"]", text: $draft.argumentsJSON).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    }
                    Text("Запрос поступает в stdin, ответ читается из stdout. Команда запускается напрямую и использует собственную авторизацию и права.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                field("Формат API") {
                    Picker("Формат", selection: $draft.format) {
                        Text("Responses").tag(APIFormat.responses)
                        Text("Chat Completions").tag(APIFormat.chatCompletions)
                    }.labelsHidden()
                    .onChange(of: draft.format) { _, format in
                        if draft.endpoint == "https://api.openai.com/v1/responses" || draft.endpoint == "https://api.openai.com/v1/chat/completions" {
                            draft.endpoint = format == .responses ? "https://api.openai.com/v1/responses" : "https://api.openai.com/v1/chat/completions"
                            key = KeyStore.read(endpoint: draft.endpoint)
                        }
                    }
                }
                field("Полный URL сервера") {
                    TextField("https://api.openai.com/v1/responses", text: $draft.endpoint).textFieldStyle(.roundedBorder)
                        .onChange(of: draft.endpoint) { _, endpoint in key = KeyStore.read(endpoint: endpoint) }
                }
                field("Модель") { TextField("Название модели вашего провайдера", text: $draft.model).textFieldStyle(.roundedBorder) }
                field("API-ключ") { SecureField("При необходимости", text: $key).textFieldStyle(.roundedBorder) }
                Text("Ключ сохраняется в Связке ключей для этого URL. Для локального сервера разрешён HTTP на localhost.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Заменять домашний префикс пути на ~ в запросе агенту", isOn: $draft.anonymizeHome).font(.callout)
            Text("Названия папок и файлов остаются в отчёте. Их содержимое не читается и не отправляется.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    do {
                        if draft.mode == .command {
                            guard let data = draft.argumentsJSON.data(using: .utf8), (try? JSONDecoder().decode([String].self, from: data)) != nil else {
                                error = "Аргументы должны быть JSON-массивом строк."; return
                            }
                        }
                        try model.saveSettings(draft, key: key); dismiss()
                    } catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width: 560)
        .onAppear { key = KeyStore.read(endpoint: draft.endpoint) }
    }
    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text(title).font(.caption).foregroundStyle(.secondary); content() }
    }
}
