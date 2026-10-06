import SwiftUI

struct MailboxRow: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var count: Int = 0

    var body: some View {
        HStack {
            Label {
                Text(title).lineLimit(1)
            } icon: {
                if let tint {
                    Image(systemName: "tag.fill").foregroundStyle(tint)
                } else {
                    Image(systemName: systemImage)
                }
            }
            Spacer(minLength: 4)
            if count > 0 {
                Text(count, format: .number)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(count > 0 ? "\(title), \(count) unread" : title)
    }
}
