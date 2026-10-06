import SwiftmailCore
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            ContentUnavailableView("No Mailbox Selected", systemImage: "tray")
                .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 600)
        } detail: {
            ContentUnavailableView("No Conversation Selected", systemImage: "envelope")
                .frame(minWidth: 480)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            NeedsSignInBanner()
        }
    }
}
