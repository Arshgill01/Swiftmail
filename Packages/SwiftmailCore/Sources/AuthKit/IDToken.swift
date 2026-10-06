import Foundation

/// Claims read from the ID token returned directly by Google's token endpoint over TLS.
/// The signature is not checked: the token came straight from Google, which is the
/// case Google documents as safe to trust without validation.
public struct IDToken: Sendable, Equatable {
    public let sub: String
    public let email: String
    public let name: String?
    public let picture: String?

    public init(jwt: String) throws {
        let segments = jwt.split(separator: ".")
        guard segments.count >= 2, let payload = Base64URL.decode(String(segments[1])) else {
            throw AuthError.invalidResponse("id_token")
        }
        struct Claims: Decodable {
            let sub: String
            let email: String?
            let name: String?
            let picture: String?
        }
        let claims = try JSONDecoder().decode(Claims.self, from: payload)
        guard let email = claims.email else { throw AuthError.invalidResponse("id_token email") }
        sub = claims.sub
        self.email = email
        name = claims.name
        picture = claims.picture
    }
}
