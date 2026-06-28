import SwiftUI

/// Sıfır-konfig onboarding sihirbazı. Token endpoint URL'i boşsa (yeni kurulum)
/// `AppView` bunu gösterir — `ErrorView` yerine. Kullanıcı tek şey yapar: Hermes
/// sunucu adresini onayla (varsayılan prefill). Anahtar GEREKMEZ — bağlantı
/// `/mate/demo-token` (key'siz) ile kurulur; tanışma/enrollment ses üzerinden
/// sunucuda olur ("candan" → kendini tanıt → ses-ID kaydı). Bittiğinde `onDone`.
struct OnboardingView: View {
    @EnvironmentObject private var settings: SettingsStore
    var onDone: () -> Void

    @State private var url: String = {
        let cur = SettingsStore.resolvedTokenEndpointURL
        return cur.isEmpty ? SettingsStore.defaultTokenEndpointURL : cur
    }()

    private var trimmed: String { url.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 4 * .grid) {
            Spacer()

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)

            Text("Mate'e hoş geldin")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.fg1)

            Text("Tanışalım. Hermes sunucu adresini onayla; sonra mikrofona “candan” deyip kendini tanıt — sesinden seni tanıyacağım.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6 * .grid)

            TextField("https://…", text: $url)
                .textFieldStyle(.roundedBorder)
                #if !os(macOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                #endif
                .frame(maxWidth: 360)

            Button {
                guard !trimmed.isEmpty else { return }
                settings.tokenEndpointURL = trimmed // @Published → UserDefaults
                onDone()
            } label: {
                Text("Başla")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(maxWidth: 360)
                    .padding(.vertical, 2 * .grid)
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmed.isEmpty)

            Text("Anahtar gerekmez — sesinle tanınacaksın.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { GlassBackdrop() }
    }
}
