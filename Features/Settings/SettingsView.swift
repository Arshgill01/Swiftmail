import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form { Text("General settings") }.formStyle(.grouped)
            }
            Tab("Accounts", systemImage: "at") {
                Form { Text("Accounts") }.formStyle(.grouped)
            }
        }
        .frame(width: 560, height: 420)
    }
}
