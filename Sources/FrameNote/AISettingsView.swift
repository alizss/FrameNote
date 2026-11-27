import AppKit
import SwiftUI

struct AISettingsView: View {
    var onSave: () -> Void
    var onCancel: () -> Void
    @State private var connection = AIConnection.load()
    @State private var checking = false
    @State private var connectionStatus = ""
    @State private var connectionFailed = false
    @State private var savingError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect AI").font(.title2.weight(.semibold))
            Text("Choose what powers Analyze. Copy for AI works with any tool without a connection.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Use", selection: $connection.provider) {
                ForEach(AIProvider.allCases) { provider in Text(provider.title).tag(provider) }
            }.pickerStyle(.radioGroup)
            Divider()
            Text(connection.provider.detail).font(.callout).foregroundStyle(.secondary)
            if connection.provider.isCLI {
                HStack {
                    Button("Sign in…") {
                        do {
                            try connection.signIn()
                            connectionStatus = "Complete sign-in in Terminal, then click Check connection."
                            connectionFailed = false
                        } catch { connectionStatus = error.localizedDescription; connectionFailed = true }
                    }
                    checkButton
                }
                DisclosureGroup("Model & app location") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Model (blank uses CLI default)", text: $connection.model).textFieldStyle(.roundedBorder)
                        HStack {
                            TextField("Executable (auto-detected)", text: $connection.executablePath).textFieldStyle(.roundedBorder)
                            Button("Choose…") {
                                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                                panel.message = "Choose the codex or claude executable"
                                if panel.runModal() == .OK, let url = panel.url { connection.executablePath = url.path }
                            }
                        }
                    }.padding(.top, 6)
                }.font(.callout)
            } else {
                SecureField(connection.provider == .compatible ? "API key (optional for local servers)" : "API key", text: $connection.key)
                    .textFieldStyle(.roundedBorder)
                TextField("Vision model ID", text: $connection.model).textFieldStyle(.roundedBorder)
                TextField("API endpoint", text: $connection.endpoint).textFieldStyle(.roundedBorder)
                HStack {
                    checkButton
                    Button("Remove saved key") {
                        if AIKeyStore.save("", provider: connection.provider) {
                            connection.key = ""; connectionStatus = "Saved key removed."; connectionFailed = false
                        } else { savingError = "Could not remove the key from Keychain." }
                    }.disabled(AIKeyStore.read(connection.provider) == nil)
                }
                Text("Keys are stored in macOS Keychain. The model must support image input to review video frames.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !connectionStatus.isEmpty {
                Text(connectionStatus).font(.callout).foregroundStyle(connectionFailed ? Color.red : Color.secondary)
                    .textSelection(.enabled)
            }
            if let savingError { Text(savingError).font(.callout).foregroundStyle(.red) }
            Text("Only the review evidence is sent when you click Analyze. Local account options use the official CLI session on this Mac; FrameNote does not copy its login tokens.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Use \(connection.provider.title)") {
                    connection.model = connection.model.trimmingCharacters(in: .whitespacesAndNewlines)
                    connection.endpoint = connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                    connection.key = connection.key.trimmingCharacters(in: .whitespacesAndNewlines)
                    connection.executablePath = connection.executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let error = connection.configurationError { savingError = error; return }
                    guard connection.save() else { savingError = "Could not store your API key in Keychain."; return }
                    onSave()
                }.buttonStyle(.borderedProminent).disabled(checking)
            }
        }
        .padding(22).frame(width: 520)
        .onChange(of: connection.provider) { _, provider in
            connection = AIConnection.load(provider: provider)
            connectionStatus = ""; savingError = nil; connectionFailed = false
        }
        .task(id: connection.provider) { if connection.provider.isCLI { await checkConnection() } }
    }

    private var checkButton: some View {
        Button {
            Task { await checkConnection() }
        } label: {
            HStack(spacing: 6) {
                if checking { ProgressView().controlSize(.small) }
                Text(checking ? "Checking…" : "Check connection")
            }
        }.disabled(checking)
    }

    private func checkConnection() async {
        let snapshot = connection
        checking = true
        defer { checking = false }
        do {
            let message = try await snapshot.check()
            guard snapshot.provider == connection.provider, !Task.isCancelled else { return }
            connectionStatus = message; connectionFailed = false
        } catch {
            guard snapshot.provider == connection.provider, !Task.isCancelled else { return }
            connectionStatus = error.localizedDescription; connectionFailed = true
        }
    }
}
