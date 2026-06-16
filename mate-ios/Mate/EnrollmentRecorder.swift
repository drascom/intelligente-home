import Foundation
import AVFoundation

/// Speaker-ID enrollment için basit, sabit süreli kayıt: doğrudan 16 kHz mono
/// s16 WAV üretir (brain'in sherpa-onnx hattının beklediği format; soundfile
/// WAV okur). Ana ses döngüsünden (AudioPipeline) bağımsızdır — Settings açıkken
/// konuşma döngüsü zaten durdurulmuş olur, böylece mikrofon serbesttir.
@MainActor
final class EnrollmentRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var level: Float = 0      // 0..1 (metering'den)
    @Published var heard = false         // konuşma algılandı mı (UI ipucu)

    private var recorder: AVAudioRecorder?

    func requestPermission() async -> Bool {
        #if os(macOS)
        return await AVCaptureDevice.requestAccess(for: .audio)
        #else
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { cont in
                AVAudioApplication.requestRecordPermission { cont.resume(returning: $0) }
            }
        } else {
            return await withCheckedContinuation { cont in
                AVAudioSession.sharedInstance().requestRecordPermission { cont.resume(returning: $0) }
            }
        }
        #endif
    }

    /// Konuşmayı kaydet; konuşan **susunca otomatik durur** (kuyruk sessizlik).
    /// Sabit süre yerine endpointing: metering ile konuşma/sessizlik izlenir.
    /// - `maxSeconds`: üst sınır (kaçak kayıt önleme)
    /// - `silenceToStop`: konuşma başladıktan sonra bu kadar sessizlik → dur
    /// - `startTimeout`: hiç konuşulmazsa bu sürede kes
    func record(maxSeconds: Double = 15, silenceToStop: Double = 1.2,
                startTimeout: Double = 6) async throws -> URL {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("enroll-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        recorder = rec
        guard rec.record() else {
            recorder = nil
            throw NSError(domain: "Enrollment", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Kayıt başlatılamadı"])
        }
        isRecording = true
        heard = false

        let speechDb: Float = -28      // bunun üstü konuşma sayılır
        let silenceDb: Float = -38     // bunun altı sessizlik sayılır
        let poll = 0.05
        let start = Date()
        var speechSeen = false
        var silence = 0.0
        while true {
            rec.updateMeters()
            let db = rec.averagePower(forChannel: 0)   // ~ -160..0 dB
            level = max(0, min(1, (db + 50) / 50))      // -50..0 dB → 0..1
            let elapsed = Date().timeIntervalSince(start)
            if db > speechDb {
                speechSeen = true
                if !heard { heard = true }
                silence = 0
            } else if db < silenceDb {
                silence += poll
            } else {
                silence = 0   // ara bölge: ne konuşma ne kesin sessizlik
            }
            // Bitiş koşulları
            if speechSeen && silence >= silenceToStop { break }      // sustu
            if elapsed >= maxSeconds { break }                       // üst sınır
            if !speechSeen && elapsed >= startTimeout { break }      // hiç konuşmadı
            try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        rec.stop()
        isRecording = false
        heard = false
        level = 0
        recorder = nil
        #if os(iOS)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        return url
    }
}
