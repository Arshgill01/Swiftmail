import Foundation

public struct OAuthConfig: Sendable, Equatable {
    public static let authorizationEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")
    public static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")
    public static let revokeEndpoint = URL(string: "https://oauth2.googleapis.com/revoke")

    public static let defaultScopes = [
        "openid",
        "email",
        "profile",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.settings.basic",
    ]

    public let clientID: String
    public let clientSecret: String
    public let scopes: [String]

    public init(clientID: String, clientSecret: String, scopes: [String] = OAuthConfig.defaultScopes) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.scopes = scopes
    }

    /// Reads the client from the app's Info.plist, filled from `Secrets.xcconfig`.
    public static func fromBundle(_ bundle: Bundle = .main) -> OAuthConfig? {
        guard
            let id = bundle.object(forInfoDictionaryKey: "SwiftmailGoogleClientID") as? String,
            !id.isEmpty, !id.hasPrefix("$("), id.hasSuffix(".apps.googleusercontent.com")
        else { return nil }
        let secret = bundle.object(forInfoDictionaryKey: "SwiftmailGoogleClientSecret") as? String ?? ""
        return OAuthConfig(clientID: id, clientSecret: secret)
    }
}
