import Foundation
import os

/// mate-livekit-mac birleşik loglama (os_log / unified logging).
///
/// `print()` YERİNE bunu kullan — Release `.app`'te de çalışır, zaman damgalı,
/// kategori-bazlı filtrelenebilir. Mesaj formatı: `"[Kategori] gövde"` — köşeli
/// parantez içindeki etiket os_log **category**'sine ayrılır.
///
/// Terminalden okuma (mate-mac deseni — `process ==` DEĞİL, `subsystem ==`):
///   Canlı:   log stream --predicate 'subsystem == "mate.livekit"' --level debug
///   Geçmiş:  log show   --predicate 'subsystem == "mate.livekit"' --last 5m --info --debug
///   Yardımcı: ./logs.sh -f   (canlı)   ·   ./logs.sh Wake   (kategori)
/// `nonisolated`: ses render thread'i / SFSpeech handler'ı gibi arka plan
/// (main-actor olmayan) bağlamlardan da güvenle çağrılabilsin (modülün varsayılan
/// main-actor izolasyonu yoksa derleme hatası verirdi). Logger Sendable + state
/// kilitle korunuyor → güvenli.
enum Log {
    nonisolated static let subsystem = "mate.livekit"

    private nonisolated(unsafe) static var loggers: [String: Logger] = [:]
    private nonisolated(unsafe) static let lock = NSLock()

    private nonisolated static func logger(_ category: String) -> Logger {
        lock.lock(); defer { lock.unlock() }
        if let existing = loggers[category] { return existing }
        let made = Logger(subsystem: subsystem, category: category)
        loggers[category] = made
        return made
    }

    /// `"[Cat] mesaj"` → uygun kategoriye (varsayılan seviye, `log show`'da bayraksız görünür).
    nonisolated static func line(_ message: String) {
        let (cat, body) = split(message)
        logger(cat).log("\(body, privacy: .public)")
        appendFile(level: "", cat: cat, body: body)
    }

    /// Hata satırları (`log show --level error` ile süzülür).
    nonisolated static func error(_ message: String) {
        let (cat, body) = split(message)
        logger(cat).error("\(body, privacy: .public)")
        appendFile(level: "ERROR ", cat: cat, body: body)
    }

    // MARK: - Dosya çıktısı
    //
    // os_log bazı ortamlardan (sandbox'lı CLI / `log show`) OKUNAMIYOR. Bu yüzden
    // logları app sandbox container'ının Caches dizinine de yazıyoruz; geliştirici
    // doğrudan tail edebilir:
    //   tail -f ~/Library/Containers/com.drascom.mate.livekit/Data/Library/Caches/mate-livekit.log

    private nonisolated(unsafe) static var fileHandle: FileHandle?
    private nonisolated(unsafe) static var fileReady = false
    private nonisolated static let iso: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    nonisolated static var fileURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("mate-livekit.log")
    }

    private nonisolated static func openFileIfNeeded() {
        guard !fileReady else { return }
        fileReady = true
        let url = fileURL
        // Her açılışta taze dosya (eski koşunun gürültüsü karışmasın).
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
    }

    private nonisolated static func appendFile(level: String, cat: String, body: String) {
        lock.lock(); defer { lock.unlock() }
        openFileIfNeeded()
        guard let fh = fileHandle else { return }
        let line = "\(iso.string(from: Date())) \(level)[\(cat)] \(body)\n"
        if let data = line.data(using: .utf8) { fh.write(data) }
    }

    /// "[Cat] gövde" → ("Cat", "gövde"). Etiket yoksa ("App", tüm mesaj).
    private nonisolated static func split(_ message: String) -> (String, String) {
        guard message.hasPrefix("["), let end = message.firstIndex(of: "]") else {
            return ("App", message)
        }
        let cat = String(message[message.index(after: message.startIndex)..<end])
        let body = String(message[message.index(after: end)...])
            .trimmingCharacters(in: .whitespaces)
        return (cat, body)
    }
}
