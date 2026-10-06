import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form { Text("General settings") }.formStyle(.grouped)
            }
            Tab("Accounts", systemImage: "at") {
                AccountsSettingsView()
            }
        }
        .frame(width: 560, height: 420)
    }
}
