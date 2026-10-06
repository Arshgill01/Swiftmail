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
    }
}
