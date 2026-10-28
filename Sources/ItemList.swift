import SwiftUI

/// One row of the contents list, captured with its numbers at a moment so the list updates while measuring.
struct ItemRow: Identifiable, Equatable {
    let node: Node
    let size: Int64
    let fileCount: Int
    let measuring: Bool
    var id: Node.ID { node.id }

    static func == (a: ItemRow, b: ItemRow) -> Bool {
        a.node === b.node && a.size == b.size && a.fileCount == b.fileCount && a.measuring == b.measuring
    }
}

/// The shown folder's items, biggest first, compact enough for the sidebar: a faint bar behind each row shows its
/// share of the folder.
struct ItemList: View {
    @EnvironmentObject var model: DiskModel
    let folder: Node
    /// Shared with the chart: the row under the pointer lights its slice, and the slice under the pointer its row.
    @Binding var hovered: (outer: Node, inner: Node?)?

    var body: some View {
        let _ = model.revision
        let rows = folder.sortedChildren.map {
            ItemRow(node: $0, size: $0.size, fileCount: $0.fileCount, measuring: $0.kind == .folder && !$0.isComplete)
        }
        let total = folder.size
        List(selection: $model.selection) {
            ForEach(rows) { row in
                ItemListRow(row: row, fraction: total > 0 ? Double(row.size) / Double(total) : 0,
                            lit: hovered?.outer === row.node, scanning: model.scanning)
                    .onHover { inside in
                        if inside, hovered?.outer !== row.node { hovered = (row.node, nil) }
                    }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .onHover { inside in if !inside { hovered = nil } }
        .contextMenu(forSelectionType: Node.ID.self) { ids in
            let nodes = rows.filter { ids.contains($0.id) }.map(\.node)
            if !nodes.isEmpty { ItemMenu(nodes: nodes) }
        } primaryAction: { ids in
            let nodes = rows.filter { ids.contains($0.id) }.map(\.node)
            if nodes.count == 1, let node = nodes.first {
                if node.kind == .folder && !node.children.isEmpty { model.open(node) } else { model.reveal(node) }
            } else {
                model.openItems(nodes)
            }
        }
    }
}

struct ItemListRow: View {
    let row: ItemRow
    let fraction: Double
    let lit: Bool
    let scanning: Bool

    var body: some View {
        HStack(spacing: 6) {
            ItemIcon(node: row.node)
            Text(row.node.title)
                .lineLimit(1)
                .truncationMode(.middle)
            if row.node.notAsked {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.secondary)
                    .help("Not measured: macOS asks before Disk Map looks in here. Measure Them below the chart asks.")
            }
            if row.node.unreadable {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.secondary)
                    .help("Disk Map isn't allowed to look inside this folder.")
            }
            if row.measuring && scanning {
                ProgressView().controlSize(.mini)
                    .help("Still measuring")
            }
            Spacer(minLength: 4)
            Text(row.node.notAsked ? "—" : formatBytes(row.size))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(row.node.kind == .hidden ? "" : "\(row.fileCount.formatted()) files · \(fraction.formatted(.percent.precision(.fractionLength(1))))")
        }
        .padding(.vertical, 1)
        .background {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.primary.opacity(lit ? 0.06 : 0))
                .padding(.horizontal, -6)
                .padding(.vertical, -3)
        }
        .overlay(alignment: .bottomLeading) {
            // The item's share of the folder, as a thin line under its name.
            GeometryReader { geo in
                Capsule()
                    .fill(Color.accentColor.opacity(lit ? 0.9 : 0.5))
                    .frame(width: max(2, geo.size.width * fraction), height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .padding(.leading, 22)
            .offset(y: 3)
        }
        .contentShape(Rectangle())
    }
}
