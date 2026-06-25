import SwiftUI

// mate-ios kaynakları macOS istemcisiyle (mac-client) paylaşılıyor.
// iOS'a özgü SwiftUI modifier'ları burada platform-nötr sarmalanır:
// #if os(...) derleme zamanında tek dal bırakır, return tipi tutarlı kalır.

extension View {
    /// URL/token gibi teknik alanlar: otomatik büyük harf + düzeltme kapalı.
    func technicalField() -> some View {
        #if os(iOS)
        return self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        return self.autocorrectionDisabled()
        #endif
    }

    /// iOS'ta URL klavyesi; macOS'ta no-op (donanım klavyesi).
    func urlKeyboard() -> some View {
        #if os(iOS)
        return self.keyboardType(.URL)
        #else
        return self
        #endif
    }

    /// iOS'ta inline navigation başlığı; macOS'ta no-op.
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        return self.navigationBarTitleDisplayMode(.inline)
        #else
        return self
        #endif
    }

    /// macOS'ta Form'a iOS'taki gibi gruplu görünüm verir (varsayılan macOS
    /// form stili etiketleri sola taşırıp düzeni bozuyor); iOS'ta no-op.
    func groupedFormCompat() -> some View {
        #if os(macOS)
        return self.formStyle(.grouped)
        #else
        return self
        #endif
    }

    /// macOS'ta sheet'e makul bir pencere boyutu verir; iOS'ta no-op.
    func settingsSheetFrame() -> some View {
        #if os(macOS)
        return self.frame(minWidth: 560, idealWidth: 600, minHeight: 600, idealHeight: 700)
        #else
        return self
        #endif
    }
}
