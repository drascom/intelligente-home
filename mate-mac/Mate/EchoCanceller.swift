import Foundation

/// Barge-in için **enerji-kapılı double-talk** tespiti (+ speexdsp denoise).
///
/// macOS 26 donanım VPIO bozuk; örnek-hizalı yazılım AEC streaming gecikmesi
/// yüzünden yakınsamadı. Onun yerine GECİKMEYE DUYARSIZ enerji yaklaşımı:
///
///   eko ≈ coupling × far_env           (coupling = akustik yol kazancı, yavaş)
///   excess = mic_env − coupling × far_env
///
/// far-end enerjisi PUSH-temelli izlenir (hoparlöre gönderdiğimiz parçalardan) —
/// ring-read underrun'ı yaşanmaz. Zarflar YAVAŞ (~300ms) → hece dalgalanması ve
/// hoparlör→mic gecikmesi hizalaması affedilir; sadece sürekli (kullanıcı konuşması)
/// enerji artışı barge-in tetikler.
///
/// iOS'ta donanım VPIO çalıştığından bu yol DEVREYE GİRMEZ (active hiç açılmaz).
final class EchoCanceller {
    static let shared = EchoCanceller()

    private(set) var active = false
    private(set) var ready = false           // coupling kalibre oldu mu

    private var preprocess: OpaquePointer?
    private var frameSize = 0
    private var sampleRate: Int32 = 0

    private let lock = NSLock()
    private var farInstant: Float = 0         // en son push edilen far-end RMS (held)

    // tap-thread durumu.
    private var pendingMic = [Float]()
    private var micI16 = [Int16]()

    private var micEnv: Float = 0
    private var farEnv: Float = 0
    private var coupling: Float = 0
    private var calibFrames = 0
    private let calibTarget = 25              // ~250ms echo-only kalibrasyon
    private let envAlpha: Float = 0.04        // yavaş zarf (~250ms zaman sabiti)
    private let couplingAlpha: Float = 0.02
    private let dtMargin: Float = 1.8         // mic_env > margin × tahmini_eko → double-talk
    private var logCounter = 0

    private init() {}

    func configure(sampleRate: Int) {
        lock.lock(); defer { lock.unlock() }
        if self.sampleRate == Int32(sampleRate), preprocess != nil { return }
        destroy()
        self.sampleRate = Int32(sampleRate)
        frameSize = sampleRate / 100
        pendingMic.removeAll(keepingCapacity: true)
        micI16 = [Int16](repeating: 0, count: frameSize)
        preprocess = speex_preprocess_state_init(Int32(frameSize), Int32(sampleRate))
        var on: Int32 = 1, off: Int32 = 0
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_DENOISE, &on)
        speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_AGC, &off)
        Log.line("[AEC] hazır sr=\(sampleRate)Hz frame=\(frameSize) (enerji-kapılı + denoise)")
    }

    private func destroy() {
        if let p = preprocess { speex_preprocess_state_destroy(p); preprocess = nil }
    }
    deinit { destroy() }

    func begin() {
        lock.lock()
        farInstant = 0; micEnv = 0; farEnv = 0; coupling = 0; calibFrames = 0; logCounter = 0
        ready = false
        active = true
        lock.unlock()
        Log.line("[AEC] başladı (TTS playback)")
    }

    func end() {
        guard active else { return }
        lock.lock(); active = false; lock.unlock()
        Log.line(String(format: "[AEC] bitti — coupling=%.2f", coupling))
    }

    /// Far-end (çalınan TTS) parçasının RMS'ini tut (push-temelli envelope kaynağı).
    func pushFarEnd(_ samples: UnsafePointer<Float>, count: Int) {
        guard active, count > 0 else { return }
        var sq: Float = 0
        for i in 0..<count { let v = samples[i]; sq += v * v }
        let rms = sqrtf(sq / Float(count))
        lock.lock(); farInstant = rms; lock.unlock()
    }

    /// Near-end mic → "kullanıcı sesi fazlası" seviyesi (0..1). echo-only ≈ 0.
    func processForLevel(_ samples: UnsafePointer<Float>, count: Int) -> Float? {
        guard active, frameSize > 0, preprocess != nil else { return nil }
        for i in 0..<count { pendingMic.append(samples[i]) }
        var lastLevel: Float? = nil
        while pendingMic.count >= frameSize {
            for i in 0..<frameSize { micI16[i] = Self.f2i(pendingMic[i]) }
            pendingMic.removeFirst(frameSize)
            speex_preprocess_run(preprocess, &micI16)   // fan gürültüsü denoise
            var micSq: Float = 0
            for i in 0..<frameSize { let v = Self.i2f(micI16[i]); micSq += v * v }
            let micRms = sqrtf(micSq / Float(frameSize))

            lock.lock(); let farRms = farInstant; lock.unlock()

            micEnv += envAlpha * (micRms - micEnv)
            farEnv += envAlpha * (farRms - farEnv)
            lastLevel = gate()
        }
        return lastLevel
    }

    private func gate() -> Float? {
        let predicted = coupling * farEnv
        let excess = micEnv - predicted

        if !ready {
            if farEnv > 0.003 {
                let inst = micEnv / max(farEnv, 1e-6)
                coupling = coupling == 0 ? inst : coupling + couplingAlpha * (inst - coupling)
                calibFrames += 1
                if calibFrames >= calibTarget {
                    ready = true
                    Log.line(String(format: "[AEC] kalibre — coupling=%.2f micEnv=%.4f farEnv=%.4f",
                                    coupling, micEnv, farEnv))
                }
            }
            return nil
        }

        let isDoubleTalk = micEnv > dtMargin * predicted
        // double-talk değilken coupling'i yavaşça izle; konuşma sırasında dondur.
        if !isDoubleTalk, farEnv > 0.003 {
            coupling += couplingAlpha * (micEnv / max(farEnv, 1e-6) - coupling)
        }

        logCounter += 1
        if logCounter % 50 == 0 {
            Log.debug(String(format: "[AEC] mic=%.4f far=%.4f pred=%.4f excess=%.4f coup=%.2f dt=%@",
                            micEnv, farEnv, predicted, excess, coupling, isDoubleTalk ? "Y" : "n"))
        }

        guard excess > 0 else { return 0 }
        let db = 20 * log10f(max(excess, 1e-9))
        let minDb: Float = -55
        if db < minDb { return 0 }
        if db >= 0 { return 1 }
        return (db - minDb) / -minDb
    }

    @inline(__always) private static func f2i(_ x: Float) -> Int16 {
        let v = max(-1, min(1, x)) * 32767
        return Int16(v)
    }
    @inline(__always) private static func i2f(_ x: Int16) -> Float { Float(x) / 32768.0 }
}
