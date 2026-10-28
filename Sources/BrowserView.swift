import SwiftUI

struct BrowserView: View {
    @EnvironmentObject var model: DiskModel
    let folder: Node
    /// Shared with the contents list in the sidebar: what's under the pointer in one lights up in the other.
    @Binding var hovered: (outer: Node, inner: Node?)?
    /// Whether the disk's free space is a slice of the sunburst too.
    @AppStorage("showsFreeSpace") private var showsFree = false

    var body: some View {
            VStack(spacing: 0) {
                HStack {
                    PathBar(folder: folder)
                    if canShowFree {
                        Toggle("Free space", isOn: $showsFree)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .fixedSize()
                            .help("Show the disk's free space beside what's on it")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                chartView
                    .id(folder.id)
                    .transition(.asymmetric(insertion: .scale(scale: model.zoomingIn ? 0.92 : 1.08).combined(with: .opacity),
                                            removal: .opacity))
                    .padding(20)
                    .contextMenu {
                        // The selection when the pointer is on part of it, else just what's under the pointer.
                        if let h = hovered {
                            let node = h.inner ?? h.outer
                            ItemMenu(nodes: node === h.outer && model.selection.contains(node.id) ? model.selectedNodes : [node])
                        }
                    }
                statusLine
            }
            .animation(.spring(duration: 0.35, bounce: 0.15), value: folder.id)
            .animation(.easeInOut(duration: 0.5), value: showsFree)
            .clipped()
    }

    /// Free space belongs to a whole disk, so it's drawn only at the top of a disk or volume.
    private var canShowFree: Bool {
        folder.parent == nil && (model.location?.kind == .disk || model.location?.kind == .volume)
    }

    private var chartView: some View {
        SunburstView(folder: folder, revision: model.revision, pending: model.pendingSize(in: folder),
                     free: model.locationUsage?.free ?? 0, freeAmount: showsFree && canShowFree ? 1 : 0,
                     selection: $model.selection, hovered: $hovered) { node in
            if node.kind == .folder && !node.children.isEmpty { model.open(node) } else { model.reveal(node) }
        } onUp: {
            model.goUp()
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if let h = hovered {
                Text(h.inner.map { "\(h.outer.title) › \($0.title)" } ?? h.outer.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(formatBytes((h.inner ?? h.outer).size))
                    .foregroundStyle(.secondary)
                Text(share((h.inner ?? h.outer).size))
                    .foregroundStyle(.tertiary)
            } else if model.scanning {
                ProgressView().controlSize(.small)
                Text("Measuring… \(model.scannedFiles.formatted()) files · \(formatBytes(model.scannedBytes))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if folder.parent != nil {
                    Text("·").foregroundStyle(.tertiary)
                    Text(folder.isComplete ? "This folder is done" : "This folder is still growing")
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("\(formatBytes(folder.size)) in \(folder.fileCount.formatted()) files")
                    .foregroundStyle(.secondary)
                if model.isPartial {
                    Text("·").foregroundStyle(.tertiary)
                    Text("Stopped early").foregroundStyle(.orange)
                        .help("Measuring was stopped, so some folders are smaller than they really are. Rescan to finish.")
                }
                if !model.notAsked.isEmpty && folder.parent == nil {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(notAskedList) not measured")
                        .foregroundStyle(.secondary)
                        .help("macOS asks before an app looks in these folders, so Disk Map waits until you ask for them.")
                    Button("Measure Them") { model.measureAsking() }
                        .buttonStyle(.link)
                        .help("Measure these folders too. macOS asks once for each.")
                }
            }
            Spacer()
            if model.scanning {
                Button("Stop") { model.stopScan() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                    .help("Stop measuring and keep what's been found so far")
            }
        }
        .font(.callout)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// "Desktop, Documents and 2 more", in the words people know these folders by.
    private var notAskedList: String {
        let order = ["Desktop", "Documents", "Downloads", "iCloud Drive", "cloud drives", "Photos", "Music", "TV",
                     "other apps' data"]
        let words = ["Mobile Documents": "iCloud Drive", "CloudStorage": "cloud drives",
                     "Containers": "other apps' data", "Group Containers": "other apps' data",
                     "iTunes": "Music", "Photo Booth Library": "Photo Booth"]
        let names = Set(model.notAsked.map { $0.hasSuffix(".photoslibrary") ? "Photos" : words[$0] ?? $0 })
            .sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
        if names.count <= 2 { return names.formatted(.list(type: .and)) }
        return "\(names[0]), \(names[1]) and \(names.count - 2) more"
    }

    private func share(_ size: Int64) -> String {
        guard folder.size > 0 else { return "" }
        return (Double(size) / Double(folder.size)).formatted(.percent.precision(.fractionLength(1)))
    }
}

/// The folder's place on the disk, under the title: each folder above it is a step back. When the trail doesn't
/// fit, folders from the middle fold into a … menu, so the start and the folder you're in stay readable.
struct PathBar: View {
    @EnvironmentObject var model: DiskModel
    let folder: Node

    var body: some View {
        let chain = folder.ancestors
        ViewThatFits(in: .horizontal) {
            // Fold away one more folder from the middle at a time, until it fits.
            ForEach(0..<max(1, chain.count - 1), id: \.self) { folded in
                trail(chain, folded: folded)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trail(_ chain: [Node], folded: Int) -> some View {
        let hidden = folded == 0 ? [] : Array(chain[1...min(folded, chain.count - 2)])
        let shown = folded == 0 ? chain : [chain[0]] + chain.dropFirst(1 + hidden.count)
        return HStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, node in
                if i > 0 { separator }
                crumb(node)
                if i == 0 && !hidden.isEmpty {
                    separator
                    foldedMenu(hidden)
                }
            }
        }
        .fixedSize(horizontal: folded < chain.count - 2, vertical: false)
    }

    private func foldedMenu(_ nodes: [Node]) -> some View {
        Menu {
            ForEach(Array(nodes.reversed().enumerated()), id: \.offset) { _, node in
                Button { model.go(to: node) } label: {
                    Label { Text(node.title) } icon: { Image(nsImage: NSWorkspace.shared.icon(forFile: node.path)) }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(nodes.map(\.title).joined(separator: " › "))
    }

    private var separator: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 2)
    }

    private func crumb(_ node: Node) -> some View {
        Crumb(node: node, isCurrent: node === folder) { model.go(to: node) }
            .contextMenu {
                Button("Show in Finder") { model.reveal(node) }
                Button("Copy Path") { model.copyPath([node]) }
            }
    }
}

private struct Crumb: View {
    let node: Node
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button { if !isCurrent { action() } } label: {
            HStack(spacing: 5) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(node.title)
                    .font(.body.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.primary.opacity(hovering && !isCurrent ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .layoutPriority(isCurrent ? 1 : 0)
        .onHover { hovering = $0 }
        .help(isCurrent ? node.path : "Go to \(node.title)")
    }
}

struct ItemMenu: View {
    @EnvironmentObject var model: DiskModel
    let nodes: [Node]

    var body: some View {
        let real = nodes.filter(\.isRealItem)
        if nodes.count == 1, let node = nodes.first {
            if node.kind == .folder && !node.children.isEmpty {
                Button("Open") { model.open(node) }
            }
            if node.kind == .file {
                Button("Open") { model.openItems([node]) }
            }
            Button(node.isRealItem ? "Show in Finder" : "Open Folder in Finder") { model.reveal(node) }
                .disabled(node.kind == .hidden)
            Button("Copy Path") { model.copyPath([node]) }
                .disabled(node.kind == .hidden)
        } else {
            Button("Open \(real.count) Items") { model.openItems(real) }
                .disabled(real.isEmpty)
            Button("Show \(real.count) Items in Finder") { model.reveal(real) }
                .disabled(real.isEmpty)
            Button("Copy Paths") { model.copyPath(real) }
                .disabled(real.isEmpty)
        }
        let trashable = nodes.filter(\.canTrash)
        if !trashable.isEmpty {
            Divider()
            Button(trashable.count == 1 ? "Move to Trash…" : "Move \(trashable.count) Items to Trash…") { requestTrash(trashable) }
        }
    }
}

struct ItemIcon: View {
    let node: Node

    var body: some View {
        switch node.kind {
        case .folder, .file:
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.path))
                .resizable()
                .frame(width: 16, height: 16)
        case .smallFiles:
            Image(systemName: "doc.on.doc").foregroundStyle(.secondary).frame(width: 16)
        case .hidden:
            Image(systemName: "gearshape.2").foregroundStyle(.secondary).frame(width: 16)
        }
    }
}

struct ShareBar: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

/// 7,680 stays as it is; 119,872 becomes 120K.
func shortCount(_ n: Int) -> String {
    n < 10_000 ? n.formatted() : n.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
}
