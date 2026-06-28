import SwiftUI

/// App settings screen.
///
/// Grows per-client settings as `Section`s in the `Form` below. Bindings write
/// straight through to the shared `SettingsStore` (persisted to UserDefaults).
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("settings.wake.section") {
                    Toggle("settings.wake.toggle", isOn: $settings.wakeWordEnabled)
                    TextField("settings.wake.word", text: $settings.wakeWord)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!settings.wakeWordEnabled)
                        #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        #endif
                    Text("settings.wake.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("settings.bargein.section") {
                    Toggle("settings.bargein.toggle", isOn: $settings.bargeInEnabled)
                    Text("settings.bargein.hint")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Hermes bağlantısı") {
                    TextField("Token endpoint URL", text: $settings.tokenEndpointURL)
                        .textFieldStyle(.roundedBorder)
                        #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        #endif
                    TextField("Client key (X-Mate-Key)", text: $settings.clientKey)
                        .textFieldStyle(.roundedBorder)
                        #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        #endif
                    TextField("Room (optional)", text: $settings.room)
                        .textFieldStyle(.roundedBorder)
                        #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        #endif
                    Text("mate_voice token endpoint: GET {url}/mate/token?identity=…&room=… · header X-Mate-Key. Boşsa bağlantı hata verir (ekrana düşer).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("settings.server.section") {
                    TextField("settings.server.livekit", text: $settings.livekitURL)
                        .textFieldStyle(.roundedBorder)
                        #if !os(macOS)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        #endif
                    Text("LiveKit URL — boşsa token endpoint'in döndürdüğü URL (wss://mate-livekit.drascom.uk) kullanılır.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background { GlassBackdrop() }
            .navigationTitle("settings.title")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("settings.close") { dismiss() }
                }
            }
            #if os(macOS)
                .frame(minWidth: 420, minHeight: 320)
            #endif
        }
    }
}
