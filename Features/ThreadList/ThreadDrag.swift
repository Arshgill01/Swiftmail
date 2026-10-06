import Foundation
import SwiftmailCore

/// Thread IDs carried by a drag from the list to a sidebar label, as a plain string.
enum ThreadDrag {
    static let prefix = "swiftmail-threads:"

    /// Dragging a selected row drags the whole selection.
    static func payload(for id: ThreadSummary.ID, selection: Set<ThreadSummary.ID>) -> String {
        let ids = selection.contains(id) ? Array(selection) : [id]
        let data = (try? JSONEncoder().encode(ids)) ?? Data()
        return prefix + String(decoding: data, as: UTF8.self)
    }

    static func decode(_ strings: [String]) -> [ThreadSummary.ID] {
        strings.flatMap { string -> [ThreadSummary.ID] in
            guard string.hasPrefix(prefix) else { return [] }
            return (try? JSONDecoder().decode([ThreadSummary.ID].self, from: Data(string.dropFirst(prefix.count).utf8))) ?? []
        }
    }
}
