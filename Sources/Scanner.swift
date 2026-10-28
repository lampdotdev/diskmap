import Foundation

/// One item in a scanned folder tree. Files under the size threshold are grouped into a single
/// "small files" item per folder so huge trees stay light in memory.
final class Node: Identifiable {
    enum Kind { case folder, file, smallFiles, hidden }

    /// Guards size, file count, children and completeness, which the scanner fills in
    /// from many threads while the window draws what's there so far.
    static let lock = NSLock()

    let name: String
    let kind: Kind
    private var _size: Int64
    private var _fileCount: Int
    private var _children: [Node]
    private var _complete: Bool
    var unreadable = false
    /// Left out of the scan because macOS asks the person first before an app looks inside (`Scanner.asksFirst`).
    var notAsked = false
    weak var parent: Node?
    /// Only set on the root of a scan.
    var rootPath: String?
    var displayName: String?

    init(name: String, kind: Kind, size: Int64 = 0, fileCount: Int = 0, children: [Node] = []) {
        self.name = name
        self.kind = kind
        self._size = size
        self._fileCount = fileCount
        self._children = children
        self._complete = kind != .folder
        for child in children { child.parent = self }
    }

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    var size: Int64 { Node.locked { _size } }
    var fileCount: Int { Node.locked { _fileCount } }
    var children: [Node] { Node.locked { _children } }
    /// False while a folder (or anything inside it) is still being measured.
    var isComplete: Bool { Node.locked { _complete } }

    /// Children biggest first, using sizes read at one moment so a running scan can't upset the order.
    var sortedChildren: [Node] {
        let pairs = Node.locked { _children.map { ($0, $0._size) } }
        return pairs.sorted { $0.1 > $1.1 }.map(\.0)
    }

    /// Adds items to this folder and their sizes to every folder above it.
    func attach(_ items: [Node]) {
        guard !items.isEmpty else { return }
        Node.locked {
            var bytes: Int64 = 0
            var files = 0
            for item in items {
                item.parent = self
                bytes += item._size
                files += item._fileCount
            }
            _children.append(contentsOf: items)
            var up: Node? = self
            while let n = up {
                n._size += bytes
                n._fileCount += files
                up = n.parent
            }
        }
    }

    func markComplete() { Node.locked { _complete = true } }

    var title: String {
        if let displayName { return displayName }
        switch kind {
        case .smallFiles: return fileCount == 1 ? "1 small file" : "\(fileCount.formatted()) small files"
        default: return name
        }
    }

    var path: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        switch kind {
        case .smallFiles, .hidden: return parent.path
        default: return (parent.path as NSString).appendingPathComponent(name)
        }
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// A real file or folder the person can reveal or trash.
    var isRealItem: Bool { kind == .folder || kind == .file }
    var canTrash: Bool { isRealItem && parent != nil }

    var ancestors: [Node] {
        var chain: [Node] = []
        var node: Node? = self
        while let n = node { chain.insert(n, at: 0); node = n.parent }
        return chain
    }

    func contains(_ other: Node) -> Bool {
        var node: Node? = other
        while let n = node { if n === self { return true }; node = n.parent }
        return false
    }

    /// Removes this item from the tree, taking its size off every folder above it.
    func detach() {
        guard let parent else { return }
        Node.locked {
            parent._children.removeAll { $0 === self }
            var up: Node? = parent
            while let n = up {
                n._size -= _size
                n._fileCount -= _fileCount
                up = n.parent
            }
        }
        self.parent = nil
    }
}

/// Shared counters a scan updates and the UI polls.
final class ScanProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _files = 0
    private var _bytes: Int64 = 0
    private var _unreadable = 0
    private var _current = ""
    private var _cancelled = false
    private var _notAsked: [String] = []

    func add(files: Int, bytes: Int64, folder: String) {
        lock.lock(); _files += files; _bytes += bytes; _current = folder; lock.unlock()
    }
    func addUnreadable() { lock.lock(); _unreadable += 1; lock.unlock() }
    func addNotAsked(_ name: String) { lock.lock(); _notAsked.append(name); lock.unlock() }
    var notAsked: [String] { lock.lock(); defer { lock.unlock() }; return _notAsked }
    func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    var snapshot: (files: Int, bytes: Int64, unreadable: Int, current: String) {
        lock.lock(); defer { lock.unlock() }
        return (_files, _bytes, _unreadable, _current)
    }
}

enum Scanner {
    /// Files smaller than this are grouped per folder.
    static let smallFileLimit: Int64 = 1_000_000

    /// Folders macOS guards with a question to the person ("Disk Map would like to access files in your Documents
    /// folder"): the three in the home folder, iCloud Drive and other cloud drives, other apps' data, and the Music,
    /// TV and Photos libraries. Reading them all at once would bring a question for each, so they're left out until
    /// the person asks for them (Measure Them). Each is listed as the home folder's own path and as the data volume's,
    /// which is how a scan of the disk reaches it.
    static var asksFirst: Set<String> {
        let home = NSHomeDirectory()
        let inHome = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage",
                      "Library/Containers", "Library/Group Containers", "Music/Music", "Music/iTunes", "Movies/TV",
                      "Pictures/Photo Booth Library"].map { (home as NSString).appendingPathComponent($0) }
        return Set(inHome + inHome.map { "/System/Volumes/Data" + $0 })
    }

    /// A Photos library may be anywhere and called anything; macOS asks before an app reads one all the same.
    static func asksFirst(_ path: String) -> Bool { path.hasSuffix(".photoslibrary") }

    /// Fills in `root` (a folder node for `path`) as it goes, so it can be drawn while measuring. Folders in `skip`
    /// below the root are listed but not looked in (the root itself is measured: the person chose it).
    static func scan(into root: Node, path: String, skip: Set<String> = [], progress: ScanProgress) {
        var st = stat()
        let device = lstat(path, &st) == 0 ? st.st_dev : 0
        scanFolder(root, path: path, device: device, depth: 0, skip: skip, progress: progress)
    }

    // The attributes asked of getattrlistbulk (the SDK spells some as Int32, some as UInt32).
    private static let returnedAttrs = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
    private static let nameAttr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_NAME)
    private static let deviceAttr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_DEVID)
    private static let typeAttr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_OBJTYPE)
    private static let errorAttr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_ERROR)
    private static let allocSizeAttr = attrgroup_t(truncatingIfNeeded: ATTR_FILE_ALLOCSIZE)

    /// Lists a folder with readdir and a stat for each entry, for a file system getattrlistbulk doesn't work on.
    /// False when the folder couldn't be read to its end.
    private static func readSlowly(_ path: String, add: (Bool, Bool, dev_t, Int64, () -> String) -> Void) -> Bool {
        guard let dir = opendir(path) else { return false }
        defer { closedir(dir) }
        let fd = dirfd(dir)
        while true {
            // readdir says nil both at the end and on an error; only errno tells them apart.
            errno = 0
            guard let entry = readdir(dir) else { return errno == 0 }
            var st = stat()
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { raw in
                raw.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cname -> String? in
                    if cname[0] == 46 && (cname[1] == 0 || (cname[1] == 46 && cname[2] == 0)) { return nil } // . and ..
                    guard fstatat(fd, cname, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
                    return String(cString: cname)
                }
            }
            guard let name else { continue }
            let type = st.st_mode & S_IFMT
            add(type == S_IFDIR, type == S_IFREG, st.st_dev, Int64(st.st_blocks) * 512, { name })
        }
    }

    private static func scanFolder(_ folder: Node, path: String, device: dev_t, depth: Int, skip: Set<String>, progress: ScanProgress) {
        defer { folder.markComplete() }
        guard !progress.cancelled else { return }
        if depth > 0, !skip.isEmpty, skip.contains(path) || asksFirst(path) {
            folder.notAsked = true
            progress.addNotAsked(folder.name)
            return
        }

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            folder.unreadable = true
            progress.addUnreadable()
            return
        }

        var children: [Node] = []
        var subfolders: [(path: String, node: Node)] = []
        var smallSize: Int64 = 0
        var smallCount = 0
        var lastSmall: (String, Int64)?
        var fileBytes: Int64 = 0
        var fileCount = 0
        let prefix = path.hasSuffix("/") ? path : path + "/"

        // One entry of the folder, however it was read. The name is made only where it's shown.
        func add(isFolder: Bool, isFile: Bool, device entryDevice: dev_t, size: Int64, name: () -> String) {
            if isFolder {
                if entryDevice != device { return } // another volume
                let entryName = name()
                let sub = Node(name: entryName, kind: .folder)
                subfolders.append((prefix + entryName, sub))
                children.append(sub)
            } else if isFile {
                fileBytes += size
                fileCount += 1
                if size >= smallFileLimit {
                    children.append(Node(name: name(), kind: .file, size: size, fileCount: 1))
                } else {
                    smallSize += size
                    smallCount += 1
                    // Only a folder's one small file is shown by name; the rest are counted.
                    if smallCount == 1 { lastSmall = (name(), size) }
                }
            }
        }

        // getattrlistbulk hands back the name, type, device and allocated size of many entries in one call, where
        // readdir and a stat for each entry take one call per file. Each entry in the buffer is its length, the
        // attributes it holds, then those attributes in a fixed order, each a multiple of 4 bytes.
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = returnedAttrs | nameAttr | deviceAttr | typeAttr | errorAttr
        request.fileattr = allocSizeAttr
        let bufferSize = 128 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 8)
        defer { buffer.deallocate() }

        var failed = false
        var failure: Int32 = 0
        var read = 0
        while true {
            let count = getattrlistbulk(fd, &request, buffer, bufferSize, 0)
            if count < 0 { failed = true; failure = errno; break }
            if count == 0 { break }
            read += Int(count)
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                if returned.commonattr & errorAttr != 0 {
                    let entryError = field.loadUnaligned(as: UInt32.self)
                    field += 4
                    if entryError != 0 { continue }
                }
                guard returned.commonattr & nameAttr != 0 else { continue }
                let nameField = field
                let nameOffset = Int(field.loadUnaligned(as: Int32.self))
                field += MemoryLayout<attrreference_t>.size
                let entryDevice = field.loadUnaligned(as: dev_t.self)
                field += 4
                let type = field.loadUnaligned(as: fsobj_type_t.self)
                field += 4
                let name = { String(cString: (nameField + nameOffset).assumingMemoryBound(to: CChar.self)) }

                let size = type == VREG.rawValue && returned.fileattr & allocSizeAttr != 0 ? field.loadUnaligned(as: off_t.self) : 0
                add(isFolder: type == VDIR.rawValue, isFile: type == VREG.rawValue, device: entryDevice, size: size, name: name)
            }
        }
        // A file system that can't list this way (some network and third-party ones) is read the slow way; anything
        // else that went wrong leaves the folder counted as unreadable, with what was read so far.
        if failed, !((failure == ENOTSUP || failure == EINVAL) && read == 0 && readSlowly(path, add: add)) {
            folder.unreadable = true
            progress.addUnreadable()
        }
        close(fd)

        if smallCount == 1, let (n, s) = lastSmall {
            children.append(Node(name: n, kind: .file, size: s, fileCount: 1))
        } else if smallCount > 1 {
            children.append(Node(name: "", kind: .smallFiles, size: smallSize, fileCount: smallCount))
        }
        folder.attach(children)
        progress.add(files: fileCount, bytes: fileBytes, folder: path)

        // Scan the upper levels in parallel; deeper levels run on whichever thread got there.
        if depth < 10 && subfolders.count > 1 {
            DispatchQueue.concurrentPerform(iterations: subfolders.count) { i in
                scanFolder(subfolders[i].node, path: subfolders[i].path, device: device, depth: depth + 1, skip: skip, progress: progress)
            }
        } else {
            for sub in subfolders {
                scanFolder(sub.node, path: sub.path, device: device, depth: depth + 1, skip: skip, progress: progress)
            }
        }
    }
}
