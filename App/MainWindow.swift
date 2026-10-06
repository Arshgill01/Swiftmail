import SwiftmailCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var window = MainWindowModel()
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(window: window)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            ThreadListView(window: window)
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 640)
        } detail: {
            ReaderView(window: window)
                .frame(minWidth: 480)
        }
        .toolbar { MainToolbar(window: window) }
        .overlay(alignment: .bottom) { ToastView() }
        .sheet(item: $window.sheet) { sheet in
            switch sheet {
            case .labels: LabelPickerSheet(window: window, mode: .apply)
            case .move: LabelPickerSheet(window: window, mode: .move)
            case .goToLabel: LabelPickerSheet(window: window, mode: .navigate)
            case .shortcuts: ShortcutsSheet()
            }
        }
        .background(WindowAccessor { WindowRegistry.register($0, model: window) })
        .focusedSceneValue(\.mainWindow, window)
        .onAppear { window.app = model }
    }
}

struct MainToolbar: ToolbarContent {
    let window: MainWindowModel

    var body: some ToolbarContent {
        let disabled = window.selectionOrCursor.isEmpty
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Archive", systemImage: "archivebox") { window.perform(.archive) }
                .help("Archive (E)").disabled(disabled)
            Button("Move to Trash", systemImage: "trash") { window.perform(.trash) }
                .help("Move to Trash (#)").disabled(disabled)
            Button("Report Spam", systemImage: "xmark.octagon") { window.perform(.spam) }
                .help("Report spam (!)").disabled(disabled)
            Button("Label", systemImage: "tag") { window.perform(.labelPicker) }
                .help("Label (L)").disabled(disabled)
            Button("Move", systemImage: "folder") { window.perform(.movePicker) }
                .help("Move to (V)").disabled(disabled)
            Button("Mark as Unread", systemImage: "envelope.badge") { window.perform(.toggleRead) }
                .help("Mark as read or unread (⇧⌘U)").disabled(disabled)
            Button("Star", systemImage: "star") { window.perform(.toggleStar) }
                .help("Star (S)").disabled(disabled)
            Button("New Message", systemImage: "square.and.pencil") { window.perform(.compose) }
                .help("New message (C)")
        }
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.undo.toast {
            HStack(spacing: 12) {
                Text(toast.message)
                if toast.canUndo {
                    Button("Undo") { model.undoLast() }
                        .buttonStyle(.link)
                        .keyboardShortcut("z", modifiers: .command)
                }
                Button {
                    model.undo.dismiss()
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 4, y: 2)
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
