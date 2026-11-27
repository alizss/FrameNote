import AppKit
import Foundation
import Security

/// Subscription access stays with the official CLIs; API credentials stay in Keychain.
enum AIProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case codex, claudeCode, openAI, anthropic, compatible
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: "Codex account"
        case .claudeCode: "Claude Code account"
        case .openAI: "OpenAI API"
        case .anthropic: "Anthropic API"
        case .compatible: "Other / local API"
        }
    }
    var isCLI: Bool { self == .codex || self == .claudeCode }
    var detail: String {
        switch self {
        case .codex: "Use the account signed in to Codex on this Mac."
        case .claudeCode: "Use the account signed in to Claude Code on this Mac."
        case .openAI, .anthropic: "Use your API key. API billing is separate from your subscription."
        case .compatible: "OpenAI-compatible API, including a local server. Choose a model that accepts images."
        }
    }
    var defaultModel: String {
        switch self {
        case .openAI: "gpt-5"
        case .anthropic: "claude-sonnet-4-6"
        default: ""
        }
    }
    var defaultEndpoint: String {
        switch self {
        case .openAI: "https://api.openai.com/v1/responses"
        case .anthropic: "https://api.anthropic.com/v1/messages"
        case .compatible: "http://localhost:1234/v1/chat/completions"
        default: ""
        }
    }
}

struct AIConnection: Sendable {
    var provider: AIProvider
    var model: String
    var endpoint: String
    var executablePath: String
    var key: String

    static var selectedProvider: AIProvider {
        UserDefaults.standard.string(forKey: "ai.provider").flatMap(AIProvider.init(rawValue:))
            ?? (OpenAIKeyStore.read() != nil ? .openAI : .codex)
    }

    static func load(provider override: AIProvider? = nil) -> Self {
        let defaults = UserDefaults.standard
        let provider = override ?? selectedProvider
        let prefix = "ai.\(provider.rawValue)."
        return Self(provider: provider, model: defaults.string(forKey: prefix + "model") ?? provider.defaultModel,
            endpoint: defaults.string(forKey: prefix + "endpoint") ?? provider.defaultEndpoint,
            executablePath: defaults.string(forKey: prefix + "executable") ?? "", key: AIKeyStore.read(provider) ?? "")
    }

    func save() -> Bool {
        guard provider.isCLI || AIKeyStore.save(key, provider: provider) else { return false }
        let defaults = UserDefaults.standard, prefix = "ai.\(provider.rawValue)."
        defaults.set(provider.rawValue, forKey: "ai.provider")
        defaults.set(model, forKey: prefix + "model")
        defaults.set(endpoint, forKey: prefix + "endpoint")
        defaults.set(executablePath, forKey: prefix + "executable")
        return true
    }

    var executable: URL? {
        guard provider.isCLI else { return nil }
        let name = provider == .codex ? "codex" : "claude"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = executablePath.isEmpty
            ? ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)", "\(home)/.npm-global/bin/\(name)"]
                + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" }
                + (provider == .codex ? ["/Applications/Codex.app/Contents/Resources/codex", "/Applications/ChatGPT.app/Contents/Resources/codex"] : [])
            : [executablePath]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    var configurationError: String? {
        if provider.isCLI { return executable == nil ? "Install \(provider == .codex ? "Codex" : "Claude Code"), or choose its executable in AI settings." : nil }
        guard let url = URL(string: endpoint), let host = url.host,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            return "Use an HTTPS endpoint, or HTTP on localhost."
        }
        if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a model that accepts images." }
        if provider != .compatible && key.isEmpty { return "Add your \(provider.title) key in AI settings." }
        return nil
    }

    func check() async throws -> String {
        if let error = configurationError { throw DesignerAssistantError.server(error) }
        if provider.isCLI {
            let result = try await LocalAIProcess.run(executable: executable!, arguments: provider == .codex ? ["login", "status"] : ["auth", "status"], input: Data(), timeout: 15)
            if provider == .codex {
                guard result.exitCode == 0 else { throw DesignerAssistantError.server("Codex is signed out. Click Sign in, then check again.") }
                return result.text.lowercased().contains("chatgpt") ? "Connected · ChatGPT account" : "Connected · Codex CLI authentication"
            }
            let json = try? JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]
            guard result.exitCode == 0, json?["loggedIn"] as? Bool == true else { throw DesignerAssistantError.server("Claude Code is signed out. Click Sign in, then check again.") }
            return "Connected · Claude Code (\(json?["authMethod"] as? String ?? "account"))"
        }
        var base = URL(string: endpoint)!.deletingLastPathComponent()
        if provider == .compatible && base.lastPathComponent == "chat" { base.deleteLastPathComponent() }
        let url = base.appendingPathComponent("models")
        var request = URLRequest(url: url); request.timeoutInterval = 20
        if provider == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DesignerAssistantError.server("Connection check failed. Check the endpoint and key. Some compatible servers do not support /models; you can still save and try Analyze.")
        }
        return "Connected · model compatibility is checked when you analyze"
    }

    @MainActor func signIn() throws {
        guard let executable else { throw DesignerAssistantError.server("Install \(provider == .codex ? "Codex" : "Claude Code") first, or choose its executable below.") }
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FrameNote/SignIn")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("\(provider.rawValue)-sign-in.command")
        let quoted = "'" + executable.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = provider == .codex ? "login" : "auth login"
        try Data("#!/bin/zsh\nexport PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:'\"$PATH\"\nunset OPENAI_API_KEY ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN\n\(quoted) \(command)\n".utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        NSWorkspace.shared.open(script)
    }
}

enum AIKeyStore {
    static func read(_ provider: AIProvider) -> String? {
        if provider == .openAI { return OpenAIKeyStore.read() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.framenote.ai",
            kSecAttrAccount as String: provider.rawValue, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ key: String, provider: AIProvider) -> Bool {
        if provider == .openAI { return OpenAIKeyStore.save(key) }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.framenote.ai", kSecAttrAccount as String: provider.rawValue]
        if key.isEmpty { let status = SecItemDelete(query as CFDictionary); return status == errSecSuccess || status == errSecItemNotFound }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        query[kSecValueData as String] = Data(key.utf8)
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
