import Foundation
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

final class AppSettingsTests: XCTestCase {
    func testStoredOrderKeepsEveryProviderExactlyOnce() {
        let settings = ProviderSettings(order: [.openRouter, .claude, .openRouter], disabled: [])

        XCTAssertEqual(settings.order, [.openRouter, .claude, .codex, .grok])
    }

    func testUnknownStoredProvidersAreSkippedWithoutResettingTheRest() throws {
        let json = #"{"providerOrder":["grok","gemini","claude"],"disabledProviders":["codex","gemini"]}"#

        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))

        XCTAssertEqual(settings.providers.order, [.grok, .claude, .codex, .openRouter])
        XCTAssertEqual(settings.providers.disabled, [.codex])
    }

    func testSettingsRoundTripThroughUserDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppSettingsTests-\(UUID().uuidString)"))
        var settings = AppSettings.default
        settings.providers.move(.grok, by: -2)
        settings.providers.setEnabled(false, for: .openRouter)

        UserDefaultsAppSettingsStore(defaults: defaults).save(settings)

        XCTAssertEqual(UserDefaultsAppSettingsStore(defaults: defaults).current, settings)
        XCTAssertEqual(settings.providers.enabledInOrder, [.grok, .claude, .codex])
    }

    func testMenuBarListLeavesOutHiddenAndDisabledProvidersButKeepsThemInThePopover() throws {
        var settings = AppSettings.default
        settings.providers.setShowsInMenuBar(false, for: .codex)
        settings.providers.setEnabled(false, for: .openRouter)

        XCTAssertEqual(settings.providers.enabledInOrder, [.claude, .codex, .grok])
        XCTAssertEqual(settings.providers.menuBarInOrder, [.claude, .grok])
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: try JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded, settings)
    }

    func testMoveStopsAtTheEnds() {
        var settings = ProviderSettings.default

        settings.move(.claude, by: -1)
        settings.move(.openRouter, by: 5)

        XCTAssertEqual(settings.order, ProviderKind.allCases)
    }

    func testMenuBarFollowsOrderAndHidesDisabledProviders() {
        let presentation = StatusItemPresentation(
            claude: .fresh(UsageSnapshot(
                capturedAt: Date(),
                fiveHour: QuotaWindow(remainingPercent: 40, resetsAt: nil),
                weekly: QuotaWindow(remainingPercent: 70, resetsAt: nil)
            )),
            codexProfiles: [
                StatusItemCodexProfileState(
                    profileID: "c",
                    name: "codex",
                    state: .fresh(UsageSnapshot(
                        capturedAt: Date(),
                        weekly: QuotaWindow(remainingPercent: 12, resetsAt: nil)
                    ))
                ),
            ],
            grokProfiles: [
                StatusItemCodexProfileState(
                    profileID: "g",
                    name: "grok",
                    state: .fresh(UsageSnapshot(
                        capturedAt: Date(),
                        weekly: QuotaWindow(remainingPercent: 90, resetsAt: nil)
                    ))
                ),
            ],
            providerOrder: [.grok, .claude]
        )

        XCTAssertEqual(presentation.visibleLabels, ["90%", "40%", "70%"])
        XCTAssertTrue(presentation.codexProfiles.isEmpty)
    }

    @MainActor
    func testDisabledProvidersAreNotRefreshed() async {
        let store = InMemoryAppSettingsStore()
        var settings = AppSettings.default
        settings.providers.setEnabled(false, for: .claude)
        settings.providers.setEnabled(false, for: .openRouter)
        store.save(settings)
        let calls = CallCounter()
        let service = ProductionAppService(
            loadClaude: {
                await calls.record("claude")
                throw ClaudeUsageClientError.credentialUnavailable
            },
            loadCodex: { _ in throw CodexAppServerClient.Error.processFailed },
            loadOpenRouter: {
                await calls.record("openRouter")
                throw OpenRouterUsageClientError.keyUnavailable
            },
            profileManager: EmptyCodexProfiles(),
            settings: store
        )

        _ = await service.refresh()

        let recorded = await calls.names
        XCTAssertEqual(recorded, [])
    }
}

private actor CallCounter {
    private(set) var names: [String] = []

    func record(_ name: String) {
        names.append(name)
    }
}

private struct EmptyCodexProfiles: CodexProfileManaging {
    func saveCurrent(named name: String) async throws -> CodexProfileMetadata {
        throw CodexProfileManagerError.currentAccountMissing
    }

    func addAccount(named name: String) async throws -> CodexProfileMetadata? { nil }
    func removeProfile(id: String) async throws {}
    func listProfiles() async throws -> [CodexProfileMetadata] { [] }
    func activeProfileID() async -> String? { nil }
    func activateProfile(id: String) async throws {}

    func materializeProfileHome(id: String) async throws -> CodexProfileHomeMaterialization {
        throw CodexProfileManagerError.credentialMissing
    }

    func writeBackProfileCredential(id: String, baseline: Data) async throws {}
}
