import SwiftUI

@main
struct MainApp: SwiftUI.App {
    @StateObject private var model = DiskModel()

    var body: some SwiftUI.Scene {
        WindowGroup("Disk Map") {
            ContentView()
                .environmentObject(model)
        }
        .commands {
            LampCommands()
            DiskCommands(model: model)
        }
    }
}

struct DiskCommands: Commands {
    @ObservedObject var model: DiskModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Folder…") { model.addFolder() }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .newItem) {
            Divider()
            Button("Show in Finder") {
                if model.selectedNodes.isEmpty { if let current = model.current { model.reveal(current) } } else { model.reveal(model.selectedNodes) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(model.current == nil)
            Button("Move to Trash…") { requestTrash(model.selectedNodes) }
                .keyboardShortcut(.delete)
                .disabled(!model.canTrashSelection)
        }
        CommandMenu("Go") {
            Button("Back") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
            Button("Enclosing Folder") { model.goUp() }
                .keyboardShortcut(.upArrow)
                .disabled(!model.canGoUp)
            Button("Open Selected Folder") { if let node = model.selectedNode { model.open(node) } }
                .keyboardShortcut(.downArrow)
                .disabled(model.selectedNode?.kind != .folder)
            Divider()
            Button("Rescan") { model.scan() }
                .keyboardShortcut("r")
                .disabled(model.location == nil || model.scanning)
        }
    }
}
