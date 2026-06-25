import Foundation
import os

/// mate-mac birleşik loglama (os_log / unified logging).
///
/// `print()` YERİNE bunu kullan. Avantaj: Release `.app`'te de çalışır (Xcode
/// gerekmez), zaman damgalı, kategori-bazlı filtrelenebilir, ring-buffer'da
/// kalıcı. Mesaj formatı eskisiyle aynı: `"[Kategori] gövde"` — köşeli parantez
/// içindeki etiket os_log **category**'sine ayrılır, gerisi mesaj olur.
///
/// Terminalden okuma:
///   Canlı (debug dahil):
///     log stream --predicate 'subsystem == "uk.drascom.mate"' --level debug
///   Geçmiş (son 5 dk, default seviyeler):
///     log show --predicate 'subsystem == "uk.drascom.mate"' --last 5m
///   Geçmiş + info/debug:
///     log show --predicate 'subsystem == "uk.drascom.mate"' --last 5m --info --debug
///   Tek kategori (ör. barge-in):
///     log show --predicate 'subsystem == "uk.drascom.mate" AND category == "BargeIn"' --last 5m
///
/// DİKKAT: Bu dosya mate-ios/Mate'e de KOPYALANMALI (project.yml notu: ortak
/// mantık iki projede de tutulur).
enum Log {
    static let subsystem = "uk.drascom.mate"

    private static var loggers: [String: Logger] = [:]
    private static let lock = NSLock()

    private static func logger(_ category: String) -> Logger {
        lock.lock(); defer { lock.unlock() }
        if let existing = loggers[category] { return existing }
        let made = Logger(subsystem: subsystem, category: category)
        loggers[category] = made
        return made
    }

    /// `"[Cat] mesaj"` satırını uygun kategoriye yazar (varsayılan seviye —
    /// `log show`'da bayraksız görünür). Etiket yoksa kategori "App" olur.
    static func line(_ message: String) {
        let (cat, body) = split(message)
        logger(cat).log("\(body, privacy: .public)")
    }

    /// Spam'li / per-frame teşhis logları için. `.debug` seviyesi diske kalıcı
    /// yazılmaz; yalnızca `log stream` veya `--debug` ile görünür.
    static func debug(_ message: String) {
        let (cat, body) = split(message)
        logger(cat).debug("\(body, privacy: .public)")
    }

    /// Hata satırları — `log show`'da `--level error` ile süzülebilir.
    static func error(_ message: String) {
        let (cat, body) = split(message)
        logger(cat).error("\(body, privacy: .public)")
    }

    /// "[Cat] gövde" → ("Cat", "gövde"). Etiket yoksa ("App", tüm mesaj).
    private static func split(_ message: String) -> (String, String) {
        guard message.hasPrefix("["), let end = message.firstIndex(of: "]") else {
            return ("App", message)
        }
        let cat = String(message[message.index(after: message.startIndex)..<end])
        let body = String(message[message.index(after: end)...])
            .trimmingCharacters(in: .whitespaces)
        return (cat, body)
    }
}
