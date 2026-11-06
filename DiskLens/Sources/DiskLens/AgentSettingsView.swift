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
                Text("AI Connection").font(.system(size: 23, weight: .semibold, design: .rounded))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Close settings without saving")
                    .accessibilityLabel("Close settings without saving")
            }
            Picker("Connection Method", selection: $draft.mode) {
                Text("Codex CLI").tag(AgentMode.codex)
                Text("Command").tag(AgentMode.command)
                Text("API").tag(AgentMode.api)
            }.pickerStyle(.segmented)
            if draft.mode != .api {
                field("Executable") {
                    HStack {
                        TextField("/absolute/path/to/agent", text: $draft.executable).textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url { draft.executable = url.path }
                        }
                    }
                }
                if draft.mode == .codex {
                    Button("Find Installed Codex") {
                        if let path = AgentSettings.detectCodex() { draft.executable = path }
                        else { error = "Codex CLI was not found. Choose an installed CLI or use the API." }
                    }
                    Text("Uses the installed CLI's authentication in a temporary, read-only session. Hooks and user configuration are disabled.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    field("Arguments as a JSON Array") {
                        TextField("[\"--print\"]", text: $draft.argumentsJSON).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    }
                    Text("The request goes to stdin and the response is read from stdout. The command runs directly with its own authentication and permissions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                field("API Format") {
                    Picker("Format", selection: $draft.format) {
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
                field("Full Server URL") {
                    TextField("https://api.openai.com/v1/responses", text: $draft.endpoint).textFieldStyle(.roundedBorder)
                        .onChange(of: draft.endpoint) { _, endpoint in key = KeyStore.read(endpoint: endpoint) }
                }
                field("Model") { TextField("Your provider's model name", text: $draft.model).textFieldStyle(.roundedBorder) }
                field("API Key") { SecureField("Optional", text: $key).textFieldStyle(.roundedBorder) }
                Text("The key is saved in Keychain for this URL. Local servers may use HTTP on localhost.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle("Replace the home directory prefix with ~ in agent requests", isOn: $draft.anonymizeHome).font(.callout)
            Text("Folder and file names remain in the report. Their contents are never read or sent.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        if draft.mode == .command {
                            guard let data = draft.argumentsJSON.data(using: .utf8), (try? JSONDecoder().decode([String].self, from: data)) != nil else {
                                error = "Arguments must be a JSON array of strings."; return
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
