import Foundation
import XCTest
@testable import TokenUsageCore

final class SecurityCLIGenericPasswordClientTests: XCTestCase {
    func testMultiLineValueRoundTripsAndIsStoredAsBase64() throws {
        let keychain = FakeSecurityCLIKeychain()
        let client = SecurityCLIGenericPasswordClient(runner: keychain, writer: keychain)
        let authFile = Data("{\n  \"tokens\": {\n    \"access\": \"a\"\n  }\n}\n".utf8)

        try client.upsertGenericPassword(data: authFile, service: "svc", account: "p1")

        XCTAssertEqual(try client.copyGenericPassword(service: "svc", account: "p1"), authFile)
        XCTAssertEqual(keychain.rawValue(service: "svc", account: "p1"), authFile.base64EncodedString())
    }

    func testMissingItemReadsNilButOtherFailuresThrow() throws {
        let keychain = FakeSecurityCLIKeychain()
        let client = SecurityCLIGenericPasswordClient(runner: keychain, writer: keychain)

        XCTAssertNil(try client.copyGenericPassword(service: "svc", account: "missing"))
        keychain.failNextReadWithStatus = 51
        XCTAssertThrowsError(try client.copyGenericPassword(service: "svc", account: "missing"))
    }

    func testCompareAndSwapWritesOnlyOverTheExpectedValue() throws {
        let keychain = FakeSecurityCLIKeychain()
        let client = SecurityCLIGenericPasswordClient(runner: keychain, writer: keychain)
        try client.upsertGenericPassword(data: Data("old".utf8), service: "svc", account: "p1")

        XCTAssertFalse(try client.compareAndSwapGenericPassword(
            data: Data("new".utf8), expectedData: Data("other".utf8), service: "svc", account: "p1"
        ))
        XCTAssertTrue(try client.compareAndSwapGenericPassword(
            data: Data("new".utf8), expectedData: Data("old".utf8), service: "svc", account: "p1"
        ))
        XCTAssertEqual(try client.copyGenericPassword(service: "svc", account: "p1"), Data("new".utf8))
    }

    func testLegacyCredentialMovesToTheNewStoreBeforeTheOldOneIsRemoved() throws {
        let keychain = FakeSecurityCLIKeychain()
        let current = KeychainCredentialStore(
            service: "svc.v2",
            keychain: SecurityCLIGenericPasswordClient(runner: keychain, writer: keychain)
        )
        let legacyClient = MemoryGenericPasswordClient()
        let legacy = KeychainCredentialStore(service: "svc", keychain: legacyClient)
        try legacy.storeCredential(Data("secret".utf8), named: "p1")
        let store = MigratingCredentialStore(current: current, legacy: legacy)

        XCTAssertEqual(try store.credential(named: "p1"), Data("secret".utf8))

        XCTAssertEqual(try current.credential(named: "p1"), Data("secret".utf8))
        XCTAssertNil(try legacy.credential(named: "p1"))
    }
}

/// Stands in for `/usr/bin/security`: answers the read script's `<status> <value>` line and
/// keeps what the writer stored.
private final class FakeSecurityCLIKeychain: SecurityCLIProcessRunning, SecurityCLIPasswordWriting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var items: [String: String] = [:]
    var failNextReadWithStatus: Int32?

    func rawValue(service: String, account: String) -> String? {
        lock.withLock { items["\(service)/\(account)"] }
    }

    func run(executable: URL, arguments: [String]) throws -> SecurityCLIProcessResult {
        let service = arguments[arguments.count - 2]
        let account = arguments[arguments.count - 1]
        let line: String = lock.withLock {
            if let status = failNextReadWithStatus {
                failNextReadWithStatus = nil
                return "\(status) \n"
            }
            guard let value = items["\(service)/\(account)"] else { return "44 \n" }
            return "0 \(value)\n"
        }
        return SecurityCLIProcessResult(terminationStatus: 0, stdout: Data(line.utf8))
    }

    func writeGenericPassword(service: String, account: String, password: Data) throws {
        lock.withLock { items["\(service)/\(account)"] = String(decoding: password, as: UTF8.self) }
    }

    func deleteGenericPassword(service: String, account: String) throws {
        lock.withLock { items["\(service)/\(account)"] = nil }
    }
}

private final class MemoryGenericPasswordClient: GenericPasswordClient, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func copyGenericPassword(service: String, account: String) throws -> Data? {
        lock.withLock { items["\(service)/\(account)"] }
    }

    func upsertGenericPassword(data: Data, service: String, account: String) throws {
        lock.withLock { items["\(service)/\(account)"] = data }
    }

    func removeGenericPassword(service: String, account: String) throws {
        lock.withLock { items["\(service)/\(account)"] = nil }
    }
}
