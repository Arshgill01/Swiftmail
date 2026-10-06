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
            ReaderPlaceholder(window: window)
                .frame(minWidth: 480)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            NeedsSignInBanner()
        }
    }
}

struct ReaderPlaceholder: View {
    let window: MainWindowModel

    var body: some View {
        if window.selectedThreads.count > 1 {
            ContentUnavailableView("\(window.selectedThreads.count) conversations selected", systemImage: "envelope.badge")
        } else {
            ContentUnavailableView("No Conversation Selected", systemImage: "envelope")
        }
    }
}
