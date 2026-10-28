Kind: tool.
Look: system colors, a sunburst drawn in Canvas, each first-ring slice hued by its place round the circle (blue to pink, `SunburstLayout.color`), lighter in outer rings, white gaps between slices; the free-space slice eases in and out (`freeAmount`, Animatable); it zooms in when going into a folder and out when coming back (`DiskModel.zoomingIn`).

# Disk Map

Shows where disk space goes. The window is two panes side by side (an `HSplitView`, no collapsible sidebar): the left pane has the places to measure (the disk, Home, mounted volumes other than read-only ones such as
disk images, and folders
added with Add Folder… or by dropping them on it), then the shown folder's contents (`ItemList`: icon, name, size, a thin share line under each; selecting several the usual way), and the disk's free space at its foot. Choosing a location measures everything in it and the right pane shows:

- a path bar under the title (which stays "Disk Map"): Finder-style icons, each folder above clickable, folders
  from the middle folded into a … menu when it doesn't fit (`ViewThatFits`), right-click to show in Finder or copy
  the path; back (‹) and forward (›) in the toolbar step through the folders visited, like a browser (`backStack`, `forwardStack`, cleared when the location changes or is rescanned),
- a sunburst: three rings around the folder's name and size (the hovered slice's while hovering; a click in
  the middle goes up), each first-ring slice hued by where it sits, blue round to pink, lighter outward;
  a single click opens a folder's slice (⌘/⇧-click select). The Free space switch beside the path (shown, and drawn, only at the top of a disk or volume: `canShowFree`) (`@AppStorage("showsFreeSpace")`,
  off at first) adds the disk's free space as a pale green slice through every ring, so shares are of the disk.
- Folders macOS asks the person about before an app looks inside (Desktop, Documents, Downloads, iCloud Drive and
  other cloud drives, other apps' data in Library/Containers and Group Containers, the Music, TV, Photo Booth and
  Photos libraries: `Scanner.asksFirst`) are left
  out at first, so opening the app brings no questions. They're listed in the left pane with a hand and "—", and the
  status line says which weren't measured, with Measure Them, which turns on `measuresAsking` (saved) and measures
  again; macOS then asks once for each. A folder the person adds is measured whatever it is (they chose it); only
  what's inside it is skipped until then.
- What macOS keeps from apps without Full Disk Access (Mail, Messages, Safari's data…) can't be opened at all:
  those folders get a lock in the list, and a blue notice under the folder's name in the left pane
  (`UnreadableNotice`) counts them and opens Full Disk Access in System Settings.

## Code

- `Sources/App.swift`: the window and the menu commands (`DiskCommands`: Add Folder… ⌘O, Show in Finder ⇧⌘R, Move
  to Trash… ⌘⌫; the Go menu: Back ⌘[, Forward ⌘], Enclosing Folder ⌘↑, Open Selected Folder ⌘↓, Rescan ⌘R).
- `Sources/DiskModel.swift`: the one model: locations (`Location`, places, volumes, added folders), scanning state
  and progress, the expected size behind the gap (`pendingSize`, `estimatedSize`), navigation (`open`, `goUp`,
  `go(to:)`), the selection and the actions on it (`openItems`, `reveal`, `copyPath`, `trash`). Results live in
  memory only, one per location.
- `Sources/Scanner.swift`: `Node`, the tree (size, file count, children and completeness behind one lock, since the
  scanner fills it in from many threads while the window draws it; `sortedChildren` takes a snapshot), and the
  scanner: `getattrlistbulk`, which hands back many entries' name, type, device and allocated size in one call
  (a few times faster than `readdir` and a `stat` per file), parallel for the upper levels, staying on one volume,
  skipping links, counting allocated size.
- `Sources/Sunburst.swift`: `SunburstLayout` (slices per ring, colors) and `SunburstView` (Canvas drawing,
  hover, clicks, labels along the first ring, the center, the free-space slice), `formatBytes`.
- `Sources/ContentView.swift`: the two panes, the left one (`SidebarView`, `LocationRow`), the toolbar and the Move to Trash confirmation.
- `Sources/ItemList.swift`: the contents list in the left pane (rows captured as `ItemRow` so it updates while measuring).
- `Sources/BrowserView.swift`: the path bar, the chart with the status line, the right-click menu (`ItemMenu`, for one item or several),
  icons and share bars.

## Data

LampStore: "folders" (the added folders' paths), "lastLocation", "totals" (each location's last finished size, for
the gap) and "measuresAsking". Nothing else is kept.

## Easy to change

- Colors of the slices: `SunburstLayout.color` and the hue range in `add`. Rings: `SunburstLayout.rings`; thinnest slice drawn: `minSpan`.
- What counts as a small file: `Scanner.smallFileLimit`. What the scanner records per file (dates, kinds): more
  attributes asked of `getattrlistbulk` in `Scanner.scanFolder` (read back in the order of their bits, ATTR_CMN_ERROR first), kept on
  `Node`.
- Which folders wait for Measure Them: `Scanner.asksFirst`.
- The places in the sidebar: `DiskModel.init` (`places`) and `refreshVolumes`.
