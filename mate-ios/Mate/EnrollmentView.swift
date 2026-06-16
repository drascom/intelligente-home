import SwiftUI

/// Speaker-ID (voice-ID) kayıt ekranı: kişi ekle, her kişi için birkaç kısa ses
/// örneği kaydet (3 sn, 16k mono WAV → brain). Settings içinden açılır; o sırada
/// konuşma döngüsü zaten durdurulmuş olur (mikrofon serbest).
struct EnrollmentView: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var recorder = EnrollmentRecorder()
    private let api = APIClient()

    @State private var speakers: [Speaker] = []
    @State private var newName = ""
    @State private var status: String?
    @State private var errorText: String?
    @State private var busy = false
    @State private var permissionDenied = false
    @State private var wizardSpeaker: Speaker?

    #if os(iOS)
    private let source = "ios"
    #else
    private let source = "mac"
    #endif

    private var base: String? { APIClient.httpBase(fromWS: settings.bridgeWSURL) }

    var body: some View {
        Form {
            Section {
                Text("Asistanın kimin konuştuğunu tanıması için her kişiyi sesinden "
                     + "kaydedin. Kişi başına 5–10 kısa örnek (~3 sn) önerilir; normal "
                     + "mesafeden, farklı cümlelerle.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Kişiler") {
                if speakers.isEmpty {
                    Text("Henüz kayıtlı kişi yok").foregroundStyle(.secondary)
                }
                ForEach(speakers) { sp in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sp.name)
                            Text("\(sp.samples) örnek")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            wizardSpeaker = sp
                        } label: {
                            Label("Kaydet", systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderless)
                        .disabled(permissionDenied)
                    }
                }
                .onDelete { idx in Task { await deleteSpeakers(at: idx) } }
            }

            Section("Yeni kişi") {
                HStack {
                    TextField("İsim", text: $newName)
                        .technicalField()
                    Button("Ekle") { Task { await addSpeaker() } }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || busy
                                  || recorder.isRecording)
                }
            }

            if let status {
                Section { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
            if let errorText {
                Section { Text(errorText).font(.caption).foregroundStyle(.red) }
            }
            if permissionDenied {
                Section {
                    Text("Mikrofon izni gerekli — Ayarlar'dan izin verin.")
                        .foregroundStyle(.red)
                }
            }
        }
        .groupedFormCompat()
        .navigationTitle("Konuşmacılar")
        .inlineNavigationTitle()
        .task { await firstLoad() }
        .sheet(item: $wizardSpeaker) { sp in
            EnrollmentWizardView(speaker: sp, baseURL: base, apiKey: settings.bridgeApiKey,
                                 source: source) {
                Task { await load() }
            }
        }
    }

    // ---- actions ----

    private func firstLoad() async {
        if !(await recorder.requestPermission()) { permissionDenied = true }
        await load()
    }

    private func load() async {
        guard let base else { errorText = "Geçersiz sunucu URL'i"; return }
        do {
            speakers = try await api.listSpeakers(baseURL: base, apiKey: settings.bridgeApiKey)
            errorText = nil
        } catch {
            errorText = describe(error)
        }
    }

    private func addSpeaker() async {
        guard let base else { return }
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        busy = true; defer { busy = false }
        do {
            _ = try await api.createSpeaker(baseURL: base, apiKey: settings.bridgeApiKey, name: name)
            newName = ""
            status = "\(name) eklendi"
            await load()
        } catch {
            errorText = describe(error)
        }
    }

    private func deleteSpeakers(at idx: IndexSet) async {
        guard let base else { return }
        let targets = idx.map { speakers[$0] }
        for sp in targets {
            try? await api.deleteSpeaker(baseURL: base, apiKey: settings.bridgeApiKey, speakerId: sp.id)
        }
        await load()
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
