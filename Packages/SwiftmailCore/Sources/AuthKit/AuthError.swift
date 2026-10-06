import Foundation

public enum AuthError: Error, Sendable, Equatable, LocalizedError {
    /// The OAuth client ID is missing from `Config/Secrets.xcconfig`.
    case notConfigured
    /// The refresh token was revoked or expired (`invalid_grant`), or is missing.
    case needsSignIn
    /// The user denied access or Google returned an error on the redirect.
    case authorizationDenied(String)
    case stateMismatch
    case timedOut
    case cancelled
    case invalidResponse(String)
    case tokenEndpoint(code: String, description: String?)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Swiftmail has no Google OAuth client yet. Add it to Config/Secrets.xcconfig (see README) and rebuild."
        case .needsSignIn:
            "This account needs to sign in again."
        case let .authorizationDenied(reason):
            switch reason {
            case "access_denied": "Access was not granted."
            case "admin_policy_enforced":
                "Your Google Workspace admin blocks this app. The admin must allow Swiftmail's client ID."
            default: "Google returned an error: \(reason)."
            }
        case .stateMismatch: "The sign-in response did not match this request. Try again."
        case .timedOut: "Sign-in timed out after 5 minutes."
        case .cancelled: "Sign-in was cancelled."
        case let .invalidResponse(detail): "Unexpected response from Google (\(detail))."
        case let .tokenEndpoint(code, description): "Google sign-in failed: \(description ?? code)."
        case let .keychain(status): "Keychain error \(status)."
        }
    }
}
