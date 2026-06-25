import SwiftUI

/// Ayarlar ekranı. Sheet olarak sunulur; draft state üzerinde çalışır,
/// "Kaydet" ile store'a yazılır (Vazgeç değişiklikleri atar).
struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var draftLanguage = "tr"
    @State private var draftVoice = "nese"
    @State private var draftSTTEngine = "whisper"
    @State private var draftWakeEnabled = true
    @State private var draftWakeWord = "candan"
    @State private var draftCuesEnabled = true
    @State private var draftBargeIn = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Ses Motoru") {
                    Picker("Dil", selection: $draftLanguage) {
                        Text("Türkçe").tag("tr")
                        Text("İngilizce").tag("en-US")
                        Text("Almanca").tag("de-DE")
                        Text("Fransızca").tag("fr-FR")
                        Text("İspanyolca").tag("es-ES")
                    }
                    .pickerStyle(.menu)

                    TextField("Ses (örn: nese)", text: $draftVoice)
                        .textFieldStyle(.roundedBorder)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif

                    Picker("STT motoru", selection: $draftSTTEngine) {
                        Text("Whisper").tag("whisper")
                        Text("Nemotron").tag("nemotron")
                    }
                    .pickerStyle(.menu)

                    Text("Dil, ses ve STT motoru sunucuya (brain) gönderilir; yanıt buna göre üretilir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Wake Word") {
                    Toggle("Wake word kullan", isOn: $draftWakeEnabled)
                    TextField("Tetikleyici kelime (örn: candan)", text: $draftWakeWord)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!draftWakeEnabled)
                        #if !os(macOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #endif
                    Text("Açıkken \"\(draftWakeWord.isEmpty ? "—" : draftWakeWord)\" duyulana kadar bekler; kapalıyken sürekli dinler.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Geçiş Sesleri") {
                    Toggle("Bip sesleri", isOn: $draftCuesEnabled)
                    Text("Wake, konuşma sonu ve uyku geçişlerinde kısa yumuşak tonlar çalar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Sözünü Kes / Barge-in") {
                    Toggle("Konuşurken müdahaleye izin ver", isOn: $draftBargeIn)
                    Text("Açıkken konuşmaya başladığında ajan susup sana döner; kapalıyken sözünü bitirir.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Ayarlar")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") { save() }
                        .fontWeight(.semibold)
                }
            }
            .onAppear {
                draftLanguage = settings.language
                draftVoice = settings.voice
                draftSTTEngine = settings.sttEngine.isEmpty ? "whisper" : settings.sttEngine
                draftWakeEnabled = settings.wakeWordEnabled
                draftWakeWord = settings.wakeWord
                draftCuesEnabled = settings.cuesEnabled
                draftBargeIn = settings.bargeInEnabled
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 460)
        #endif
    }

    private func save() {
        settings.language = draftLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.voice = draftVoice.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.sttEngine = draftSTTEngine.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.wakeWordEnabled = draftWakeEnabled
        settings.wakeWord = draftWakeWord.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        settings.cuesEnabled = draftCuesEnabled
        settings.bargeInEnabled = draftBargeIn
        dismiss()
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsStore())
}
