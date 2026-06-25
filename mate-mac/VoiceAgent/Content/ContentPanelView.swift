import SwiftUI

/// Sağda açılan içerik paneli (frosted #3 cam). ŞİMDİLİK İSKELE: gelen öğeyi
/// tür rozeti + başlık + url + "render yakında" notuyla placeholder gösterir.
/// Gerçek render'lar (YouTube/PDF/Image/web) sonraki turda `card(_:)` içindeki
/// switch'e eklenecek — yapı buna hazır.
struct ContentPanelView: View {
    let items: [ContentItem]
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3 * .grid) {
            HStack {
                Text("İçerik").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if items.isEmpty {
                Spacer()
                Text("Henüz içerik yok")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3 * .grid) {
                        ForEach(items.reversed()) { card($0) }
                    }
                }
            }
        }
        .padding(4 * .grid)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func card(_ item: ContentItem) -> some View {
        VStack(alignment: .leading, spacing: .grid) {
            HStack { badge(item.kind); Spacer() }
            Text(item.title)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
            if !item.url.isEmpty {
                Text(item.url)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // Gerçek render burada tipe göre genişletilecek (şimdilik placeholder).
            switch item.kind {
            case .youtube, .image, .pdf, .web, .unknown:
                Text("render yakında")
                    .font(.caption2).italic()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(3 * .grid)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass3(cornerRadius: 3 * .grid)
    }

    private func badge(_ kind: ContentItem.Kind) -> some View {
        Text(kind.rawValue.uppercased())
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 1.5 * .grid)
            .padding(.vertical, 0.5 * .grid)
            .background(Capsule().fill(.white.opacity(0.16)))
    }
}
