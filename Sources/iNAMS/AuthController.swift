import AppKit
import AuthenticationServices
import CryptoKit
import iNAMSKit

/// One-time onboarding: Auth0 sign-in (Authorization Code + PKCE via
/// ASWebAuthenticationSession) → POST /v1/auth/exchange → mint the app's own
/// Admin API key → Keychain. After this the key powers everything and the
/// browser is never needed again (the key self-rotates via the rotate
/// endpoint before its 90-day expiry).
///
/// Requires an Auth0 **Native** application with `inams://auth/callback` in
/// its allowed callback URLs, and the `inams` URL scheme registered in
/// Info.plist (project.yml does this for the bundled app).
@MainActor
final class AuthController: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Auth0Settings {
        var domain: String
        var clientID: String
        var audience: String?

        // TODO: real Auth0 Native-app values before first release (open item
        // in docs/PLAN.md). Overridable for staging via `defaults write`.
        static func resolved(defaults: UserDefaults = .standard) -> Auth0Settings {
            Auth0Settings(
                domain: defaults.string(forKey: "NAMSAuth0Domain") ?? "REPLACE-ME.us.auth0.com",
                clientID: defaults.string(forKey: "NAMSAuth0ClientID") ?? "REPLACE_ME_CLIENT_ID",
                audience: defaults.string(forKey: "NAMSAuth0Audience")
            )
        }
    }

    enum AuthError: LocalizedError {
        case badCallback
        case tokenEndpoint(String)
        case noWorkspaceToken

        var errorDescription: String? {
            switch self {
            case .badCallback: return "Auth0 callback was missing the authorization code"
            case .tokenEndpoint(let msg): return "Auth0 token exchange failed: \(msg)"
            case .noWorkspaceToken: return "NAMS exchange returned no workspace tokens"
            }
        }
    }

    private let settings = Auth0Settings.resolved()

    func signIn(client: NAMSClient, keychain: KeychainStore) async throws {
        // PKCE pair
        let verifier = Self.randomURLSafe(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()

        var authorize = URLComponents(string: "https://\(settings.domain)/authorize")!
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: settings.clientID),
            URLQueryItem(name: "redirect_uri", value: "inams://auth/callback"),
            URLQueryItem(name: "scope", value: "openid profile email"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let audience = settings.audience {
            queryItems.append(URLQueryItem(name: "audience", value: audience))
        }
        authorize.queryItems = queryItems

        let callbackURL = try await presentAuthSession(url: authorize.url!)
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value
        else {
            throw AuthError.badCallback
        }

        let (accessToken, idToken) = try await redeemCode(code, verifier: verifier)

        // Auth0 token -> short-lived per-workspace NAMS JWTs.
        let exchange = try await client.exchange(auth0AccessToken: accessToken, idToken: idToken)
        guard let workspaceToken = exchange.workspaces.first?.token else {
            throw AuthError.noWorkspaceToken
        }

        // Mint the app's long-lived Admin key with the fresh JWT and store it.
        // Admin category because sandbox status needs workspace:admin and MCP
        // setup needs key-minting rights (see docs/PLAN.md).
        let host = Host.current().localizedName ?? "Mac"
        let created = try await client.createAPIKey(
            label: "iNAMS – \(host)",
            category: "admin",
            bearerOverride: workspaceToken
        )
        try keychain.set(created.key, account: KeychainStore.apiKeyAccount)
        try keychain.set(created.id, account: KeychainStore.apiKeyIDAccount)
    }

    // MARK: - Plumbing

    private func presentAuthSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "inams") { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: AuthError.badCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }

    private func redeemCode(_ code: String, verifier: String) async throws -> (access: String, id: String?) {
        struct TokenResponse: Decodable {
            let access_token: String
            let id_token: String?
        }
        var request = URLRequest(url: URL(string: "https://\(settings.domain)/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "client_id": settings.clientID,
            "code": code,
            "redirect_uri": "inams://auth/callback",
            "code_verifier": verifier,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.tokenEndpoint(String(data: data.prefix(200), encoding: .utf8) ?? "unknown")
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        return (token.access_token, token.id_token)
    }

    private static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes).base64URLEncoded()
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Menu bar app has no main window; an off-screen anchor suffices.
        MainActor.assumeIsolated {
            NSApp.windows.first ?? NSWindow(
                contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true
            )
        }
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
