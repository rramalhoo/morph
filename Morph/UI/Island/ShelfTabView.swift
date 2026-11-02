import AppKit
import QuickLook
import SwiftUI

struct ShelfTabView: View {
    @Environment(FileShelfStore.self) private var shelf
    @Environment(IslandController.self) private var island
    @State private var previewURL: URL?

    var body: some View {
        MorphCard {
            if shelf.items.isEmpty {
                VStack(spacing: MorphSpacing.s) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(MorphColor.textSecondary)
                    Text("Drop files here to keep them close")
                        .font(MorphFont.secondary)
                        .foregroundStyle(MorphColor.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: MorphSpacing.xs) {
                    HStack {
                        Text(shelf.items.count == 1 ? "1 FILE" : "\(shelf.items.count) FILES")
                            .font(MorphFont.label)
                            .foregroundStyle(MorphColor.textSecondary)
                        Spacer()
                        MorphIconButton(symbol: "trash", label: "Clear Shelf", size: 11, action: shelf.removeAll)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: MorphSpacing.s) {
                            ForEach(shelf.items) { item in
                                ShelfTile(item: item, onPreview: { previewURL = item.url })
                            }
                        }
                    }
                }
            }
        }
        .quickLookPreview($previewURL, in: shelf.items.map(\.url))
        // Moving to the preview window leaves the island, which must not collapse underneath it.
        .onChange(of: previewURL == nil) { _, isClosed in
            island.send(isClosed ? .interactionEnded : .interactionBegan)
        }
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let onPreview: () -> Void

    @Environment(FileShelfStore.self) private var shelf

    var body: some View {
        VStack(spacing: MorphSpacing.xs) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 44, height: 44)
            Text(item.name)
                .font(MorphFont.label)
                .foregroundStyle(MorphColor.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 76, height: 26, alignment: .top)
        }
        .padding(.vertical, MorphSpacing.xs)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { shelf.open(item) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help([item.name, shelf.details(for: item)].joined(separator: "\n"))
        .contextMenu {
            Button("Quick Look", action: onPreview)
            Button("Open") { shelf.open(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            Divider()
            Button("Remove from Shelf") { shelf.remove(item) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(shelf.details(for: item))
        .accessibilityAction(named: "Quick Look", onPreview)
        .accessibilityAction(named: "Open") { shelf.open(item) }
        .accessibilityAction(named: "Show in Finder") { shelf.reveal(item) }
        .accessibilityAction(named: "Remove from Shelf") { shelf.remove(item) }
    }
}
