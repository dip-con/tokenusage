import Foundation

public enum GrokCredentialError: Error, Equatable, Sendable {
    case malformed
    case unsupportedIssuer
}

/// The one signed-in session in a Grok CLI `auth.json`.
///
/// The file is a single-entry object keyed `"<issuer>::<client id>"`. The whole file is what gets
/// stored and swapped, so fields this app does not read survive untouched.
public struct GrokCredential: Equatable, Sendable {
    public static let issuer = "https://auth.x.ai"

    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let clientID: String
    public let userID: String?
    public let email: String?

    public func isExpired(at date: Date, leeway: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(date) <= leeway
    }

    public static func parse(_ data: Data) throws -> GrokCredential {
        let (key, entry) = try entry(in: data)
        guard let accessToken = entry["key"] as? String, !accessToken.isEmpty else {
            throw GrokCredentialError.malformed
        }
        let issuer = (entry["oidc_issuer"] as? String) ?? key.components(separatedBy: "::").first
        // Custom-IdP (enterprise OIDC) sessions renew elsewhere and are not SuperGrok accounts.
        guard issuer == Self.issuer else { throw GrokCredentialError.unsupportedIssuer }
        let clientID = (entry["oidc_client_id"] as? String)
            ?? key.components(separatedBy: "::").dropFirst().first
        guard let clientID, !clientID.isEmpty else { throw GrokCredentialError.malformed }
        return GrokCredential(
            accessToken: accessToken,
            refreshToken: (entry["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: (entry["expires_at"] as? String).flatMap(Self.date(from:)),
            clientID: clientID,
            userID: (entry["user_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            email: (entry["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    public static func applying(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date?,
        to data: Data
    ) throws -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokCredentialError.malformed
        }
        let (key, original) = try entry(in: data)
        var entry = original
        entry["key"] = accessToken
        entry["refresh_token"] = refreshToken
        if let expiresAt {
            entry["expires_at"] = Self.string(from: expiresAt)
        }
        root[key] = entry
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func entry(in data: Data) throws -> (String, [String: Any]) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root.count == 1,
              let (key, value) = root.first,
              let entry = value as? [String: Any] else {
            throw GrokCredentialError.malformed
        }
        return (key, entry)
    }

    private static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
