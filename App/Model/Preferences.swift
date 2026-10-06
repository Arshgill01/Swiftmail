import Foundation
import SwiftmailCore

/// UserDefaults keys and typed accessors usable off the main actor.
enum Preferences {
    static let listDensity = "listDensity"
    static let backfillWindow = "backfillWindow"
    static let undoSendDelay = "undoSendDelay"
    static let loadRemoteImages = "loadRemoteImages"
    static let readerFontSize = "readerFontSize"
    static let dockBadge = "dockBadge"
    static let notificationsEnabled = "notificationsEnabled"
    static let notifyPrimaryOnly = "notifyPrimaryOnly"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            listDensity: ListDensity.comfortable.rawValue,
            backfillWindow: BackfillWindow.oneYear.rawValue,
            undoSendDelay: 10,
            loadRemoteImages: false,
            readerFontSize: 14.0,
            dockBadge: true,
        ])
    }

    static var syncSettings: SyncSettings {
        let raw = UserDefaults.standard.string(forKey: backfillWindow) ?? ""
        return SyncSettings(backfillWindow: BackfillWindow(rawValue: raw) ?? .oneYear)
    }

    /// Per-account switches are stored as `<key>.<accountID>`.
    static func accountKey(_ key: String, _ accountID: String) -> String {
        "\(key).\(accountID)"
    }
}

enum ListDensity: String, CaseIterable {
    case comfortable, compact
}
