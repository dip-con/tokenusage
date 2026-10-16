import Foundation

/// A named Grok account. Everything here is non-secret: the CLI's `auth.json` for the account
/// lives in the Keychain under the profile identifier.
public struct GrokProfileMetadata: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let userID: String?
    public let emailAddress: String?
    public let subscriptionTier: String?

    public init(
        id: String,
        name: String,
        userID: String? = nil,
        emailAddress: String? = nil,
        subscriptionTier: String? = nil
    ) {
        self.id = id
        self.name = name
        self.userID = userID
        self.emailAddress = emailAddress
        self.subscriptionTier = subscriptionTier
    }
}

public enum GrokProfilePreferencesError: Error, Equatable {
    case invalidProfileMetadata
}

public protocol GrokProfilePreferencesStoring: AnyObject {
    func saveProfiles(_ profiles: [GrokProfileMetadata]) throws
    func profiles() throws -> [GrokProfileMetadata]
    var activeProfileID: String? { get set }
}

public final class GrokProfilePreferences: GrokProfilePreferencesStoring {
    private let defaults: UserDefaults
    private static let profilesKey = "grok.profileMetadata"
    private static let activeProfileIDKey = "grok.activeProfileID"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func saveProfiles(_ profiles: [GrokProfileMetadata]) throws {
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: Self.profilesKey)
        } catch {
            throw GrokProfilePreferencesError.invalidProfileMetadata
        }
    }

    public func profiles() throws -> [GrokProfileMetadata] {
        guard let data = defaults.data(forKey: Self.profilesKey) else { return [] }
        do {
            return try JSONDecoder().decode([GrokProfileMetadata].self, from: data)
        } catch {
            throw GrokProfilePreferencesError.invalidProfileMetadata
        }
    }

    public var activeProfileID: String? {
        get { defaults.string(forKey: Self.activeProfileIDKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.activeProfileIDKey)
            } else {
                defaults.removeObject(forKey: Self.activeProfileIDKey)
            }
        }
    }
}

public enum GrokLoginOutcome: Equatable, Sendable {
    case completed
    case cancelled
    case failed(terminationStatus: Int32)
}

/// Runs `grok login` with `GROK_HOME` pointed at a throwaway directory, so adding an account
/// never signs the current one out.
public protocol GrokLoginRunning: Sendable {
    func runGrokLogin(grokHome: URL) async throws -> GrokLoginOutcome
}
