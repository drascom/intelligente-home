import LiveKitComponents
import SwiftUI

/// Bağlantı durumu ekranı (eski StartView'in yerine).
///
/// Manuel "Bağlan" butonu YOKTUR: uygulama açılışta otomatik bağlanır; bağlantı
/// koptuğunda (manuel/ağ) bu ekran tekrar görünür ve yeniden bağlanır. Bağlanma
/// başarılı olunca AppView `interactions()`'a geçer ve (wakeWordEnabled ise)
/// WakeCoordinator uyku moduna girip "candan" bekler.
///
/// Otomatik bağlanma HATA YOKKEN yapılır; hata varsa döngüye girmemek için
/// otomatik denemez — kullanıcı "Yeniden dene" ile tekrar başlatır.
struct ConnectingView: View {
    @EnvironmentObject private var session: Session

    /// Kullanıcı bilerek kapattıysa otomatik bağlanma; manuel "Bağlan" göster.
    @Binding var userDisconnected: Bool

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: 6 * .grid) {
            if let error = session.error {
                errorState(error)
            } else if userDisconnected {
                disconnectedState()
            } else {
                connectingState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, horizontalSizeClass == .regular ? 32 * .grid : 16 * .grid)
        // Açılışta otomatik bağlan. Hata varsa (döngü olmasın) ya da kullanıcı
        // bilerek kapattıysa otomatik denemez; ikisinde de manuel buton gösterilir.
        // session.start() yalnızca bağlantı kopuksa iş yapar (aksi halde no-op).
        .task {
            guard session.error == nil, !userDisconnected else { return }
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

    private func disconnectedState() -> some View {
        VStack(spacing: 4 * .grid) {
            Image(systemName: "phone.down.circle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.fg3)
            Text("Bağlantı kapatıldı")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.fg1)
            AsyncButton {
                userDisconnected = false
                await session.start()
            } label: {
                HStack {
                    Spacer()
                    Text("Bağlan")
                    Spacer()
                }
                .frame(width: 48 * .grid, height: 11 * .grid)
            }
            #if os(visionOS)
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            #else
            .buttonStyle(ProminentButtonStyle())
            #endif
            .padding(.top, 2 * .grid)
        }
    }

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
            AsyncButton {
                // Hatayı temizle ve yeniden bağlanmayı dene.
                session.dismissError()
                await session.start()
            } label: {
                HStack {
                    Spacer()
                    Text("Yeniden dene")
                    Spacer()
                }
                .frame(width: 48 * .grid, height: 11 * .grid)
            }
            #if os(visionOS)
            .buttonStyle(.borderedProminent)
            .controlSize(.extraLarge)
            #else
            .buttonStyle(ProminentButtonStyle())
            #endif
            .padding(.top, 2 * .grid)
        }
    }
}

#Preview {
    ConnectingView(userDisconnected: .constant(false))
        .environmentObject(
            Session(tokenSource: LiteralTokenSource(
                serverURL: URL(string: "wss://example.com")!,
                participantToken: "",
                participantName: "preview",
                roomName: "preview"
            ))
        )
}
