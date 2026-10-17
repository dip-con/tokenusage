import Foundation

public enum GrokProfileManagerError: Error, Equatable, Sendable, LocalizedError {
    case invalidProfileName
    case currentAccountMissing
    case currentAccountNotSaved
    case unsupportedAccount
    case profileNotFound
    case credentialMissing
    case activeCredentialExpired
    case signedOut
    case concurrentModification
    case storageFailed
    case loginUnavailable
    case loginFailed
    case loginFailedWithStatus(Int32)
    case temporaryDirectoryFailed

    public var errorDescription: String? {
        switch self {
        case .invalidProfileName:
            "계정 이름이 비어 있습니다."
        case .currentAccountMissing:
            "grok CLI 에 로그인된 계정을 읽지 못했습니다."
        case .currentAccountNotSaved:
            "지금 grok CLI 에 로그인된 계정이 저장되어 있지 않습니다. 먼저 현재 계정을 저장해 주세요."
        case .unsupportedAccount:
            "x.ai 계정 로그인만 지원합니다."
        case .profileNotFound:
            "해당 Grok 계정을 찾지 못했습니다."
        case .credentialMissing:
            "저장된 Grok 자격 증명이 없습니다."
        case .activeCredentialExpired:
            "grok CLI 토큰이 만료되었습니다. grok 을 한 번 실행하거나 다시 로그인해 주세요."
        case .signedOut:
            "저장된 Grok 계정의 로그인이 만료되었습니다. 다시 로그인해 주세요."
        case .concurrentModification:
            "전환하는 사이에 grok CLI 계정이 바뀌었습니다."
        case .storageFailed:
            "Grok 계정 저장소 작업에 실패했습니다."
        case .loginUnavailable:
            "grok 실행 파일을 찾지 못해 로그인을 시작할 수 없습니다."
        case .loginFailed:
            "Grok 로그인에 실패했습니다."
        case let .loginFailedWithStatus(status):
            "Grok 로그인이 종료 코드 \(status) 로 실패했습니다."
        case .temporaryDirectoryFailed:
            "로그인용 임시 디렉터리를 만들지 못했습니다."
        }
    }
}

/// Named Grok accounts, switched by swapping the `auth.json` the `grok` CLI reads.
///
/// The account the CLI is signed in as is the CLI's to renew while a `grok` process is running;
/// otherwise nothing would ever renew it, so the app renews it and writes the rotated token back
/// into `auth.json` for the next CLI start. The other accounts' refresh tokens only this app holds.
public actor GrokProfileManager {
    public static let bootstrapProfileName = "grok1"

    private let credentialStore: any CredentialStoring
    private let preferences: any GrokProfilePreferencesStoring
    private let liveAuthFile: any AuthFileOperating
    private let refresher: any GrokOAuthRefreshing
    private let loginRunner: (any GrokLoginRunning)?
    private let subscriptionTier: @Sendable (String) async -> String?
    private let isCLIRunning: @Sendable () -> Bool
    private let temporaryDirectory: URL
    private let profileID: @Sendable () -> String
    private let now: @Sendable () -> Date
    /// Renewed credentials the Keychain refused. The old refresh token is already spent, so the
    /// new one is served from memory and written again on every read until the Keychain takes it.
    private var unsavedCredentials: [String: Data] = [:]

    public init(
        credentialStore: any CredentialStoring,
        preferences: any GrokProfilePreferencesStoring,
        liveAuthFile: any AuthFileOperating,
        refresher: any GrokOAuthRefreshing,
        loginRunner: (any GrokLoginRunning)? = nil,
        subscriptionTier: @escaping @Sendable (String) async -> String? = { _ in nil },
        isCLIRunning: @escaping @Sendable () -> Bool = { true },
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        profileID: @escaping @Sendable () -> String = { UUID().uuidString },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.credentialStore = credentialStore
        self.preferences = preferences
        self.liveAuthFile = liveAuthFile
        self.refresher = refresher
        self.loginRunner = loginRunner
        self.subscriptionTier = subscriptionTier
        self.isCLIRunning = isCLIRunning
        self.temporaryDirectory = temporaryDirectory
        self.profileID = profileID
        self.now = now
    }

    public func listProfiles() throws -> [GrokProfileMetadata] {
        do {
            return try preferences.profiles()
        } catch {
            throw GrokProfileManagerError.storageFailed
        }
    }

    public func activeProfileID() -> String? {
        preferences.activeProfileID
    }

    public func hasLiveAccount() -> Bool {
        (try? liveAuthFile.readAuthFile()) != nil
    }

    @discardableResult
    public func saveCurrent(named requestedName: String) async throws -> GrokProfileMetadata {
        let name = try validatedName(requestedName)
        let data = try liveCredentialData()
        let credential = try parsed(data)
        guard !credential.isExpired(at: now(), leeway: 0) else {
            throw GrokProfileManagerError.activeCredentialExpired
        }
        let tier = await subscriptionTier(credential.accessToken)
        return try persist(
            name: name,
            data: data,
            credential: credential,
            tier: tier,
            makeActive: true
        )
    }

    /// Signs in to another account in a throwaway `GROK_HOME`; the account the CLI is signed in
    /// as is untouched and the new one is stored without being activated.
    public func addAccount(named requestedName: String) async throws -> GrokProfileMetadata? {
        let name = try validatedName(requestedName)
        guard let loginRunner else { throw GrokProfileManagerError.loginUnavailable }
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let outcome: GrokLoginOutcome
        do {
            outcome = try await loginRunner.runGrokLogin(grokHome: home)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GrokProfileManagerError.loginFailed
        }
        switch outcome {
        case .completed:
            break
        case .cancelled:
            return nil
        case let .failed(status):
            throw GrokProfileManagerError.loginFailedWithStatus(status)
        }

        guard let data = try? Data(contentsOf: home.appendingPathComponent("auth.json")) else {
            throw GrokProfileManagerError.currentAccountMissing
        }
        let credential = try parsed(data)
        let tier = await subscriptionTier(credential.accessToken)
        return try persist(
            name: name,
            data: data,
            credential: credential,
            tier: tier,
            makeActive: false
        )
    }

    /// Follows the CLI: it renews its own token and can be signed in to another account from a
    /// terminal, so the live account is matched by user id and only its own profile is updated.
    public func syncActiveProfile() {
        guard let data = try? liveAuthFile.readAuthFile(),
              let credential = try? GrokCredential.parse(data) else {
            if preferences.activeProfileID != nil { preferences.activeProfileID = nil }
            return
        }
        let profiles = (try? preferences.profiles()) ?? []
        let live = profiles.first { Self.isSameAccount($0, credential) }
        if preferences.activeProfileID != live?.id {
            preferences.activeProfileID = live?.id
        }
        guard let live, (try? storedCredential(live.id)) != data else { return }
        if (try? credentialStore.storeCredential(data, named: live.id)) != nil {
            unsavedCredentials[live.id] = nil
        }
    }

    public func accessToken(for id: String) async throws -> String {
        guard let stored = try storedCredential(id) else {
            throw GrokProfileManagerError.credentialMissing
        }
        let credential = try parsed(stored)
        let isActive = id == preferences.activeProfileID
        if isActive {
            guard credential.isExpired(at: now(), leeway: 0) else { return credential.accessToken }
            // A running CLI holds the refresh token in memory; rotating it here would sign it out.
            guard !isCLIRunning() else { throw GrokProfileManagerError.activeCredentialExpired }
        } else {
            guard credential.isExpired(at: now()) else { return credential.accessToken }
        }

        let renewed: GrokRenewedToken
        do {
            renewed = try await refresher.refresh(credential)
        } catch GrokOAuthRefreshError.rejected {
            throw GrokProfileManagerError.signedOut
        } catch GrokOAuthRefreshError.refreshTokenMissing {
            throw GrokProfileManagerError.signedOut
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GrokProfileManagerError.credentialMissing
        }
        if let updated = try? GrokCredential.applying(
            accessToken: renewed.accessToken,
            refreshToken: renewed.refreshToken,
            expiresAt: renewed.expiresAt,
            to: stored
        ) {
            if isActive {
                // The CLI reads this file on its next start; losing the race to it just means it
                // already wrote a newer session, which the next sync picks up.
                try? liveAuthFile.replaceAuthFile(with: updated, ifCurrentMatches: stored)
            }
            do {
                try credentialStore.storeCredential(updated, named: id)
                unsavedCredentials[id] = nil
            } catch {
                unsavedCredentials[id] = updated
            }
        }
        return renewed.accessToken
    }

    public func activateProfile(id: String) async throws {
        guard try listProfiles().contains(where: { $0.id == id }) else {
            throw GrokProfileManagerError.profileNotFound
        }
        syncActiveProfile()
        guard id != preferences.activeProfileID else { return }

        let original = try? liveAuthFile.readAuthFile()
        // Overwriting an account nobody saved would sign it out of this Mac for good.
        if let original, (try? GrokCredential.parse(original)) != nil,
           preferences.activeProfileID == nil {
            throw GrokProfileManagerError.currentAccountNotSaved
        }

        _ = try await accessToken(for: id)
        guard let candidate = try storedCredential(id) else {
            throw GrokProfileManagerError.credentialMissing
        }
        do {
            try liveAuthFile.replaceAuthFile(with: candidate, ifCurrentMatches: original)
        } catch AtomicAuthFileError.conflict {
            throw GrokProfileManagerError.concurrentModification
        } catch {
            throw GrokProfileManagerError.storageFailed
        }
        preferences.activeProfileID = id
    }

    public func removeProfile(id: String) throws {
        let profiles = try listProfiles()
        guard profiles.contains(where: { $0.id == id }) else {
            throw GrokProfileManagerError.profileNotFound
        }
        do {
            try credentialStore.removeCredential(named: id)
            unsavedCredentials[id] = nil
            try preferences.saveProfiles(profiles.filter { $0.id != id })
        } catch {
            throw GrokProfileManagerError.storageFailed
        }
        if preferences.activeProfileID == id {
            preferences.activeProfileID = nil
        }
    }

    private func persist(
        name: String,
        data: Data,
        credential: GrokCredential,
        tier: String?,
        makeActive: Bool
    ) throws -> GrokProfileMetadata {
        let profiles = try listProfiles()
        let existing = profiles.first { Self.isSameAccount($0, credential) }
        let metadata = GrokProfileMetadata(
            id: existing?.id ?? profileID(),
            name: name,
            userID: credential.userID,
            emailAddress: credential.email,
            subscriptionTier: tier ?? existing?.subscriptionTier
        )
        do {
            try credentialStore.storeCredential(data, named: metadata.id)
            unsavedCredentials[metadata.id] = nil
            var updated = profiles
            if let index = updated.firstIndex(where: { $0.id == metadata.id }) {
                updated[index] = metadata
            } else {
                updated.append(metadata)
            }
            try preferences.saveProfiles(updated)
        } catch {
            throw GrokProfileManagerError.storageFailed
        }
        if makeActive {
            preferences.activeProfileID = metadata.id
        }
        return metadata
    }

    private func liveCredentialData() throws -> Data {
        guard let data = try? liveAuthFile.readAuthFile() else {
            throw GrokProfileManagerError.currentAccountMissing
        }
        return data
    }

    private func parsed(_ data: Data) throws -> GrokCredential {
        do {
            return try GrokCredential.parse(data)
        } catch GrokCredentialError.unsupportedIssuer {
            throw GrokProfileManagerError.unsupportedAccount
        } catch {
            throw GrokProfileManagerError.currentAccountMissing
        }
    }

    private func storedCredential(_ id: String) throws -> Data? {
        if let unsaved = unsavedCredentials[id] {
            if (try? credentialStore.storeCredential(unsaved, named: id)) != nil {
                unsavedCredentials[id] = nil
            }
            return unsaved
        }
        do {
            return try credentialStore.credential(named: id)
        } catch {
            throw GrokProfileManagerError.storageFailed
        }
    }

    private func makeTemporaryHome() throws -> URL {
        let home = temporaryDirectory.appendingPathComponent(
            "tokenusage-grok-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: home,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw GrokProfileManagerError.temporaryDirectoryFailed
        }
        return home.standardizedFileURL
    }

    private func validatedName(_ requestedName: String) throws -> String {
        let name = requestedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GrokProfileManagerError.invalidProfileName }
        return name
    }

    static func isSameAccount(_ profile: GrokProfileMetadata, _ credential: GrokCredential) -> Bool {
        if let userID = credential.userID, let existing = profile.userID { return userID == existing }
        if let email = credential.email, let existing = profile.emailAddress { return email == existing }
        return false
    }
}
