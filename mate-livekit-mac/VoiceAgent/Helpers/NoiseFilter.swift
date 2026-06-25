import Foundation

/// stderr gürültü filtresi — VPIO / CoreAudio'nun saniyede yüzlerce kez bastığı
/// zararsız ama log'u boğan satırları ELER, geri kalan her şeyi gerçek stderr'e
/// olduğu gibi geçirir.
///
/// NEDEN: macOS 26'da VPIO (voice-processing) downlink DSP'si bozuk
/// ([[vpio-macos26-apple-bug]]); dahili çıkışta (VPIO=true) far-end işleme her
/// render slice'ında `kAudioUnitErr_TooManyFramesToProcess` (-10874) ve
/// `ProcessDownlinkAudio` hatası basıyor. Uygulama yine çalışıyor (wake + publish
/// OK) ama konsol/stderr binlerce satırla doluyor. Bu satırlar bizim Log.swift'ten
/// (os_log + dosya) GEÇMEZ — doğrudan CoreAudio C++ tarafından fd 2'ye yazılır.
/// Bu yüzden fd 2'yi bir pipe'tan geçirip desen-eşleşen satırları düşürüyoruz.
///
/// Bizim kendi loglarımız (os_log / candan-livekit.log) ETKİLENMEZ.
enum NoiseFilter {
    /// Bu alt-dizgelerden birini içeren stderr satırı düşürülür.
    private static let needles: [String] = [
        "failed to process downlink voice proc",
        "failed to run downlink DSP",
        "ProcessDownlinkAudio",
        "kAudioUnitErr_TooManyFramesToProcess",
        "aumx/mcmx/appl, render err: -10874",
        "IOWorkLoop: skipping cycle due to overload",
        "IOWorkLoop: context",          // "received an out of order message"
        "vpStrategyManager.mm",
        "Voice_Processor_Interface_Adapter",
        "Far_End_Voice_Proc_Node",
        "getting headset info",          // AQMEIO_HAL: USB headset HAL açılırken zararsız sorgu
    ]

    private nonisolated(unsafe) static var installed = false

    /// fd 2'yi (stderr) bir pipe'a yönlendirir; arka planda satır satır okuyup
    /// gürültüyü eler, kalanı kaydedilen gerçek stderr'e yazar. İdempotent.
    /// Audio motoru başlamadan ÖNCE (uygulama init başında) çağrılmalı.
    static func install() {
        guard !installed else { return }
        installed = true

        let savedStderrFD = dup(STDERR_FILENO)
        guard savedStderrFD >= 0 else { return }

        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { close(savedStderrFD); return }
        let readFD = fds[0]
        let writeFD = fds[1]

        // stderr (fd 2) artık pipe'ın yazma ucuna gitsin.
        guard dup2(writeFD, STDERR_FILENO) >= 0 else {
            close(savedStderrFD); close(readFD); close(writeFD); return
        }
        close(writeFD) // fd 2 zaten kopyasını tutuyor

        let realStderr = FileHandle(fileDescriptor: savedStderrFD, closeOnDealloc: false)
        let reader = FileHandle(fileDescriptor: readFD, closeOnDealloc: true)

        let queue = DispatchQueue(label: "candan.stderr.filter", qos: .utility)
        queue.async {
            var pending = [UInt8]()
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break } // EOF
                pending.append(contentsOf: chunk)

                // Tam satırları (\n) işle; son eksik parça pending'de kalır.
                while let nl = pending.firstIndex(of: 0x0A) {
                    let lineBytes = Array(pending[..<nl])
                    pending.removeSubrange(...nl)
                    let line = String(decoding: lineBytes, as: UTF8.self)
                    if needles.contains(where: { line.contains($0) }) { continue } // gürültü → düşür
                    var out = lineBytes
                    out.append(0x0A)
                    out.withUnsafeBytes { realStderr.write(Data($0)) }
                }
            }
        }
    }
}
