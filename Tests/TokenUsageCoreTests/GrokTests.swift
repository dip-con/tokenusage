import Foundation
import XCTest
@testable import TokenUsageCore

final class GrokUsageDecoderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_172_800)

    func testCreditUsagePercentBecomesRemainingWeeklyQuota() throws {
        let snapshot = try GrokUsageDecoder.decode(
            billing(extra: #""creditUsagePercent": 37.5,"#),
            capturedAt: now
        )

        let weekly = try XCTUnwrap(snapshot.weekly)
        XCTAssertEqual(weekly.remainingPercent, 62.5)
        XCTAssertEqual(
            try XCTUnwrap(weekly.resetsAt).timeIntervalSince1970,
            1_792_552_534.414,
            accuracy: 0.01
        )
        XCTAssertEqual(try XCTUnwrap(weekly.windowDuration), 7 * 24 * 60 * 60, accuracy: 0.01)
    }

    func testCurrentPeriodWithoutPercentReadsAsNothingUsed() throws {
        let snapshot = try GrokUsageDecoder.decode(billing(extra: ""), capturedAt: now)

        XCTAssertEqual(snapshot.weekly?.remainingPercent, 100)
    }

    func testOnDemandCapIsUsedWhenNoPercentIsReported() throws {
        let snapshot = try GrokUsageDecoder.decode(
            billing(extra: #""onDemandCap": {"val": 200}, "onDemandUsed": {"val": 150},"#),
            capturedAt: now
        )

        XCTAssertEqual(snapshot.weekly?.remainingPercent, 25)
    }

    func testAnEndedPeriodWithoutPercentIsNotGuessed() {
        let later = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertThrowsError(try GrokUsageDecoder.decode(billing(extra: ""), capturedAt: later)) {
            XCTAssertEqual($0 as? GrokUsageClientError, .malformedResponse)
        }
    }

    private func billing(extra: String) -> Data {
        Data(#"""
        {"config": {\#(extra)
          "currentPeriod": {"type": "USAGE_PERIOD_TYPE_WEEKLY",
            "start": "2026-10-14T03:15:34.414496+00:00",
            "end": "2026-10-21T03:15:34.414496+00:00"},
          "isUnifiedBillingUser": true}}
        """#.utf8)
    }
}

final class GrokOAuthRefresherTests: XCTestCase {
    func testRefreshPostsTheStandardGrantAndKeepsTheRefreshTokenWhenNotRotated() async throws {
        let session = RecordingSession(
            body: #"{"access_token": "new-access", "expires_in": 21600}"#,
            status: 200
        )
        let now = Date(timeIntervalSince1970: 1_000)
        let refresher = GrokOAuthRefresher(session: session, now: { now })

        let renewed = try await refresher.refresh(
            GrokFixture.credential(refreshToken: "a+b/c")
        )

        XCTAssertEqual(renewed.accessToken, "new-access")
        XCTAssertEqual(renewed.refreshToken, "a+b/c")
        XCTAssertEqual(renewed.expiresAt, now.addingTimeInterval(21_600))
        let request = try XCTUnwrap(session.lastRequest)
        XCTAssertEqual(request.url, GrokOAuthRefresher.endpoint)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=a%2Bb/c"))
        XCTAssertTrue(body.contains("client_id=\(GrokFixture.clientID)"))
    }

    func testRejectedRefreshIsReportedAsRejected() async {
        let refresher = GrokOAuthRefresher(
            session: RecordingSession(body: #"{"error": "invalid_grant"}"#, status: 400)
        )

        do {
            _ = try await refresher.refresh(GrokFixture.credential())
            XCTFail("A rejected grant must not produce a token")
        } catch {
            XCTAssertEqual(error as? GrokOAuthRefreshError, .rejected)
        }
    }
}

final class GrokProfileManagerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSaveCurrentStoresTheLiveFileAndMakesItActive() async throws {
        let fixture = Fixture(live: GrokFixture.authFile(token: "live", userID: "u1", expiresAt: now + 3_600))
        let manager = fixture.manager(now: now)

        let saved = try await manager.saveCurrent(named: "personal")

        XCTAssertEqual(try fixture.credentials.credential(named: saved.id), fixture.live.current)
        XCTAssertEqual(saved.userID, "u1")
        XCTAssertEqual(saved.subscriptionTier, "SuperGrok")
        let activeID = await manager.activeProfileID()
        XCTAssertEqual(activeID, saved.id)
    }

    func testAddAccountReadsTheIsolatedHomeAndLeavesTheLiveAccountAlone() async throws {
        let live = GrokFixture.authFile(token: "live", userID: "u1", expiresAt: now + 3_600)
        let fixture = Fixture(live: live)
        let added = GrokFixture.authFile(token: "second", userID: "u2", expiresAt: now + 3_600)
        fixture.login.plant = { home in
            try? added.write(to: home.appendingPathComponent("auth.json"))
        }
        let manager = fixture.manager(now: now)

        let profile = try await manager.addAccount(named: "work")

        let stored = try XCTUnwrap(profile.flatMap { try fixture.credentials.credential(named: $0.id) })
        XCTAssertEqual(stored, added)
        XCTAssertEqual(fixture.live.current, live)
        let activeID = await manager.activeProfileID()
        XCTAssertNil(activeID, "a new sign-in is stored without being activated")
        let home = try XCTUnwrap(fixture.login.homes.first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.path), "the throwaway home is removed")
    }

    func testTheActiveAccountIsNeverRenewedByTheApp() async throws {
        let fixture = Fixture(live: GrokFixture.authFile(token: "live", userID: "u1", expiresAt: now + 3_600))
        let manager = fixture.manager(now: now)
        let saved = try await manager.saveCurrent(named: "personal")
        fixture.live.current = GrokFixture.authFile(token: "live", userID: "u1", expiresAt: now - 60)
        await manager.syncActiveProfile()

        do {
            _ = try await manager.accessToken(for: saved.id)
            XCTFail("An expired CLI token must be renewed by the CLI, not here")
        } catch {
            XCTAssertEqual(error as? GrokProfileManagerError, .activeCredentialExpired)
        }
        XCTAssertEqual(fixture.refresher.calls, 0)
    }

    func testAnExpiredInactiveAccountIsRenewedAndStored() async throws {
        let fixture = Fixture(live: GrokFixture.authFile(token: "live", userID: "u1", expiresAt: now + 3_600))
        fixture.refresher.result = GrokRenewedToken(
            accessToken: "renewed",
            refreshToken: "rotated",
            expiresAt: now + 21_600
        )
        let manager = fixture.manager(now: now)
        _ = try await manager.saveCurrent(named: "personal")
        let other = try fixture.storeProfile(
            GrokFixture.authFile(token: "stale", userID: "u2", expiresAt: now - 60)
        )

        let token = try await manager.accessToken(for: other.id)

        XCTAssertEqual(token, "renewed")
        let stored = try XCTUnwrap(try fixture.credentials.credential(named: other.id))
        let credential = try GrokCredential.parse(stored)
        XCTAssertEqual(credential.accessToken, "renewed")
        XCTAssertEqual(credential.refreshToken, "rotated")
        XCTAssertEqual(credential.userID, "u2", "fields the app does not renew survive")
    }

    func testActivateSwapsTheLiveFileAndKeepsTheOutgoingAccountsLatestToken() async throws {
        let fixture = Fixture(live: GrokFixture.authFile(token: "live", userID: "u1", expiresAt: now + 3_600))
        let manager = fixture.manager(now: now)
        let personal = try await manager.saveCurrent(named: "personal")
        let work = try fixture.storeProfile(
            GrokFixture.authFile(token: "work", userID: "u2", expiresAt: now + 3_600)
        )
        let renewedByCLI = GrokFixture.authFile(token: "live-renewed", userID: "u1", expiresAt: now + 7_200)
        fixture.live.current = renewedByCLI

        try await manager.activateProfile(id: work.id)

        XCTAssertEqual(fixture.live.current, try fixture.credentials.credential(named: work.id))
        XCTAssertEqual(try fixture.credentials.credential(named: personal.id), renewedByCLI)
        let activeID = await manager.activeProfileID()
        XCTAssertEqual(activeID, work.id)
    }

    func testActivateRefusesToOverwriteAnUnsavedLiveAccount() async throws {
        let unsaved = GrokFixture.authFile(token: "unsaved", userID: "u9", expiresAt: now + 3_600)
        let fixture = Fixture(live: unsaved)
        let manager = fixture.manager(now: now)
        let work = try fixture.storeProfile(
            GrokFixture.authFile(token: "work", userID: "u2", expiresAt: now + 3_600)
        )

        do {
            try await manager.activateProfile(id: work.id)
            XCTFail("An account nobody saved must not be overwritten")
        } catch {
            XCTAssertEqual(error as? GrokProfileManagerError, .currentAccountNotSaved)
        }
        XCTAssertEqual(fixture.live.current, unsaved)
    }

    private final class Fixture: @unchecked Sendable {
        let credentials = MemoryClaudeCredentialStore()
        let preferences = MemoryGrokPreferences()
        let live: MemoryAuthFile
        let refresher = FakeGrokRefresher()
        let login = FakeGrokLogin()

        init(live: Data?) {
            self.live = MemoryAuthFile(current: live)
        }

        func manager(now: Date) -> GrokProfileManager {
            GrokProfileManager(
                credentialStore: credentials,
                preferences: preferences,
                liveAuthFile: live,
                refresher: refresher,
                loginRunner: login,
                subscriptionTier: { _ in "SuperGrok" },
                now: { now }
            )
        }

        func storeProfile(_ data: Data) throws -> GrokProfileMetadata {
            let credential = try GrokCredential.parse(data)
            let profile = GrokProfileMetadata(
                id: UUID().uuidString,
                name: credential.userID ?? "profile",
                userID: credential.userID
            )
            try credentials.storeCredential(data, named: profile.id)
            try preferences.saveProfiles(try preferences.profiles() + [profile])
            return profile
        }
    }
}

enum GrokFixture {
    static let clientID = "b1a00492-073a-47ea-816f-4c329264a828"

    static func credential(refreshToken: String = "refresh") -> GrokCredential {
        try! GrokCredential.parse(authFile(token: "token", userID: "u1", expiresAt: nil, refreshToken: refreshToken))
    }

    static func authFile(
        token: String,
        userID: String,
        expiresAt: Date?,
        refreshToken: String = "refresh"
    ) -> Data {
        var entry: [String: Any] = [
            "key": token,
            "refresh_token": refreshToken,
            "user_id": userID,
            "email": "\(userID)@example.com",
            "oidc_issuer": GrokCredential.issuer,
            "oidc_client_id": clientID,
            "auth_mode": "oidc",
        ]
        if let expiresAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            entry["expires_at"] = formatter.string(from: expiresAt)
        }
        return try! JSONSerialization.data(
            withJSONObject: ["\(GrokCredential.issuer)::\(clientID)": entry],
            options: [.sortedKeys]
        )
    }
}

private final class RecordingSession: URLSessionProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let body: String
    private let status: Int
    private var request: URLRequest?

    init(body: String, status: Int) {
        self.body = body
        self.status = status
    }

    var lastRequest: URLRequest? { lock.withLock { request } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { self.request = request }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (Data(body.utf8), response)
    }
}

final class MemoryGrokPreferences: GrokProfilePreferencesStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [GrokProfileMetadata] = []
    private var active: String?

    var activeProfileID: String? {
        get { lock.withLock { active } }
        set { lock.withLock { active = newValue } }
    }

    func saveProfiles(_ profiles: [GrokProfileMetadata]) throws {
        lock.withLock { stored = profiles }
    }

    func profiles() throws -> [GrokProfileMetadata] {
        lock.withLock { stored }
    }
}

final class MemoryAuthFile: AuthFileOperating, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    init(current: Data?) {
        data = current
    }

    var current: Data? {
        get { lock.withLock { data } }
        set { lock.withLock { data = newValue } }
    }

    func readAuthFile() throws -> Data? {
        current
    }

    func replaceAuthFile(with data: Data, ifCurrentMatches expectedData: Data?) throws {
        try lock.withLock {
            guard self.data == expectedData else { throw AtomicAuthFileError.conflict }
            self.data = data
        }
    }

    func restoreAuthFile(to data: Data?, ifCurrentMatches expectedData: Data?) throws {
        try lock.withLock {
            guard self.data == expectedData else { throw AtomicAuthFileError.conflict }
            self.data = data
        }
    }
}

final class FakeGrokRefresher: GrokOAuthRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private var renewed: GrokRenewedToken?
    private var count = 0

    var result: GrokRenewedToken? {
        get { lock.withLock { renewed } }
        set { lock.withLock { renewed = newValue } }
    }

    var calls: Int { lock.withLock { count } }

    func refresh(_ credential: GrokCredential) async throws -> GrokRenewedToken {
        try lock.withLock {
            count += 1
            guard let renewed else { throw GrokOAuthRefreshError.rejected }
            return renewed
        }
    }
}

final class FakeGrokLogin: GrokLoginRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []
    private var planter: (@Sendable (URL) -> Void)?

    var plant: (@Sendable (URL) -> Void)? {
        get { lock.withLock { planter } }
        set { lock.withLock { planter = newValue } }
    }

    var homes: [URL] { lock.withLock { recorded } }

    func runGrokLogin(grokHome: URL) async throws -> GrokLoginOutcome {
        let plant = lock.withLock {
            recorded.append(grokHome)
            return planter
        }
        plant?(grokHome)
        return .completed
    }
}
