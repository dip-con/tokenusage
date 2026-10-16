import Foundation
import XCTest
@testable import TokenUsageApp
import TokenUsageCore

@MainActor
final class GrokProfilePresentationTests: XCTestCase {
    func testShowsOneRowPerGrokAccountWithItsSubscriptionWindow() {
        let model = makeModel()
        let weekly = QuotaWindow(
            remainingPercent: 62.5,
            resetsAt: Date(timeIntervalSince1970: 1_792_552_534),
            windowDuration: 7 * 24 * 60 * 60
        )
        let monthly = QuotaWindow(
            remainingPercent: 10,
            resetsAt: nil,
            windowDuration: 31 * 24 * 60 * 60
        )

        model.apply(.current(snapshot(weekly: weekly, monthly: monthly)))

        XCTAssertEqual(model.grokQuotaRows.map(\.name), ["personal", "work"])
        XCTAssertEqual(model.grokQuotaRows.map(\.quota.window), ["주간", "월간"])
        XCTAssertEqual(model.grokQuotaRows.map(\.quota.percentText), ["63%", "10%"])
        XCTAssertEqual(model.grokQuotaRows.map(\.subscriptionTier), ["SuperGrok", nil])
        XCTAssertEqual(model.grokQuotaRows.filter(\.isActive).map(\.profileID), ["grok-1"])
        XCTAssertEqual(model.activeGrokProfileName, "personal")
    }

    func testFailedGrokAccountReadsAsUnavailableWithoutAffectingOthers() {
        let model = makeModel()
        let base = snapshot(
            weekly: QuotaWindow(remainingPercent: 50, resetsAt: nil),
            monthly: nil
        )

        model.apply(.current(base))

        XCTAssertEqual(model.grokQuotaRows.map(\.freshnessText), ["최신", "조회 실패"])
        XCTAssertEqual(model.grokQuotaRows.last?.quota.percentText, "--")
    }

    private func snapshot(weekly: QuotaWindow, monthly: QuotaWindow?) -> AppUsageSnapshot {
        let captured = Date(timeIntervalSince1970: 1_792_172_800)
        return AppUsageSnapshot(
            claude: .unavailable(message: ""),
            codexUsage: [],
            codexProfiles: [],
            activeCodexProfileID: nil,
            grokUsage: [
                GrokProfileUsage(
                    profileID: "grok-1",
                    state: .fresh(UsageSnapshot(capturedAt: captured, weekly: weekly))
                ),
                GrokProfileUsage(
                    profileID: "grok-2",
                    state: monthly.map { .fresh(UsageSnapshot(capturedAt: captured, weekly: $0)) }
                        ?? .unavailable(message: "")
                ),
            ],
            grokProfiles: [
                GrokProfileMetadata(
                    id: "grok-1",
                    name: "personal",
                    emailAddress: "me@example.com",
                    subscriptionTier: "SuperGrok"
                ),
                GrokProfileMetadata(id: "grok-2", name: "work"),
            ],
            activeGrokProfileID: "grok-1"
        )
    }

    private func makeModel() -> AppViewModel {
        AppViewModel(
            coordinator: GrokPassthroughCoordinator(),
            profileActions: GrokUnusedCodexActions(),
            locale: Locale(identifier: "ko_KR"),
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }
}

private struct GrokUnusedCodexActions: CodexProfileActionHandling {
    func selectProfile(id: String) async throws -> AppUsageSnapshot {
        throw CodexProfileManagerError.profileNotFound
    }

    func saveCurrentProfile(named name: String) async throws -> AppUsageSnapshot {
        throw CodexProfileManagerError.profileNotFound
    }

    func addAccount(named name: String) async throws -> AppUsageSnapshot {
        throw CodexProfileManagerError.profileNotFound
    }

    func deleteProfile(id: String) async throws -> AppUsageSnapshot {
        throw CodexProfileManagerError.profileNotFound
    }
}

private actor GrokPassthroughCoordinator: AppUsageCoordinating {
    func start() async {}

    func stateChanges() async -> AsyncStream<RefreshState<AppUsageSnapshot>> {
        AsyncStream { $0.finish() }
    }

    func requestRefresh() async {}

    func performProfileOperation(
        _ operation: @escaping @Sendable () async throws -> AppUsageSnapshot
    ) async throws -> AppUsageSnapshot {
        try await operation()
    }

    func stop() async {}
}
