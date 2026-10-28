import SwiftUI
import AppKit

struct Location: Identifiable, Hashable {
    enum Kind { case disk, home, volume, folder }
    let path: String
    let name: String
    let kind: Kind
    var id: String { path }

    var symbol: String {
        switch kind {
        case .disk: return "internaldrive"
        case .home: return "house"
        case .volume: return "externaldrive"
        case .folder: return "folder"
        }
    }
}

struct VolumeUsage {
    let total: Int64
    let free: Int64
    var used: Int64 { total - free }
}

@MainActor
final class DiskModel: ObservableObject {
    @Published var places: [Location] = []
    @Published var volumes: [Location] = []
    @Published var folders: [Location] = []
    @Published var selectedLocation: Location.ID? {
        didSet { if selectedLocation != oldValue { showSelectedLocation() } }
    }

    @Published var current: Node?
    /// The items selected in the current folder: any number, from the map (⌘- or ⇧-click) or the table.
    @Published var selection: Set<Node.ID> = []
    @Published var revision = 0
    /// Folders visited before and after this one, like a browser's back and forward.
    @Published var backStack: [Node] = []
    @Published var forwardStack: [Node] = []
    /// Whether the last move went into a folder (the map zooms in) or out of one (it zooms out).
    @Published var zoomingIn = true

    @Published var scanning = false
    @Published var scannedFiles = 0
    @Published var scannedBytes: Int64 = 0
    @Published var scanningFolder = ""
    @Published var unreadableCount = 0
    /// The startup disk's space, shown at the foot of the left pane.
    @Published var diskUsage: VolumeUsage?
    /// The space of the disk or volume being shown, whose free space the chart can add; nil for Home and folders.
    @Published var locationUsage: VolumeUsage?
    @Published var errorMessage: String?

    @Published var isPartial = false
    /// Folders the last scan left out because macOS would have asked first (`Scanner.asksFirst`).
    @Published var notAsked: [String] = []
    /// Whether the person asked to measure those folders too. Off to begin with, so opening the app brings no
    /// questions from macOS; Measure Them turns it on, and macOS asks once for each.
    @Published var measuresAsking = LampStore.load(Bool.self, from: "measuresAsking") ?? false
    private var results: [String: (root: Node, unreadable: Int, partial: Bool, notAsked: [String])] = [:]
    private var progress: ScanProgress?
    private var scanID = 0

    init() {
        let dataVolume = "/System/Volumes/Data"
        let diskPath = FileManager.default.fileExists(atPath: dataVolume) ? dataVolume : "/"
        let diskName = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? "Macintosh HD"
        places = [
            Location(path: diskPath, name: diskName, kind: .disk),
            Location(path: NSHomeDirectory(), name: "Home", kind: .home),
        ]
        let saved = LampStore.load([String].self, from: "folders") ?? []
        folders = saved.map { Location(path: $0, name: FileManager.default.displayName(atPath: $0), kind: .folder) }
        refreshVolumes()
        refreshUsage()
        let last = LampStore.load(String.self, from: "lastLocation")
        selectedLocation = allLocations.contains { $0.id == last } ? last : places[1].id
        if current == nil { showSelectedLocation() }
    }

    var allLocations: [Location] { places + volumes + folders }
    var location: Location? { allLocations.first { $0.id == selectedLocation } }
    var root: Node? { current?.ancestors.first }
    /// The selected items, biggest first.
    var selectedNodes: [Node] { current?.sortedChildren.filter { selection.contains($0.id) } ?? [] }
    /// The one selected item, when exactly one is.
    var selectedNode: Node? { selection.count == 1 ? selectedNodes.first : nil }
    var canTrashSelection: Bool { !selectedNodes.isEmpty && selectedNodes.allSatisfy(\.canTrash) }
    var currentFolderIsMeasuring: Bool { scanning && current?.isComplete == false }

    // MARK: Locations

    func refreshVolumes() {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeLocalizedNameKey, .volumeIsReadOnlyKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { url in
            guard url.path != "/", url.path.hasPrefix("/Volumes/") else { return nil }
            // A read-only volume is almost always a mounted disk image (an installer), whose space is the .dmg file's,
            // already counted where that file is, and nothing on it can be moved to the Trash.
            if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true { return nil }
            let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? url.lastPathComponent
            return Location(path: url.path, name: name, kind: .volume)
        }
    }

    func refreshUsage() {
        diskUsage = Self.usage(of: "/")
        locationUsage = location.flatMap { $0.kind == .disk || $0.kind == .volume ? Self.usage(of: $0.path) : nil }
    }

    private static func usage(of path: String) -> VolumeUsage? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity else { return nil }
        return VolumeUsage(total: Int64(total), free: Int64(free))
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder to see what's taking up space in it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFolder(url)
    }

    func addFolder(_ url: URL) {
        let path = url.standardizedFileURL.path
        if !allLocations.contains(where: { $0.path == path }) {
            folders.append(Location(path: path, name: FileManager.default.displayName(atPath: path), kind: .folder))
            LampStore.save(folders.map(\.path), to: "folders")
        }
        selectedLocation = path
    }

    func removeFolder(_ location: Location) {
        folders.removeAll { $0.id == location.id }
        LampStore.save(folders.map(\.path), to: "folders")
        results[location.id] = nil
        if selectedLocation == location.id { selectedLocation = places[1].id }
    }

    private func showSelectedLocation() {
        backStack = []; forwardStack = []
        guard let location else { current = nil; return }
        LampStore.save(location.id, to: "lastLocation")
        if let result = results[location.id] {
            cancelScan()
            current = result.root
            unreadableCount = result.unreadable
            isPartial = result.partial
            notAsked = result.notAsked
            selection = []
            refreshUsage()
        } else {
            scan()
        }
    }

    // MARK: Scanning

    func scan() {
        guard let location else { return }
        progress?.cancel()
        let p = ScanProgress()
        progress = p
        scanID += 1
        let id = scanID
        scanning = true
        isPartial = false
        notAsked = []
        unreadableCount = 0
        selection = []
        scannedFiles = 0
        scannedBytes = 0
        scanningFolder = ""
        refreshUsage()

        let path = location.path
        let root = Node(name: (path as NSString).lastPathComponent, kind: .folder)
        root.rootPath = path
        root.displayName = location.name
        current = root
        backStack = []; forwardStack = []
        results[location.id] = nil
        expectedSize = estimatedSize(of: location)

        // Redraw the map from what's been measured so far.
        Task { [weak self] in
            while let self, self.scanID == id, self.scanning {
                let s = p.snapshot
                self.scannedFiles = s.files
                self.scannedBytes = s.bytes
                self.scanningFolder = s.current
                self.unreadableCount = s.unreadable
                self.revision += 1
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        let isDisk = location.kind == .disk
        let skip = measuresAsking ? [] : Scanner.asksFirst
        Task.detached(priority: .userInitiated) {
            Scanner.scan(into: root, path: path, skip: skip, progress: p)
            let unreadable = p.snapshot.unreadable
            let notAsked = p.notAsked
            let cancelled = p.cancelled
            await MainActor.run { [weak self] in
                guard let self, self.scanID == id else { return }
                if isDisk, !cancelled, let usage = self.diskUsage {
                    let other = usage.used - root.size
                    let name = notAsked.isEmpty ? "System & other volumes" : "System, other volumes & not measured"
                    if other > 0 { root.attach([Node(name: name, kind: .hidden, size: other)]) }
                }
                if !cancelled { self.rememberTotal(root.size, for: location) }
                self.results[location.id] = (root, unreadable, cancelled, notAsked)
                self.unreadableCount = unreadable
                self.notAsked = notAsked
                self.isPartial = cancelled
                self.scanning = false
                self.expectedSize = nil
                let s = p.snapshot
                self.scannedFiles = s.files
                self.scannedBytes = s.bytes
                self.revision += 1
            }
        }
    }

    // MARK: Not measured yet

    /// How big the location is expected to be while it's being measured, if there's a way to tell.
    @Published var expectedSize: Int64?

    /// Space still to be measured in `folder`: only known for the top of a running scan.
    func pendingSize(in folder: Node) -> Int64 {
        guard scanning, folder.parent == nil, let expectedSize else { return 0 }
        return max(0, expectedSize - folder.size)
    }

    private func estimatedSize(of location: Location) -> Int64? {
        switch location.kind {
        case .disk:
            return diskUsage?.used
        case .volume:
            let values = try? URL(fileURLWithPath: location.path).resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
            if let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacity { return Int64(total - free) }
            return totals[location.id]
        case .home, .folder:
            return totals[location.id]
        }
    }

    private lazy var totals: [String: Int64] = LampStore.load([String: Int64].self, from: "totals") ?? [:]

    private func rememberTotal(_ size: Int64, for location: Location) {
        totals[location.id] = size
        LampStore.save(totals, to: "totals")
    }

    /// Measures the folders macOS asks about too, from now on, starting with this location.
    func measureAsking() {
        measuresAsking = true
        LampStore.save(true, to: "measuresAsking")
        results.removeAll()
        scan()
    }

    func cancelScan() {
        progress?.cancel()
        scanID += 1
        scanning = false
    }

    /// Stops measuring and shows what was found so far.
    func stopScan() {
        progress?.cancel()
    }

    // MARK: Navigation

    func open(_ node: Node) {
        guard node.kind == .folder, !node.children.isEmpty else { return }
        visit(node)
        selection = []
    }

    func goUp() {
        guard let current, let parent = current.parent else { return }
        visit(parent)
        selection = [current.id]
    }

    func go(to node: Node) {
        guard node !== current else { return }
        let previous = current
        visit(node)
        selectPath(from: node, toward: previous)
    }

    func goBack() {
        guard let target = backStack.popLast(), let previous = current else { return }
        forwardStack.append(previous)
        show(target, from: previous)
    }

    func goForward() {
        guard let target = forwardStack.popLast(), let previous = current else { return }
        backStack.append(previous)
        show(target, from: previous)
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// A new step in the history: what was ahead is dropped, as in a browser.
    private func visit(_ node: Node) {
        guard let previous = current, node !== previous else { current = node; return }
        backStack.append(previous)
        forwardStack = []
        zoomingIn = node.ancestors.count >= previous.ancestors.count
        current = node
    }

    private func show(_ node: Node, from previous: Node) {
        zoomingIn = node.ancestors.count >= previous.ancestors.count
        current = node
        selectPath(from: node, toward: previous)
    }

    /// Coming back out to a folder selects the item you came out of.
    private func selectPath(from node: Node, toward previous: Node?) {
        selection = Set([previous?.ancestors.first { $0.parent === node }?.id].compactMap { $0 })
    }

    var canGoUp: Bool { current?.parent != nil }

    // MARK: Actions

    func reveal(_ node: Node) { reveal([node]) }

    /// Shows the items in Finder, selected; "small files" and the like open their folder instead.
    func reveal(_ nodes: [Node]) {
        let real = nodes.filter(\.isRealItem).map(\.url)
        if !real.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(real) }
        for node in nodes where !node.isRealItem && node.kind != .hidden { NSWorkspace.shared.open(node.url) }
    }

    /// Opens each item as Finder would: a file in its app, a folder in a Finder window.
    func openItems(_ nodes: [Node]) {
        for node in nodes where node.isRealItem { NSWorkspace.shared.open(node.url) }
    }

    func copyPath(_ nodes: [Node]) {
        let paths = nodes.filter { $0.kind != .hidden }.map(\.path)
        guard !paths.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// Moves the items to the Trash, going on past any that can't be moved and saying which.
    func trash(_ nodes: [Node]) {
        var failed: [String] = []
        for node in nodes where node.canTrash {
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                forgetOverlapping(node.path)
                if let current, node.contains(current) { self.current = node.parent }
                // Back and Forward mustn't lead into what's gone.
                backStack.removeAll { node.contains($0) }
                forwardStack.removeAll { node.contains($0) }
                selection.remove(node.id)
                node.detach()
            } catch {
                failed.append(nodes.count == 1 ? error.localizedDescription : "“\(node.title)”: \(error.localizedDescription)")
            }
        }
        revision += 1
        refreshUsage()
        if !failed.isEmpty { errorMessage = failed.joined(separator: "\n") }
    }

    /// Forgets the other locations' scans that hold `path` or lie inside it (Home holds an added folder, the disk
    /// holds Home), since only the tree on screen knows the item went; they're measured again when chosen.
    private func forgetOverlapping(_ path: String) {
        // A scan of the disk reaches the home folder through the data volume's path.
        func plain(_ p: String) -> String {
            let data = "/System/Volumes/Data"
            return p.hasPrefix(data + "/") ? String(p.dropFirst(data.count)) : p == data ? "/" : p
        }
        func within(_ inner: String, _ outer: String) -> Bool {
            outer == "/" || inner == outer || inner.hasPrefix(outer.hasSuffix("/") ? outer : outer + "/")
        }
        let moved = plain(path)
        for key in results.keys where key != location?.id {
            let root = plain(key)
            if within(moved, root) || within(root, moved) { results[key] = nil }
        }
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}
