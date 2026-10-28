import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: DiskModel
    @State private var pendingTrash: [Node] = []
    @State private var hovered: (outer: Node, inner: Node?)?

    var body: some View {
        // A fixed side pane, part of the window, that can't be hidden: the places to measure and what's in the
        // folder being shown.
        HSplitView {
            SidebarView(hovered: $hovered)
                .frame(minWidth: 244, idealWidth: 264, maxWidth: 340)
            detail
                .frame(minWidth: 460, maxWidth: .infinity)
        }
        .frame(minWidth: 820, minHeight: 520)
        .toolbar { toolbar }
        .navigationTitle("Disk Map")
        .hidingToolbarEdge()
        .onReceive(NotificationCenter.default.publisher(for: .requestTrash)) { note in
            pendingTrash = note.object as? [Node] ?? []
        }
        .confirmationDialog(trashTitle, isPresented: Binding(get: { !pendingTrash.isEmpty }, set: { if !$0 { pendingTrash = [] } }),
                            titleVisibility: .visible, presenting: pendingTrash) { nodes in
            Button("Move to Trash", role: .destructive) { model.trash(nodes) }
        } message: { nodes in
            Text("\(nodes.count == 1 ? "It takes" : "They take") up \(formatBytes(nodes.reduce(0) { $0 + $1.size })). You can put \(nodes.count == 1 ? "it" : "them") back from the Trash until you empty it.")
        }
        .alert("Couldn't move to the Trash", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var trashTitle: String {
        pendingTrash.count == 1 ? "Move “\(pendingTrash[0].title)” to the Trash?" : "Move \(pendingTrash.count) items to the Trash?"
    }

    @ViewBuilder private var detail: some View {
        if let current = model.current {
            BrowserView(folder: current, hovered: $hovered)
        } else {
            ContentUnavailableView {
                Label("Choose a Location", systemImage: "internaldrive")
            } description: {
                Text("Pick your disk, your home folder, or any folder to see what's using space.")
            } actions: {
                Button("Add Folder…") { model.addFolder() }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                .help("Back to the folder you were in (⌘[)")
                .disabled(!model.canGoBack)
            Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                .help("Forward again (⌘])")
                .disabled(!model.canGoForward)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.scan() } label: { Label("Rescan", systemImage: "arrow.clockwise") }
                .help("Measure this location again (⌘R)")
                .disabled(model.location == nil || model.scanning)
            Button {
                if model.selectedNodes.isEmpty { if let current = model.current { model.reveal(current) } } else { model.reveal(model.selectedNodes) }
            } label: { Label("Show in Finder", systemImage: "finder") }
                .help("Show the selected item in Finder")
                .disabled(model.current == nil)
            Button {
                requestTrash(model.selectedNodes)
            } label: { Label("Move to Trash", systemImage: "trash") }
                .help("Move the selected item to the Trash (⌘⌫)")
                .disabled(!model.canTrashSelection)
        }
    }
}

extension Notification.Name {
    static let requestTrash = Notification.Name("DiskMapRequestTrash")
}

func requestTrash(_ nodes: [Node]) {
    let nodes = nodes.filter(\.canTrash)
    guard !nodes.isEmpty else { return }
    NotificationCenter.default.post(name: .requestTrash, object: nodes)
}

struct SidebarView: View {
    @EnvironmentObject var model: DiskModel
    @Binding var hovered: (outer: Node, inner: Node?)?

    /// How tall the locations are, and the pane they're in: past a share of the pane they scroll, so the
    /// folder's contents below always keep their room however many folders and volumes there are.
    @State private var locationsHeight: CGFloat = 0
    @State private var paneHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    header("Locations")
                    ForEach(model.places) { LocationRow(location: $0) }
                    if !model.volumes.isEmpty {
                        header("Volumes")
                        ForEach(model.volumes) { LocationRow(location: $0) }
                    }
                    header("Folders")
                    ForEach(model.folders) { loc in
                        LocationRow(location: loc).contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: loc.path)]) }
                            Divider()
                            Button("Remove from Sidebar") { model.removeFolder(loc) }
                        }
                    }
                    Button { model.addFolder() } label: {
                        Label("Add Folder…", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { locationsHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(locationsHeight, max(160, paneHeight * 0.45)))
            .lampDropFiles { urls in
                for url in urls where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    model.addFolder(url)
                }
            }

            Divider().padding(.horizontal, 12)
            if let current = model.current {
                header("In \(current.title)")
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                if model.unreadableCount > 0 {
                    UnreadableNotice(count: model.unreadableCount) { model.openFullDiskAccessSettings() }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                }
                ItemList(folder: current, hovered: $hovered)
            } else {
                Spacer()
            }

            if let usage = model.diskUsage {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(usage.used), total: Double(max(usage.total, 1)))
                        .tint(Double(usage.free) / Double(max(usage.total, 1)) < 0.1 ? .red : .accentColor)
                    Text("\(formatBytes(usage.free)) free of \(formatBytes(usage.total))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
        .background(.background.secondary)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
        .onAppear { model.refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in model.refreshVolumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in model.refreshVolumes() }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }
}

/// A place to measure, as a sidebar row.
struct LocationRow: View {
    @EnvironmentObject var model: DiskModel
    let location: Location
    @State private var hovering = false

    var body: some View {
        let selected = model.selectedLocation == location.id
        Button { model.selectedLocation = location.id } label: {
            Label(location.name, systemImage: location.symbol)
                .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.primary.opacity(0.1) : hovering ? Color.primary.opacity(0.05) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hovering = $0 }
    }
}

extension View {
    /// No line under the toolbar: the path bar below it carries on from the title.
    @ViewBuilder func hidingToolbarEdge() -> some View {
        if #available(macOS 15, *) { toolbarBackgroundVisibility(.hidden, for: .windowToolbar) } else { self }
    }
}

/// Folders macOS keeps from apps without Full Disk Access, as a small notice that opens the switch for it.
struct UnreadableNotice: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "eye.slash")
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count.formatted()) \(count == 1 ? "folder" : "folders") couldn't be read")
                        .fontWeight(.medium)
                    Text("Allow Full Disk Access, then rescan")
                        .font(.caption)
                        .opacity(0.8)
                }
                Spacer(minLength: 0)
            }
            .font(.callout)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("macOS keeps some folders, like Mail's and Messages', from apps until you give them Full Disk Access in System Settings.")
    }
}
