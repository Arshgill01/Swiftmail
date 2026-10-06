import SwiftmailCore
import SwiftUI

struct ThreadRow: View {
    let thread: ThreadSummary
    let density: ListDensity
    let ownAddresses: Set<String>
    let labels: [String: LabelRecord]
    let accountColor: Color?

    var body: some View {
        HStack(spacing: 0) {
            if let accountColor {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accountColor)
                    .frame(width: 3)
                    .padding(.vertical, 4)
                    .padding(.trailing, 5)
            }
            Circle()
                .fill(thread.isUnread ? Color.accentColor : .clear)
                .frame(width: 7, height: 7)
                .padding(.trailing, 6)
            if density == .comfortable {
                comfortable
            } else {
                compact
            }
        }
        .frame(height: density == .comfortable ? 64 : 24)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var comfortable: some View {
        HStack(alignment: .top, spacing: 10) {
            let sender = thread.participants.first { !ownAddresses.contains($0.email.lowercased()) } ?? thread.participants.first
            AvatarView(name: sender?.name ?? sender?.email ?? "?", email: sender?.email ?? "", size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    senderText
                    Spacer(minLength: 4)
                    trailingIcons
                    Text(ThreadDateFormatter.string(thread.lastDate))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                HStack(spacing: 4) {
                    Text(subject)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    labelChips
                }
                Text(thread.snippet ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var compact: some View {
        HStack(spacing: 8) {
            senderText
                .frame(width: 150, alignment: .leading)
            Text(subject)
                .font(.system(size: 13))
                .lineLimit(1)
                .layoutPriority(1)
            Text(thread.snippet ?? "")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            labelChips
            trailingIcons
            Text(ThreadDateFormatter.string(thread.lastDate))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var senderText: some View {
        HStack(spacing: 3) {
            Text(senderLine)
                .font(.system(size: 13, weight: thread.isUnread ? .semibold : .regular))
                .lineLimit(1)
            if thread.messageCount > 1 {
                Text("\(thread.messageCount)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if thread.hasDraft {
                Text("Draft")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var trailingIcons: some View {
        if thread.hasAttachments {
            Image(systemName: "paperclip")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        if thread.isStarred {
            Image(systemName: "star.fill")
                .font(.system(size: 10))
                .foregroundStyle(.yellow)
        }
    }

    @ViewBuilder
    private var labelChips: some View {
        let userLabels = thread.labelIDs.compactMap { labels[$0] }.filter { $0.type == "user" }
        if !userLabels.isEmpty {
            HStack(spacing: 3) {
                ForEach(userLabels.prefix(2), id: \.id) { label in
                    LabelChip(label: label)
                }
                if userLabels.count > 2 {
                    Text("+\(userLabels.count - 2)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var subject: String {
        let text = thread.subject?.trimmingCharacters(in: .whitespaces) ?? ""
        return text.isEmpty ? "(no subject)" : text
    }

    /// "Alex, me" style list of participants, first names when there are several.
    var senderLine: String {
        let names = thread.participants.map { address -> String in
            if ownAddresses.contains(address.email.lowercased()) {
                return "me"
            }
            let name = address.name ?? address.email
            if thread.participants.count > 1 {
                return name.split(separator: " ").first.map(String.init) ?? name
            }
            return name
        }
        return names.isEmpty ? "(no sender)" : names.joined(separator: ", ")
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if thread.isUnread {
            parts.append("Unread")
        }
        if thread.isStarred {
            parts.append("Starred")
        }
        parts.append("From \(senderLine)")
        parts.append(subject)
        if let snippet = thread.snippet {
            parts.append(snippet)
        }
        parts.append(ThreadDateFormatter.string(thread.lastDate))
        return parts.joined(separator: ". ")
    }
}

struct LabelChip: View {
    let label: LabelRecord

    var body: some View {
        let name = label.name.split(separator: "/").last.map(String.init) ?? label.name
        Text(name)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .foregroundStyle(Color(hex: label.colorText) ?? .primary)
            .background(Color(hex: label.colorBg)?.opacity(0.9) ?? Color.secondary.opacity(0.15), in: Capsule())
    }
}

enum ThreadDateFormatter {
    /// Time today, "Oct 3" this year, "3/10/24" before.
    static func string(_ millis: Int64, now: Date = Date()) -> String {
        let date = Date(millis: millis)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
