import Foundation
import Observation
import CryptoKit
import AuthenticationServices
import UIKit

/// Connects the user's Gmail account via OAuth 2.0 with PKCE, run entirely in an
/// `ASWebAuthenticationSession` — no Google SDK and no Info.plist URL scheme, as
/// the session intercepts the reversed-client-id callback itself.
///
/// The refresh token (used for sending later) lives in the Keychain; only the
/// connected email address is cached on disk for display.
@Observable
final class GmailAuthStore: NSObject, ASWebAuthenticationPresentationContextProviding {
    private(set) var connectedEmail: String?
    private(set) var isConnecting = false
    var errorMessage: String?

    var isConnected: Bool { connectedEmail != nil }

    private static let refreshTokenKey = "gmail.refreshToken"
    private let file = JSONFile<Stored>(name: "gmail.json")
    private struct Stored: Codable { var email: String }

    @ObservationIgnored private var webSession: ASWebAuthenticationSession?

    override init() {
        super.init()
        connectedEmail = file.load()?.email
    }

    // MARK: - Connect / disconnect

    @MainActor
    func connect() async {
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }

        do {
            let verifier = Self.codeVerifier()
            let code = try await authorize(verifier: verifier)
            let tokens = try await exchange(code: code, verifier: verifier)

            if let refresh = tokens.refresh_token {
                Keychain.set(refresh, for: Self.refreshTokenKey)
            }
            let email = tokens.id_token.flatMap(Self.email(fromIDToken:)) ?? "Connected"
            connectedEmail = email
            file.save(Stored(email: email))
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // User dismissed the sign-in sheet — not an error worth surfacing.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        Keychain.set(nil, for: Self.refreshTokenKey)
        file.delete()
        connectedEmail = nil
    }

    // MARK: - Sending

    /// Send a plain-text email from the connected account via the Gmail API.
    func send(to recipient: String, subject: String, body: String, fromName: String) async throws {
        let token = try await accessToken()
        let raw = Self.mimeMessage(
            from: connectedEmail ?? "", fromName: fromName,
            to: recipient, subject: subject, body: body
        )

        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["raw": raw])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GmailAuthError.server(String(data: data, encoding: .utf8) ?? "Send failed.")
        }
    }

    /// Trade the stored refresh token for a short-lived access token.
    private func accessToken() async throws -> String {
        guard let refresh = Keychain.get(Self.refreshTokenKey) else {
            throw GmailAuthError.notConnected
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.googleClientID),
            URLQueryItem(name: "refresh_token", value: refresh),
            URLQueryItem(name: "grant_type", value: "refresh_token")
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GmailAuthError.server(String(data: data, encoding: .utf8) ?? "Couldn't refresh Google session.")
        }
        struct Refreshed: Decodable { let access_token: String }
        return try JSONDecoder().decode(Refreshed.self, from: data).access_token
    }

    /// Build a base64url-encoded RFC 2822 message for the Gmail API's `raw` field.
    private static func mimeMessage(from: String, fromName: String, to: String, subject: String, body: String) -> String {
        let fromHeader = fromName.isEmpty ? from : "\(fromName) <\(from)>"
        let headers = [
            "From: \(fromHeader)",
            "To: \(to)",
            "Subject: \(encodeHeader(subject))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=\"UTF-8\"",
            "Content-Transfer-Encoding: 8bit"
        ]
        let message = headers.joined(separator: "\r\n") + "\r\n\r\n" + body
        return Data(message.utf8).base64URLEncodedString()
    }

    /// RFC 2047-encode a header value only when it contains non-ASCII characters.
    private static func encodeHeader(_ text: String) -> String {
        guard !text.allSatisfy(\.isASCII) else { return text }
        return "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
    }

    // MARK: - OAuth steps

    /// Present Google's consent screen and return the authorization code.
    @MainActor
    private func authorize(verifier: String) async throws -> String {
        defer { webSession = nil }
        let state = UUID().uuidString
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.googleClientID),
            URLQueryItem(name: "redirect_uri", value: AppConfig.googleRedirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: AppConfig.googleScopes),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // Force account choice + consent so a refresh token is always issued.
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: AppConfig.googleRedirectScheme
            ) { url, error in
                if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: error ?? GmailAuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            webSession = session
            session.start()
        }

        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        guard items?.first(where: { $0.name == "state" })?.value == state,
              let code = items?.first(where: { $0.name == "code" })?.value else {
            throw GmailAuthError.invalidResponse
        }
        return code
    }

    /// Trade the authorization code for access + refresh tokens.
    private func exchange(code: String, verifier: String) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.googleClientID),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "code_verifier", value: verifier),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "redirect_uri", value: AppConfig.googleRedirectURI)
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GmailAuthError.server(String(data: data, encoding: .utf8) ?? "Token exchange failed.")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    // MARK: - Helpers

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The system always calls this on the main thread.
        MainActor.assumeIsolated {
            let scene = UIApplication.shared.connectedScenes
                .first { $0.activationState == .foregroundActive } as? UIWindowScene
            return scene?.keyWindow ?? ASPresentationAnchor()
        }
    }

    private static func codeVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// Pull the email claim out of the returned id_token (a JWT) so we can show
    /// which account connected, without an extra userinfo request.
    private static func email(fromIDToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return claims["email"] as? String
    }
}

enum GmailAuthError: LocalizedError {
    case cancelled
    case invalidResponse
    case notConnected
    case server(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sign-in was cancelled."
        case .invalidResponse: return "Unexpected response from Google."
        case .notConnected: return "Connect Gmail in Profile first."
        case .server(let message): return message
        }
    }
}

private extension Data {
    /// Base64URL without padding, as required by PKCE.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
