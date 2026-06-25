import LiveKitComponents
import SwiftUI

/// Bağlantı durumu ekranı (eski StartView'in yerine).
///
/// Manuel buton YOKTUR — uygulama HEP bağlı olmalı: açılışta otomatik bağlanır;
/// bağlantı koptuğunda (ağ vs.) bu ekran tekrar görünür ve kendiliğinden yeniden
/// bağlanır. Hata olsa bile kullanıcı müdahalesi gerekmeden kendini onarır
/// (kısa beklemeyle yeniden dener). Bağlanma başarılı olunca AppView
/// `interactions()`'a geçer ve (wakeWordEnabled ise) WakeCoordinator uyku moduna
/// girip "candan" bekler.
struct ConnectingView: View {
    @EnvironmentObject private var session: Session

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: 6 * .grid) {
            if let error = session.error {
                errorState(error)
            } else {
                connectingState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, horizontalSizeClass == .regular ? 32 * .grid : 16 * .grid)
        // HEP bağlı kal: hata yokken otomatik bağlan.
        // session.start() yalnızca bağlantı kopuksa iş yapar (aksi halde no-op).
        .task {
            guard session.error == nil else { return }
            await session.start()
        }
        // Hata varsa kendi kendine onar: kısa bekleme + yeniden dene (sıkı döngü
        // olmasın diye her denemede bekle). Manuel buton yok.
        .task(id: session.error?.localizedDescription) {
            guard session.error != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            session.dismissError()
            await session.start()
        }
        #if os(visionOS)
        .glassBackgroundEffect()
        .frame(maxWidth: 175 * .grid)
        #endif
    }

    private func connectingState() -> some View {
        VStack(spacing: 4 * .grid) {
            Spinner()
            Text("Bağlanılıyor…")
                .font(.system(size: 15))
                .foregroundStyle(.fg3)
        }
    }

    /// Hata durumu: manuel buton YOK — kendi kendine yeniden dener (bkz. body'deki
    /// `.task(id:)`). Kullanıcıya yalnızca durum gösterilir.
    private func errorState(_ error: Session.Error) -> some View {
        VStack(spacing: 4 * .grid) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Bağlanılamadı")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.fg1)
            Text(error.localizedDescription)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 2 * .grid) {
                Spinner()
                Text("Yeniden deneniyor…")
                    .font(.system(size: 13))
                    .foregroundStyle(.fg3)
            }
            .padding(.top, 2 * .grid)
        }
    }
}

#Preview {
    ConnectingView()
        .environmentObject(
            Session(tokenSource: LiteralTokenSource(
                serverURL: URL(string: "wss://example.com")!,
                participantToken: "",
                participantName: "preview",
                roomName: "preview"
            ))
        )
}
