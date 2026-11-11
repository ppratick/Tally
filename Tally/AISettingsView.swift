import SwiftUI

struct AISettingsView: View {
    @Environment(TallyStore.self) private var store
    @State private var key = ""
    @State private var error: String?
    @State private var confirmingRemoval = false
    var body: some View {
        Form {
            Section {
                Label(store.hasOpenAIKey ? "Key saved on this device" : "No saved key", systemImage: store.hasOpenAIKey ? "checkmark.shield" : "key")
                    .foregroundStyle(.secondary).accessibilityIdentifier("ai.keyStatus")
                SecureField(store.hasOpenAIKey ? "Paste replacement API key" : "Paste OpenAI API key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .accessibilityIdentifier("ai.apiKey")
                Button(store.hasOpenAIKey ? "Replace Key" : "Save Key") {
                    perform {
                        try OpenAIKeyStore.save(key)
                        key = ""; store.refreshOpenAIKeyStatus()
                    }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.chatSending)
                if store.hasOpenAIKey {
                    Button("Remove Key", role: .destructive) { confirmingRemoval = true }.disabled(store.chatSending)
                }
            } header: { Text("OpenAI API key") } footer: {
                Text("Your key is saved in this iPhone’s Keychain. For each chat request, it is sent securely to your Tally server to contact OpenAI. It isn’t saved in the server database or chat history. Saving checks the format; OpenAI verifies the key when you send a message.")
            }
            Section {
                LabeledContent("Model", value: "GPT-6 Luna")
                Text("Your questions and relevant financial data are sent to OpenAI. Usage is billed to your OpenAI API account.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Ask Tally").navigationBarTitleDisplayMode(.inline)
        .onAppear { store.refreshOpenAIKeyStatus() }
        .onDisappear { key = "" }
        .confirmationDialog("Remove the saved OpenAI key?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Key", role: .destructive) {
                perform { try OpenAIKeyStore.remove(); key = ""; store.refreshOpenAIKeyStatus() }
            }
        }
        .alert("Couldn't update your OpenAI key", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { self.error = error.localizedDescription }
    }
}
