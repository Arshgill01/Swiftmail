import Foundation

/// Namespace for shared constants of the core package.
public enum SwiftmailCore {
    public static let appSupportFolderName = "Swiftmail"

    /// `Application Support/Swiftmail`, inside the app container when sandboxed.
    public static func appSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let url = base.appendingPathComponent(appSupportFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
