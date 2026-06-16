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

    /// `seconds` saniyelik 16k mono s16 WAV kaydet; bitince dosya URL'i döner.
    func record(seconds: Double) async throws -> URL {
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
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            rec.updateMeters()
            let db = rec.averagePower(forChannel: 0)   // ~ -160..0 dB
            level = max(0, min(1, (db + 50) / 50))      // -50..0 dB → 0..1
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        rec.stop()
        isRecording = false
        level = 0
        recorder = nil
        #if os(iOS)
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        return url
    }
}
