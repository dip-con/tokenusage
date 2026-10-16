import Foundation

public enum GrokOAuthRefreshError: Error, Equatable, Sendable {
    case refreshTokenMissing
    case rejected
    case rateLimited
    case networkFailure
    case malformedResponse
    case unexpectedHTTPStatus(Int)
}

public struct GrokRenewedToken: Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public protocol GrokOAuthRefreshing: Sendable {
    func refresh(_ credential: GrokCredential) async throws -> GrokRenewedToken
}

/// Renews a stored Grok account with the standard OAuth refresh grant at auth.x.ai.
///
/// Only accounts the `grok` CLI is *not* signed in as may be renewed here: the CLI renews its own
/// session, and a refresh token rotated behind its back would sign it out.
public struct GrokOAuthRefresher: GrokOAuthRefreshing, Sendable {
    public static let endpoint = URL(string: "https://auth.x.ai/oauth2/token")!

    private let session: any URLSessionProtocol
    private let endpoint: URL
    private let now: @Sendable () -> Date

    public init(
        session: any URLSessionProtocol = URLSession.shared,
        endpoint: URL = GrokOAuthRefresher.endpoint,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.endpoint = endpoint
        self.now = now
    }

    public func refresh(_ credential: GrokCredential) async throws -> GrokRenewedToken {
        guard let refreshToken = credential.refreshToken else {
            throw GrokOAuthRefreshError.refreshTokenMissing
        }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: credential.clientID),
        ]
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // URLComponents leaves "+" bare, which a form decoder would read as a space.
        request.httpBody = form.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GrokOAuthRefreshError.networkFailure
        }
        guard let http = response as? HTTPURLResponse else {
            throw GrokOAuthRefreshError.malformedResponse
        }
        switch http.statusCode {
        case 200...299:
            break
        case 400, 401, 403:
            throw GrokOAuthRefreshError.rejected
        case 429:
            throw GrokOAuthRefreshError.rateLimited
        default:
            throw GrokOAuthRefreshError.unexpectedHTTPStatus(http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = root["access_token"] as? String, !accessToken.isEmpty else {
            throw GrokOAuthRefreshError.malformedResponse
        }
        let rotated = (root["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return GrokRenewedToken(
            accessToken: accessToken,
            refreshToken: rotated ?? refreshToken,
            expiresAt: (root["expires_in"] as? NSNumber).map {
                now().addingTimeInterval($0.doubleValue)
            }
        )
    }
}
