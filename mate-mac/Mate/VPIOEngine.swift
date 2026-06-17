#if os(macOS)
import Foundation
import AudioToolbox
import CoreAudio

/// macOS için raw `AUVoiceProcessingIO` ses I/O — DONANIM AEC.
///
/// macOS 26'da AVAudioEngine'in voice-processing sarmalayıcısı -10875 ile patlıyor
/// (kendi aggregate kurulumu bozuk); ama raw VPIO AudioUnit default cihazda
/// sorunsuz init oluyor (probe ile kanıtlandı). Bu sınıf TTS playback'i ve mic
/// capture'ı AYNI VPIO unit'inden geçirir → OS, hoparlör ekosunu mic'ten donanım
/// seviyesinde siler (iOS'la aynı kalite). Cihaz bind ETMEYİZ → default cihaz
/// (tek-cihaz picker sistem default'unu zaten ayarlıyor).
///
/// iOS bu sınıfı kullanmaz (orada AVAudioEngine+VPIO çalışıyor).
final class VPIOEngine {
    static let sampleRate: Double = 48000
    private(set) var running = false

    private var unit: AudioUnit?

    // TTS çıkış halkası (Float32 mono) — app push eder, output render çeker.
    private var outRing: [Float]
    private var outRead = 0
    private var outWrite = 0
    private var outCount = 0
    private let outCap: Int
    private let outLock = NSLock()

    // Mic render hedefi (input callback'te AudioUnitRender ile doldurulur).
    private var micScratch: [Float]
    private let micFrames = 4096

    /// Echo-cancel edilmiş mic örnekleri (Float32 mono) — audio thread'den çağrılır.
    var onMic: ((UnsafePointer<Float>, Int) -> Void)?

    init() {
        outCap = Int(Self.sampleRate) * 3   // 3 sn TTS tamponu
        outRing = [Float](repeating: 0, count: outCap)
        micScratch = [Float](repeating: 0, count: micFrames)
    }

    // MARK: - Yaşam döngüsü

    func start() throws {
        guard !running else { return }
        var acd = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &acd) else {
            throw err("VPIO bileşeni bulunamadı")
        }
        var u: AudioUnit?
        try check(AudioComponentInstanceNew(comp, &u), "InstanceNew")
        guard let unit = u else { throw err("instance nil") }
        self.unit = unit

        // IO'yu aç: input element 1, output element 0.
        var one: UInt32 = 1
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &one, 4), "EnableIO input")
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &one, 4), "EnableIO output")
        // Cihaz BIND ETME → default (probe: bind edince -10875). Tek-cihaz picker
        // sistem default giriş/çıkışını zaten ayarlıyor.

        // Akış formatı: 48k Float32 mono, her iki yön.
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Self.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        // Bizim oynatma için verdiğimiz format (output element 0, input scope).
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "StreamFormat out")
        // Bizim aldığımız mic format (input element 1, output scope).
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &asbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)),
            "StreamFormat in")

        let me = Unmanaged.passUnretained(self).toOpaque()
        // Çıkış render callback (oynatılacak TTS'i biz sağlarız).
        var outCB = AURenderCallbackStruct(inputProc: vpioOutputRender, inputProcRefCon: me)
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0, &outCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "SetRenderCallback")
        // Giriş callback (mic hazır olunca AudioUnitRender ile çekeriz).
        var inCB = AURenderCallbackStruct(inputProc: vpioInputAvailable, inputProcRefCon: me)
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0, &inCB, UInt32(MemoryLayout<AURenderCallbackStruct>.size)),
            "SetInputCallback")

        try check(AudioUnitInitialize(unit), "Initialize")
        try check(AudioOutputUnitStart(unit), "Start")
        running = true
        Log.line("[VPIO] başladı — donanım AEC (48k mono, default cihaz)")
    }

    func stop() {
        guard running, let unit else { return }
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil
        running = false
        outLock.lock(); outRead = 0; outWrite = 0; outCount = 0; outLock.unlock()
        Log.line("[VPIO] durdu")
    }

    // MARK: - TTS çıkış halkası

    /// Oynatılacak TTS örneklerini (Float32 mono) kuyruğa ekle.
    func enqueuePlayback(_ samples: UnsafePointer<Float>, count: Int) {
        outLock.lock(); defer { outLock.unlock() }
        for i in 0..<count {
            outRing[outWrite] = samples[i]
            outWrite = (outWrite + 1) % outCap
            if outCount < outCap { outCount += 1 } else { outRead = (outRead + 1) % outCap }
        }
    }

    /// Bekleyen oynatma örneği sayısı (drain takibi için).
    var pendingPlayback: Int { outLock.lock(); defer { outLock.unlock() }; return outCount }

    /// Oynatma kuyruğunu boşalt (barge-in / iptal).
    func flushPlayback() {
        outLock.lock(); outRead = 0; outWrite = 0; outCount = 0; outLock.unlock()
    }

    // MARK: - Render (audio thread)

    /// Output render: kuyruktaki TTS'i ioData'ya kopyala (yoksa sessizlik).
    fileprivate func renderOutput(frames: UInt32, ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
        guard let ioData else { return noErr }
        let abl = UnsafeMutableAudioBufferListPointer(ioData)
        let n = Int(frames)
        outLock.lock()
        for buf in abl {
            guard let ptr = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for i in 0..<n {
                if outCount > 0 {
                    ptr[i] = outRing[outRead]
                    outRead = (outRead + 1) % outCap
                    outCount -= 1
                } else {
                    ptr[i] = 0
                }
            }
        }
        outLock.unlock()
        return noErr
    }

    /// Input available: mic'i (echo-cancel edilmiş) render edip tüketiciye ver.
    fileprivate func renderInput(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 ts: UnsafePointer<AudioTimeStamp>,
                                 bus: UInt32, frames: UInt32) -> OSStatus {
        guard let unit else { return noErr }
        let n = min(Int(frames), micFrames)
        return micScratch.withUnsafeMutableBufferPointer { mp -> OSStatus in
            var abl = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: 1,
                                      mDataByteSize: UInt32(n * 4),
                                      mData: mp.baseAddress))
            let st = AudioUnitRender(unit, flags, ts, bus, UInt32(n), &abl)
            if st == noErr, let base = mp.baseAddress {
                onMic?(base, n)
            }
            return st
        }
    }

    // MARK: - Yardımcılar

    private func check(_ st: OSStatus, _ what: String) throws {
        if st != noErr { throw err("\(what) başarısız (st=\(st))") }
    }
    private func err(_ msg: String) -> NSError {
        Log.line("[VPIO] HATA: \(msg)")
        return NSError(domain: "VPIO", code: -1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}

// MARK: - C render callback köprüleri (yakalama yok → serbest fonksiyon)

private func vpioOutputRender(_ refCon: UnsafeMutableRawPointer,
                              _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                              _ ts: UnsafePointer<AudioTimeStamp>,
                              _ bus: UInt32, _ frames: UInt32,
                              _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let engine = Unmanaged<VPIOEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.renderOutput(frames: frames, ioData: ioData)
}

private func vpioInputAvailable(_ refCon: UnsafeMutableRawPointer,
                                _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                _ ts: UnsafePointer<AudioTimeStamp>,
                                _ bus: UInt32, _ frames: UInt32,
                                _ ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let engine = Unmanaged<VPIOEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.renderInput(flags: flags, ts: ts, bus: bus, frames: frames)
}
#endif
