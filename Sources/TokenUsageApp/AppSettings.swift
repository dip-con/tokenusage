import Foundation

public enum ProviderKind: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case grok
    case openRouter

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .openRouter: "OpenRouter"
        }
    }
}

/// Which providers the app shows, and in what order, everywhere it shows them: the popover
/// sections, the menu bar columns and the phone page. A disabled provider is also not refreshed.
public struct ProviderSettings: Equatable, Sendable {
    public private(set) var order: [ProviderKind]
    public private(set) var disabled: Set<ProviderKind>
    /// Still refreshed and shown in the popover, just left out of the menu bar title.
    public private(set) var hiddenFromMenuBar: Set<ProviderKind>

    public static let `default` = ProviderSettings(order: ProviderKind.allCases, disabled: [])

    public init(
        order: [ProviderKind],
        disabled: Set<ProviderKind>,
        hiddenFromMenuBar: Set<ProviderKind> = []
    ) {
        self.hiddenFromMenuBar = hiddenFromMenuBar
        // Every provider appears exactly once, so one the stored order predates still shows up.
        var seen = Set<ProviderKind>()
        let known = order.filter { seen.insert($0).inserted }
        self.order = known + ProviderKind.allCases.filter { !seen.contains($0) }
        self.disabled = disabled
    }

    public var enabledInOrder: [ProviderKind] {
        order.filter { !disabled.contains($0) }
    }

    public func isEnabled(_ provider: ProviderKind) -> Bool {
        !disabled.contains(provider)
    }

    public var menuBarInOrder: [ProviderKind] {
        enabledInOrder.filter { !hiddenFromMenuBar.contains($0) }
    }

    public func showsInMenuBar(_ provider: ProviderKind) -> Bool {
        !hiddenFromMenuBar.contains(provider)
    }

    public mutating func setShowsInMenuBar(_ shows: Bool, for provider: ProviderKind) {
        if shows { hiddenFromMenuBar.remove(provider) } else { hiddenFromMenuBar.insert(provider) }
    }

    public mutating func setEnabled(_ enabled: Bool, for provider: ProviderKind) {
        if enabled { disabled.remove(provider) } else { disabled.insert(provider) }
    }

    public mutating func move(_ provider: ProviderKind, by offset: Int) {
        guard let index = order.firstIndex(of: provider) else { return }
        let target = min(max(index + offset, 0), order.count - 1)
        guard target != index else { return }
        order.remove(at: index)
        order.insert(provider, at: target)
    }
}

public struct AppSettings: Equatable, Sendable {
    public var providers: ProviderSettings

    public static let `default` = AppSettings(providers: .default)

    public init(providers: ProviderSettings) {
        self.providers = providers
    }
}

extension AppSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case providerOrder
        case disabledProviders
        case menuBarHiddenProviders
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Raw strings, so a provider removed in a later version is skipped instead of failing
        // the whole decode and resetting every setting.
        let order = (try container.decodeIfPresent([String].self, forKey: .providerOrder) ?? [])
            .compactMap(ProviderKind.init(rawValue:))
        let disabled = (try container.decodeIfPresent([String].self, forKey: .disabledProviders) ?? [])
            .compactMap(ProviderKind.init(rawValue:))
        let hidden = (try container.decodeIfPresent([String].self, forKey: .menuBarHiddenProviders) ?? [])
            .compactMap(ProviderKind.init(rawValue:))
        self.init(providers: ProviderSettings(
            order: order,
            disabled: Set(disabled),
            hiddenFromMenuBar: Set(hidden)
        ))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(providers.order.map(\.rawValue), forKey: .providerOrder)
        try container.encode(
            providers.disabled.map(\.rawValue).sorted(),
            forKey: .disabledProviders
        )
        try container.encode(
            providers.hiddenFromMenuBar.map(\.rawValue).sorted(),
            forKey: .menuBarHiddenProviders
        )
    }
}

/// Read from the refresh loop off the main actor as well as from the UI, hence the lock.
public protocol AppSettingsStoring: Sendable {
    var current: AppSettings { get }
    func save(_ settings: AppSettings)
}

public final class InMemoryAppSettingsStore: AppSettingsStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppSettings

    public init(_ settings: AppSettings = .default) {
        value = settings
    }

    public var current: AppSettings { lock.withLock { value } }

    public func save(_ settings: AppSettings) {
        lock.withLock { value = settings }
    }
}

public final class UserDefaultsAppSettingsStore: AppSettingsStoring, @unchecked Sendable {
    private static let key = "settings.app"
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var value: AppSettings

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        value = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? .default
    }

    public var current: AppSettings { lock.withLock { value } }

    public func save(_ settings: AppSettings) {
        lock.withLock {
            value = settings
            if let data = try? JSONEncoder().encode(settings) {
                defaults.set(data, forKey: Self.key)
            }
        }
    }
}
