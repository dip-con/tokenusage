import Foundation
import TokenUsageCore

struct StatusItemClaudeProfileState: Equatable, Sendable {
    let profileID: String
    let name: String
    let state: UsageState
}

struct StatusItemClaudeProfile: Equatable, Sendable {
    let profileID: String
    let name: String
    let fiveHourText: String
    /// The weekly limit, or the Fable one on plans (Team) that report no all-model weekly limit.
    let weeklyText: String
    let weeklyIsFable: Bool

    var weeklyAccessibilityName: String {
        weeklyIsFable ? "Fable weekly" : "weekly"
    }
}

struct StatusItemCodexProfileState: Equatable, Sendable {
    let profileID: String
    let name: String
    let state: UsageState
}

struct StatusItemCodexProfile: Equatable, Sendable {
    let profileID: String
    let name: String
    let weeklyText: String
}

struct StatusItemPresentation: Equatable, Sendable {
    static let claudeMark = "✳"
    static let codexMark = "◎"
    static let grokMark = "✦"
    static let openRouterMark = "◑"
    static let staleIndicator = "•"

    /// One column per signed-in Claude account, each stacking 5-hour over weekly remaining
    /// (Fable weekly when the plan has no all-model weekly limit).
    let claudeProfiles: [StatusItemClaudeProfile]
    let codexProfiles: [StatusItemCodexProfile]
    /// One weekly (or monthly) remaining value per Grok account; empty hides the Grok group.
    let grokProfiles: [StatusItemCodexProfile]
    /// The provider groups shown, left to right; a provider missing here is hidden.
    let providerOrder: [ProviderKind]
    /// nil when OpenRouter has no key or its balance could not be read; the label stays hidden then.
    let openRouterBalanceText: String?
    let isStale: Bool

    var claudeFiveHourText: String {
        claudeProfiles.first?.fiveHourText ?? "--"
    }

    var claudeWeeklyText: String {
        claudeProfiles.first?.weeklyText ?? "--"
    }

    var codexWeeklyTexts: [String] {
        codexProfiles.map(\.weeklyText)
    }

    var visibleLabels: [String] {
        providerOrder.flatMap { provider -> [String] in
            switch provider {
            case .claude: claudeProfiles.flatMap { [$0.fiveHourText, $0.weeklyText] }
            case .codex: codexWeeklyTexts
            case .grok: grokProfiles.map(\.weeklyText)
            case .openRouter: [openRouterBalanceText].compactMap { $0 }
            }
        }
    }

    var staleIndicatorText: String? {
        isStale ? Self.staleIndicator : nil
    }

    init(
        claudeProfiles: [StatusItemClaudeProfileState],
        codexProfiles: [StatusItemCodexProfileState],
        openRouter: OpenRouterUsageState = .notConfigured(message: ""),
        grokProfiles: [StatusItemCodexProfileState] = [],
        providerOrder: [ProviderKind] = ProviderKind.allCases
    ) {
        let claudeContents = providerOrder.contains(.claude)
            ? claudeProfiles.map { Self.content(from: $0.state) }
            : []
        let codexContents = providerOrder.contains(.codex)
            ? codexProfiles.map { Self.content(from: $0.state) }
            : []
        let grokContents = providerOrder.contains(.grok)
            ? grokProfiles.map { Self.content(from: $0.state) }
            : []

        self.claudeProfiles = zip(claudeProfiles, claudeContents).map { profile, content in
            let weeklyIsFable = content.snapshot?.weekly == nil && content.snapshot?.fableWeekly != nil
            return StatusItemClaudeProfile(
                profileID: profile.profileID,
                name: profile.name,
                fiveHourText: Self.label(value: content.snapshot?.fiveHour),
                weeklyText: Self.label(
                    value: weeklyIsFable ? content.snapshot?.fableWeekly : content.snapshot?.weekly
                ),
                weeklyIsFable: weeklyIsFable
            )
        }
        self.codexProfiles = zip(codexProfiles, codexContents).map { profile, content in
            StatusItemCodexProfile(
                profileID: profile.profileID,
                name: profile.name,
                weeklyText: Self.label(value: content.snapshot?.weekly)
            )
        }
        self.grokProfiles = zip(grokProfiles, grokContents).map { profile, content in
            StatusItemCodexProfile(
                profileID: profile.profileID,
                name: profile.name,
                weeklyText: Self.label(value: content.snapshot?.weekly)
            )
        }
        self.providerOrder = providerOrder
        openRouterBalanceText = providerOrder.contains(.openRouter)
            ? Self.balanceLabel(from: openRouter)
            : nil
        isStale = (claudeContents + codexContents + grokContents).contains { $0.isStale }
    }

    /// Single-account form, used before any Claude profile has been captured.
    init(
        claude: UsageState,
        codexProfiles: [StatusItemCodexProfileState],
        openRouter: OpenRouterUsageState = .notConfigured(message: ""),
        grokProfiles: [StatusItemCodexProfileState] = [],
        providerOrder: [ProviderKind] = ProviderKind.allCases
    ) {
        self.init(
            claudeProfiles: [
                StatusItemClaudeProfileState(profileID: "", name: "Claude", state: claude)
            ],
            codexProfiles: codexProfiles,
            openRouter: openRouter,
            grokProfiles: grokProfiles,
            providerOrder: providerOrder
        )
    }

    private static func balanceLabel(from state: OpenRouterUsageState) -> String? {
        let remaining: Double
        switch state {
        case let .fresh(snapshot):
            remaining = snapshot.remaining
        case let .stale(lastGood, _):
            remaining = lastGood.remaining
        case .unavailable, .notConfigured:
            return nil
        }
        guard remaining.isFinite else { return nil }
        return String(
            format: "$%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            max(0, remaining)
        )
    }

    private static func content(from state: UsageState) -> (snapshot: UsageSnapshot?, isStale: Bool) {
        switch state {
        case let .fresh(snapshot):
            return (snapshot, false)
        case let .stale(lastGood, _):
            return (lastGood, true)
        case .unavailable:
            return (nil, false)
        }
    }

    private static func label(value: QuotaWindow?) -> String {
        guard let remaining = value?.remainingPercent,
              remaining.isFinite,
              remaining <= 100
        else {
            return "--"
        }

        return "\(Int(max(0, remaining).rounded()))%"
    }
}
