import SwiftUI

/// Yönlendirmeli enrollment sihirbazı: kişiye sırayla cümleler verir, her birini
/// okurken kısa bir kayıt alıp brain'e yükler. Tutarlı, fonem açısından çeşitli
/// örnekler toplamayı kolaylaştırır.
struct EnrollmentWizardView: View {
    let speaker: Speaker
    let baseURL: String?
    let apiKey: String
    let source: String
    var onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var recorder = EnrollmentRecorder()
    private let api = APIClient()

    @State private var stepIndex = 0
    @State private var added = 0
    @State private var uploading = false
    @State private var errorText: String?
    @State private var finished = false

    private let prompts = EnrollmentPrompts.sentences

    var body: some View {
        NavigationStack {
            Group {
                if finished { completion } else { stepBody }
            }
            .padding()
            .navigationTitle(speaker.name)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { onFinished(); dismiss() }
                }
            }
        }
    }

    private var stepBody: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                ProgressView(value: Double(stepIndex), total: Double(prompts.count))
                Text("Cümle \(stepIndex + 1)/\(prompts.count)  •  \(added) örnek")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text("Butona basıp cümleyi normal sesinizle okuyun — bitince kayıt otomatik durur:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text(prompts[stepIndex])
                .font(.title3)
                .fontWeight(.medium)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            if recorder.isRecording {
                VStack(spacing: 10) {
                    Label(recorder.heard ? "Dinliyorum… bitince durur" : "Okumaya başlayın…",
                          systemImage: "waveform")
                        .foregroundStyle(.red)
                    ProgressView(value: Double(recorder.level))
                }
            } else if uploading {
                ProgressView("Gönderiliyor…")
            } else {
                Button {
                    Task { await recordStep() }
                } label: {
                    Label("Kaydet ve oku", systemImage: "mic.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderedProminent)
            }

            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
            }

            Spacer()
        }
    }

    private var completion: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("\(speaker.name) kaydedildi")
                .font(.title3)
            Text("\(added) örnek eklendi. İstediğiniz zaman sihirbazı tekrar çalıştırıp "
                 + "daha fazla örnek ekleyebilirsiniz — ne kadar çok, tanıma o kadar isabetli.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Bitti") { onFinished(); dismiss() }
                .buttonStyle(.borderedProminent)
        }
    }

    private func recordStep() async {
        guard let baseURL else { errorText = "Geçersiz sunucu URL'i"; return }
        errorText = nil
        do {
            let url = try await recorder.record()
            uploading = true
            defer { uploading = false }
            let data = try Data(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            _ = try await api.uploadSample(baseURL: baseURL, apiKey: apiKey,
                                           speakerId: speaker.id, wavData: data, source: source)
            added += 1
            if stepIndex + 1 < prompts.count {
                stepIndex += 1
            } else {
                finished = true
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// Enrollment cümleleri: kısa, doğal, fonem açısından çeşitli (sayılar + Türkçe
/// karakterler dahil). Far-field robustluk için normal evde okunması yeterli.
enum EnrollmentPrompts {
    // ÖNEMLİ: cümleler wake word ("candan") İÇERMEMELİ — yoksa okurken odadaki
    // dinleyen cihazlar (mac/iPhone/satellite) tetiklenir.
    static let sentences: [String] = [
        "İyi günler, ben bu evde yaşayan kişilerden biriyim.",
        "Bugün hava oldukça güzel, dışarı çıkmak için ideal bir gün.",
        "Lütfen salondaki lambayı aç ve perdeleri yavaşça kapat.",
        "Bir, iki, üç, dört, beş, altı, yedi, sekiz, dokuz, on.",
        "Yarın sabah saat dokuzda beni nazikçe uyandırmanı istiyorum.",
        "Çığlık, ağaç, şemsiye, öğretmen, gönül — Türkçenin sesleri.",
    ]
}
