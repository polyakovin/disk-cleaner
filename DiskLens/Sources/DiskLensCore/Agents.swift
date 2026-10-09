import Foundation
import Darwin

public enum APIFormat: String, Codable, CaseIterable, Sendable { case responses, chatCompletions }
public enum AgentMode: String, Codable, CaseIterable, Sendable { case codex, command, api }

public struct AgentSettings: Codable, Sendable {
    public var mode: AgentMode = .codex
    public var executable: String = ""
    public var argumentsJSON: String = "[]"
    public var endpoint: String = "https://api.openai.com/v1/responses"
    public var model: String = ""
    public var format: APIFormat = .responses
    public var anonymizeHome: Bool = true
    public init() {}
    public static let codexArguments = ["--no-daemon", "--ask-for-approval", "never", "exec", "--sandbox", "read-only",
                                        "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--color", "never", "-"]

    public static func detectCodex() -> String? {
        let names = ["/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                     "/Applications/Codex.app/Contents/Resources/codex", "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return (names + paths).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public enum AgentFailure: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): return text } }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum APIAgent {
    public static func request(settings: AgentSettings, key: String, report: DiskReport) throws -> URLRequest {
        guard let url = URL(string: settings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, url.user == nil, url.password == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host)) else {
            throw AgentFailure.message("Укажите HTTPS-адрес API или HTTP-адрес localhost.")
        }
        guard !settings.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentFailure.message("Укажите модель в настройках подключения.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        let input = try report.json(anonymizeHome: settings.anonymizeHome, compactForAgent: true)
        let body: [String: Any]
        if settings.format == .responses {
            body = ["model": settings.model, "instructions": AgentInstructions.text, "input": input,
                    "store": false, "max_output_tokens": 4000]
        } else {
            body = ["model": settings.model, "messages": [["role": "system", "content": AgentInstructions.text],
                                                          ["role": "user", "content": input]], "stream": false]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    public static func parse(data: Data, statusCode: Int, format: APIFormat, key: String = "") throws -> String {
        func safe(_ value: String) -> String { key.isEmpty ? value : value.replacingOccurrences(of: key, with: "[ключ скрыт]") }
        guard data.count <= 2_000_000 else { throw AgentFailure.message("Ответ сервера слишком большой.") }
        guard (200..<300).contains(statusCode) else {
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = (json?["error"] as? [String: Any])?["message"] as? String
            throw AgentFailure.message("API вернул HTTP \(statusCode). " + safe(String((message ?? "Проверьте адрес, модель и авторизацию.").prefix(400))))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentFailure.message("API вернул ответ в неизвестном формате.")
        }
        var text = ""
        if format == .responses {
            let output = object["output"] as? [[String: Any]] ?? []
            text = output.flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .filter { $0["type"] as? String == "output_text" }
                .compactMap { $0["text"] as? String }.joined(separator: "\n\n")
            if text.isEmpty { text = object["output_text"] as? String ?? "" }
            if object["status"] as? String == "incomplete" && !text.isEmpty {
                text += "\n\nОтвет модели прерван лимитом сервера; рекомендации могут быть неполными."
            }
        } else {
            let choice = (object["choices"] as? [[String: Any]])?.first
            let message = choice?["message"] as? [String: Any]
            text = message?["content"] as? String ?? ""
            if choice?["finish_reason"] as? String == "length" && !text.isEmpty {
                text += "\n\nОтвет модели прерван лимитом сервера."
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentFailure.message("В ответе API нет текстовых рекомендаций. Проверьте формат API и модель.")
        }
        return safe(text)
    }

    public static func analyze(settings: AgentSettings, key: String, report: DiskReport,
                               configuration: URLSessionConfiguration = .ephemeral) async throws -> String {
        let request = try request(settings: settings, key: key, report: report)
        let config = configuration
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentFailure.message("Нет HTTP-ответа от сервера.") }
        return try parse(data: data, statusCode: http.statusCode, format: settings.format, key: key)
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, 1_000_000 - data.count)
        data.append(chunk.prefix(remaining))
        if chunk.count > remaining { truncated = true }
    }
    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self) + (truncated ? "\n[Ответ сокращён до 1 МБ]" : "")
    }
}

public enum CommandAgent {
    public static func analyze(settings: AgentSettings, report: DiskReport, cancellation: CancellationFlag,
                               timeout: TimeInterval = 300) async throws -> String {
        let prompt = try report.agentPrompt(anonymizeHome: settings.anonymizeHome)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do { continuation.resume(returning: try run(settings: settings, input: prompt, cancellation: cancellation, timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public static func run(settings: AgentSettings, input: String, cancellation: CancellationFlag,
                           timeout: TimeInterval = 300) throws -> String {
        let executable = settings.executable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard executable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable) else {
            throw AgentFailure.message("Выберите установленный исполняемый файл агента в настройках.")
        }
        let arguments: [String]
        if settings.mode == .codex { arguments = AgentSettings.codexArguments }
        else {
            guard let data = settings.argumentsJSON.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode([String].self, from: data) else {
                throw AgentFailure.message("Аргументы должны быть JSON-массивом строк, например [\"--print\"].")
            }
            arguments = parsed
        }
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("DiskLens-agent-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        let inputURL = temp.appendingPathComponent("report-input.txt")
        try Data(input.utf8).write(to: inputURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        defer { try? inputHandle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = temp
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for name in ["HOME", "TMPDIR", "LANG", "CODEX_HOME"] { if let value = inherited[name] { environment[name] = value } }
        environment["PATH"] = (inherited["PATH"] ?? "/usr/bin:/bin") + ":/opt/homebrew/bin:/usr/local/bin"
        process.environment = environment
        process.standardInput = inputHandle
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout; process.standardError = stderr
        let output = OutputBuffer(), errors = OutputBuffer()
        try process.run()
        let readers = DispatchGroup()
        for (handle, buffer) in [(stdout.fileHandleForReading, output), (stderr.fileHandleForReading, errors)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readers.leave() }
                while let data = try? handle.read(upToCount: 8192), !data.isEmpty { buffer.append(data) }
            }
        }
        let start = Date()
        var timedOut = false
        while process.isRunning {
            if cancellation.isCancelled || Date().timeIntervalSince(start) > timeout {
                timedOut = !cancellation.isCancelled
                process.terminate()
                usleep(150_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            usleep(50_000)
        }
        process.waitUntilExit()
        let drained = readers.wait(timeout: .now() + 2) == .success
        try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
        if cancellation.isCancelled { throw CancellationError() }
        if timedOut { throw AgentFailure.message("Агент не ответил за отведённое время. Проверьте подключение или повторите запрос.") }
        guard drained else { throw AgentFailure.message("Агент завершился, но его дочерний процесс оставил поток открытым.") }
        guard process.terminationStatus == 0 else {
            throw AgentFailure.message("Агент завершился с кодом \(process.terminationStatus). " + String(errors.text().suffix(1600)))
        }
        let result = output.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw AgentFailure.message("Агент не вернул текст в stdout. Проверьте аргументы команды.") }
        return result
    }
}
