import SwiftUI

/// Liquid Glass #3 (frosted-depth) görünümü.
///
/// NOT: macOS 26 SwiftUI `.glassEffect()` API'si YERİNE **material fallback**
/// kullanıldı — kurulu SDK'da derlemeyi garantiler ve görsel olarak mockup #3'e
/// (yoğun buzlu cam + belirgin highlight + derin gölge) yakındır. Gerçek Liquid
/// Glass API'sine geçmek istersek tek nokta: `Glass3Modifier`.
extension View {
    /// Frosted #3 cam yüzey: material + üstten parlayan highlight border + derin gölge.
    func glass3(cornerRadius: CGFloat = 4 * .grid, strong: Bool = false) -> some View {
        modifier(Glass3Modifier(cornerRadius: cornerRadius, strong: strong))
    }
}

private struct Glass3Modifier: ViewModifier {
    let cornerRadius: CGFloat
    let strong: Bool

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .background(
                shape.fill(.white.opacity(strong ? 0.10 : 0.05))
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(strong ? 0.55 : 0.4), .white.opacity(0.06)],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .clipShape(shape)
            .shadow(color: .black.opacity(0.45), radius: strong ? 22 : 14, y: strong ? 12 : 8)
    }
}

/// Cam'ın okunması için canlı, koyu zemin (mockup #3'teki gradient'e yakın).
struct GlassBackdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.09, blue: 0.14)
            RadialGradient(colors: [Color(red: 0.29, green: 0.42, blue: 1).opacity(0.45), .clear],
                           center: .init(x: 0.8, y: 0.05), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.69, green: 0.29, blue: 1).opacity(0.4), .clear],
                           center: .init(x: 0.15, y: 0.95), startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}
