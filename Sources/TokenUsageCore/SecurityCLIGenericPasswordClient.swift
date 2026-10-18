import Foundation

/// App-owned generic passwords kept through `/usr/bin/security` instead of Security.framework.
///
/// An item the app writes itself trusts the app by its partition ID, and an app without an Apple
/// team is identified there only by its cdhash, which changes on every build - so every rebuild
/// asked for the login password once per saved account. Items `security` writes trust Apple's
/// own signature instead, which no rebuild of this app changes; Claude Code's item, read the same
/// way, never prompted.
public struct SecurityCLIGenericPasswordClient: ConditionalGenericPasswordClient, Sendable {
    private static let shell = URL(fileURLWithPath: "/bin/sh")
    /// The runner's FIFO transport returns only the first line and no exit status, so one line
    /// carries both: `<status> <value>`, where 44 is a missing item. Values are stored base64, so
    /// a multi-line `auth.json` neither breaks that line nor gets hex-printed by `security -w`.
    private static let readScript = """
    value=$(/usr/bin/security find-generic-password -s "$1" -a "$2" -w 2>/dev/null); \
    printf '%s %s\\n' "$?" "$value"
    """
    private static let itemNotFoundStatus = "44"
    private static let operationLock = NSLock()

    private let runner: any SecurityCLIProcessRunning
    private let writer: any SecurityCLIPasswordWriting

    public init() {
        self.init(runner: SystemSecurityCLIProcessRunner(), writer: SystemSecurityCLIPasswordWriter())
    }

    public init(runner: any SecurityCLIProcessRunning, writer: any SecurityCLIPasswordWriting) {
        self.runner = runner
        self.writer = writer
    }

    public func copyGenericPassword(service: String, account: String) throws -> Data? {
        try Self.operationLock.withLock { try copyUnlocked(service: service, account: account) }
    }

    public func upsertGenericPassword(data: Data, service: String, account: String) throws {
        try Self.operationLock.withLock {
            try write(data, service: service, account: account)
        }
    }

    public func removeGenericPassword(service: String, account: String) throws {
        try Self.operationLock.withLock {
            try writer.deleteGenericPassword(service: service, account: account)
        }
    }

    public func compareAndSwapGenericPassword(
        data: Data,
        expectedData: Data,
        service: String,
        account: String
    ) throws -> Bool {
        // Indivisible only against this client in this process, like SystemGenericPasswordClient.
        try Self.operationLock.withLock {
            guard try copyUnlocked(service: service, account: account) == expectedData else {
                return false
            }
            try write(data, service: service, account: account)
            return true
        }
    }

    private func copyUnlocked(service: String, account: String) throws -> Data? {
        let result: SecurityCLIProcessResult
        do {
            result = try runner.run(
                executable: Self.shell,
                arguments: ["-c", Self.readScript, "sh", service, account]
            )
        } catch {
            throw KeychainCredentialStoreError.operationFailed
        }
        let line = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard let status = fields.first else { throw KeychainCredentialStoreError.operationFailed }
        if status == Self.itemNotFoundStatus { return nil }
        guard status == "0", fields.count == 2,
              let value = Data(base64Encoded: String(fields[1])), !value.isEmpty else {
            throw KeychainCredentialStoreError.operationFailed
        }
        return value
    }

    private func write(_ data: Data, service: String, account: String) throws {
        try writer.writeGenericPassword(
            service: service,
            account: account,
            password: Data(data.base64EncodedString().utf8)
        )
    }
}

/// Moves each credential from the Security.framework item it used to live in to a
/// `security`-written one the first time it is read, so the old item asks for the login password
/// one last time and never again. The new item is written before the old one is removed, so an
/// interrupted move leaves a copy behind rather than losing the account.
public struct MigratingCredentialStore: ConditionalCredentialStoring, Sendable {
    private let current: KeychainCredentialStore
    private let legacy: KeychainCredentialStore

    public init(current: KeychainCredentialStore, legacy: KeychainCredentialStore) {
        self.current = current
        self.legacy = legacy
    }

    public func credential(named name: String) throws -> Data? {
        if let stored = try current.credential(named: name) { return stored }
        guard let old = try legacy.credential(named: name) else { return nil }
        try current.storeCredential(old, named: name)
        try? legacy.removeCredential(named: name)
        return old
    }

    public func storeCredential(_ credential: Data, named name: String) throws {
        try current.storeCredential(credential, named: name)
    }

    public func removeCredential(named name: String) throws {
        try current.removeCredential(named: name)
        try legacy.removeCredential(named: name)
    }

    public func storeCredential(
        _ credential: Data,
        named name: String,
        ifCurrentMatches expectedCredential: Data
    ) throws -> Bool {
        _ = try self.credential(named: name)
        return try current.storeCredential(
            credential,
            named: name,
            ifCurrentMatches: expectedCredential
        )
    }
}

extension KeychainCredentialStore {
    /// The store for the app's own saved accounts: `<service>.v2` through `security`, migrating
    /// anything still in the Security.framework item named `<service>`.
    public static func appOwned(service: String) -> MigratingCredentialStore {
        MigratingCredentialStore(
            current: KeychainCredentialStore(
                service: "\(service).v2",
                keychain: SecurityCLIGenericPasswordClient()
            ),
            legacy: KeychainCredentialStore(service: service)
        )
    }
}
