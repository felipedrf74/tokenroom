import Foundation
import ServiceManagement

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case percents
    case meters
    case highest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .percents: "Percents"
        case .meters: "Meters"
        case .highest: "Most urgent only"
        }
    }
}

@Observable
final class AppSettings {
    var enabled: Set<Provider> {
        didSet { persist() }
    }

    var refreshMinutes: Int {
        didSet { persist() }
    }

    var menuStyle: MenuBarStyle {
        didSet { persist() }
    }

    var popoverStyle: PopoverStyle {
        didSet { persist() }
    }

    var hiddenFromMenuBar: Set<Provider> {
        didSet { persist() }
    }

    var budgets: [Provider: Double] {
        didSet { persist() }
    }

    private(set) var budgetReferences: [Provider: BudgetReference] {
        didSet { persist() }
    }

    var launchAtLogin: Bool {
        didSet { applyLaunchAtLogin() }
    }

    var showsAlertsOnMac: Bool {
        didSet { persist() }
    }

    var newsEnabled: Bool {
        didSet { persist() }
    }

    var alertPreferences: AlertPreferences {
        didSet { persist() }
    }

    var followedTimeZone: String? {
        get { defaults.string(forKey: Keys.followedTimeZone) }
        set { defaults.set(newValue, forKey: Keys.followedTimeZone) }
    }

    private var applyingLogin = false

    var refreshInterval: TimeInterval {
        TimeInterval(refreshMinutes * 60)
    }

    private let defaults: UserDefaults
    private var isReady = false
    @ObservationIgnored private var foreign = ForeignChoices()

    private struct ForeignChoices {
        var enabled: [String] = []
        var known: [String] = []
        var hidden: [String] = []
        var budgets: [String: Double] = [:]
        var budgetReferences: [String: Any] = [:]
    }
    private(set) var newlyKnown: [Provider] = []

    enum Keys {
        static let version = "settingsVersion"
        static let enabled = "enabledProviders"
        static let known = "knownProviders"
        static let refreshMinutes = "refreshMinutes"
        static let menuStyle = "menuStyle"
        static let popoverStyle = "popoverStyle"
        static let hiddenFromMenuBar = "menuBarHidden"
        static let budgets = "budgets"
        static let budgetReferences = BudgetReferencePreferences.referencesKey
        static let alertsOnMac = "alertsOnMac"
        static let newsEnabled = "newsEnabled"
        static let alertPreferences = "alertPreferences"
        static let followedTimeZone = "followedTimeZone"
    }

    static let currentVersion = 2

    init(defaults: UserDefaults = .standard, detectsSession: (Provider) -> Bool = { _ in false }) {
        self.defaults = defaults
        enabled = Self.resolveEnabled(defaults: defaults, detectsSession: detectsSession)
        newlyKnown = Self.unknownProviders(defaults: defaults)
        let minutes = defaults.object(forKey: Keys.refreshMinutes) as? Int ?? 10
        refreshMinutes = [5, 10, 15, 30].contains(minutes) ? minutes : 10
        if let raw = defaults.string(forKey: Keys.menuStyle), let style = MenuBarStyle(rawValue: raw) {
            menuStyle = style
        } else {
            menuStyle = .meters
        }
        popoverStyle = defaults.string(forKey: Keys.popoverStyle).flatMap(PopoverStyle.init(rawValue:)) ?? .orbit
        hiddenFromMenuBar = Set((defaults.array(forKey: Keys.hiddenFromMenuBar) as? [String] ?? []).compactMap(Provider.init(rawValue:)))
        var budgets: [Provider: Double] = [:]
        for (key, value) in defaults.dictionary(forKey: Keys.budgets) as? [String: Double] ?? [:] {
            if let provider = Provider(rawValue: key), value.isFinite, value > 0 {
                budgets[provider] = value
            }
        }
        self.budgets = budgets
        budgetReferences = Dictionary(uniqueKeysWithValues: budgets.keys.compactMap { provider in
            BudgetReferencePreferences.reference(in: defaults, for: provider).map { (provider, $0) }
        })
        showsAlertsOnMac = defaults.bool(forKey: Keys.alertsOnMac)
        newsEnabled = defaults.bool(forKey: Keys.newsEnabled)
        alertPreferences = defaults.data(forKey: Keys.alertPreferences)
            .flatMap { try? RelayEnvelope.decoder.decode(AlertPreferences.self, from: $0) } ?? AlertPreferences()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        foreign = ForeignChoices(
            enabled: Self.foreignIDs(defaults.array(forKey: Keys.enabled)),
            known: Self.foreignIDs(defaults.array(forKey: Keys.known)),
            hidden: Self.foreignIDs(defaults.array(forKey: Keys.hiddenFromMenuBar)),
            budgets: (defaults.dictionary(forKey: Keys.budgets) as? [String: Double] ?? [:]).filter { Provider(rawValue: $0.key) == nil },
            budgetReferences: (defaults.dictionary(forKey: Keys.budgetReferences) ?? [:]).filter { key, _ in
                guard let provider = Provider(rawValue: key) else { return true }
                return budgetReferences[provider] == nil
            }
        )
        isReady = true
        persist()
    }

    func budget(for provider: Provider) -> Double? {
        budgets[provider]
    }

    func budgetReference(for provider: Provider) -> BudgetReference? {
        guard let reference = budgetReferences[provider], reference.isValid,
              budgets[provider] == reference.amount else { return nil }
        return reference
    }

    func setBudget(_ value: Double?, for provider: Provider, unit: String = "usd") {
        if let value, (!value.isFinite || value <= 0) { return }
        if let value, !BudgetReference(amount: value, unit: unit).isValid { return }
        foreign.budgetReferences[provider.rawValue] = nil
        if let value {
            budgets[provider] = value
            budgetReferences[provider] = BudgetReference(amount: value, unit: unit)
        } else {
            budgets.removeValue(forKey: provider)
            budgetReferences.removeValue(forKey: provider)
        }
    }

    func showsInMenuBar(_ provider: Provider) -> Bool {
        !hiddenFromMenuBar.contains(provider)
    }

    func setShowsInMenuBar(_ provider: Provider, _ isOn: Bool) {
        if isOn {
            hiddenFromMenuBar.remove(provider)
        } else {
            hiddenFromMenuBar.insert(provider)
        }
    }

    private static func resolveEnabled(defaults: UserDefaults, detectsSession: (Provider) -> Bool) -> Set<Provider> {
        let saved = (defaults.array(forKey: Keys.enabled) as? [String]).map {
            Set($0.compactMap(Provider.init(rawValue:)))
        }
        let known: Set<Provider>
        if defaults.integer(forKey: Keys.version) >= 2 {
            known = Set((defaults.array(forKey: Keys.known) as? [String] ?? []).compactMap(Provider.init(rawValue:)))
        } else if saved != nil {
            known = Provider.legacy
        } else {
            known = []
        }
        var enabled = saved ?? []
        for provider in Provider.allCases where !known.contains(provider) {
            guard provider.category != .orgSpend else { continue }
            if provider.enabledByDefault || detectsSession(provider) {
                enabled.insert(provider)
            }
        }
        return enabled
    }

    private static func foreignIDs(_ saved: [Any]?) -> [String] {
        (saved as? [String] ?? []).filter { Provider(rawValue: $0) == nil }
    }

    private static func unknownProviders(defaults: UserDefaults) -> [Provider] {
        if defaults.integer(forKey: Keys.version) >= 2 {
            let known = Set((defaults.array(forKey: Keys.known) as? [String] ?? []).compactMap(Provider.init(rawValue:)))
            return Provider.allCases.filter { !known.contains($0) }
        }
        if defaults.array(forKey: Keys.enabled) != nil {
            return Provider.allCases.filter { !Provider.legacy.contains($0) }
        }
        return Provider.allCases
    }

    func enableDetected(_ providers: Set<Provider>) {
        for provider in newlyKnown where providers.contains(provider) && provider.category != .orgSpend {
            enabled.insert(provider)
        }
        newlyKnown = []
    }

    func isEnabled(_ provider: Provider) -> Bool {
        enabled.contains(provider)
    }

    func setEnabled(_ provider: Provider, _ isOn: Bool) {
        if isOn {
            enabled.insert(provider)
        } else {
            enabled.remove(provider)
        }
    }

    private func persist() {
        guard isReady else { return }
        defaults.set(Self.currentVersion, forKey: Keys.version)
        defaults.set((enabled.map(\.rawValue) + foreign.enabled).sorted(), forKey: Keys.enabled)
        defaults.set((Provider.allCases.map(\.rawValue) + foreign.known).sorted(), forKey: Keys.known)
        defaults.set(refreshMinutes, forKey: Keys.refreshMinutes)
        defaults.set(menuStyle.rawValue, forKey: Keys.menuStyle)
        defaults.set(popoverStyle.rawValue, forKey: Keys.popoverStyle)
        defaults.set((hiddenFromMenuBar.map(\.rawValue) + foreign.hidden).sorted(), forKey: Keys.hiddenFromMenuBar)
        defaults.set(Dictionary(uniqueKeysWithValues: budgets.map { ($0.key.rawValue, $0.value) }).merging(foreign.budgets) { mine, _ in mine }, forKey: Keys.budgets)
        defaults.set(Dictionary(uniqueKeysWithValues: budgetReferences.map { ($0.key.rawValue, $0.value.propertyList as Any) })
            .merging(foreign.budgetReferences) { mine, _ in mine }, forKey: Keys.budgetReferences)
        defaults.set(showsAlertsOnMac, forKey: Keys.alertsOnMac)
        defaults.set(newsEnabled, forKey: Keys.newsEnabled)
        if let data = try? RelayEnvelope.encoder.encode(alertPreferences) {
            defaults.set(data, forKey: Keys.alertPreferences)
        }
    }

    private func applyLaunchAtLogin() {
        guard !applyingLogin else { return }
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            applyingLogin = true
            launchAtLogin = SMAppService.mainApp.status == .enabled
            applyingLogin = false
        }
    }
}
