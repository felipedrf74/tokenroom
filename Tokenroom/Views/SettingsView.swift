import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general
    case providers
    case keys
    case alerts
    case news
    case menuBar
    case iPhone
}

/// Which tab Settings shows; the app sets it before opening Settings from elsewhere.
@Observable
@MainActor
final class SettingsTabRequest {
    var tab: SettingsTab = .providers
}

struct SettingsView: View {
    @Bindable var store: QuotaStore
    @Bindable var request: SettingsTabRequest
    @State private var search = ""
    @FocusState private var sidebarFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { request.tab }, set: { if let tab = $0 { request.tab = tab } })) {
                ForEach(SettingsPage.groups, id: \.title) { group in
                    let pages = group.pages.filter { $0.tab != .iPhone || store.relay != nil }.filter { $0.matches(search) }
                    if !pages.isEmpty {
                        Section(group.title) {
                            ForEach(pages) { page in
                                Label {
                                    Text(page.title)
                                } icon: {
                                    SettingsIcon(symbol: page.symbol, tint: page.tint)
                                }
                                .tag(page.tab)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            // The keyboard starts here, as in System Settings: left alone, the window gives it to
            // the page's first text field, which then opens with a caret or its text selected.
            .focused($sidebarFocused)
            .defaultFocus($sidebarFocused, true)
            .searchable(text: $search, placement: .sidebar, prompt: "Search settings")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            let page = SettingsPage.page(for: request.tab)
            content(for: request.tab)
                .environment(\.settingsHeader, SettingsHeaderInfo(page: page, summary: summary(for: request.tab)))
        }
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560)
        .navigationTitle(SettingsPage.page(for: request.tab).title)
        .onChange(of: store.pendingKeyProvider, initial: true) { _, provider in
            if provider != nil {
                request.tab = .keys
            }
        }
        .onChange(of: search) { _, text in
            // Jump to the first page that matches, as System Settings does.
            if !text.isEmpty, let first = SettingsPage.groups.flatMap(\.pages).first(where: { $0.matches(text) && ($0.tab != .iPhone || store.relay != nil) }) {
                request.tab = first.tab
            }
        }
    }

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings(store: store)
        case .providers: ProvidersSettings(store: store) { request.tab = .keys }
        case .keys: KeysSettings(store: store)
        case .alerts: AlertsSettings(store: store)
        case .news: NewsSettings(store: store)
        case .menuBar: MenuBarSettings(store: store)
        case .iPhone:
            // The app always has a relay; only tests and captures run without one, and the sidebar
            // hides the page then. The form stays, so the pane is never bare.
            Form {
                SettingsHeaderSection()
                if let relay = store.relay {
                    RelaySettingsSection(relay: relay)
                }
            }
            .formStyle(.grouped)
        }
    }

    /// A short count on the page's header card, like "9 of 17 on".
    private func summary(for tab: SettingsTab) -> String? {
        switch tab {
        case .providers:
            let personal = Provider.allCases.filter { $0.category != .orgSpend }
            return "\(personal.filter { store.settings.isEnabled($0) }.count) of \(personal.count) on"
        case .news, .menuBar:
            // Their first control already says so.
            return nil
        case .iPhone:
            guard let relay = store.relay else { return nil }
            switch relay.state {
            case .unavailable: return "Unavailable"
            case .off: return "Off"
            case .waiting: return "Waiting for readings"
            case .noAccount: return "Sign in to iCloud"
            case .sent: return nil
            case .failed: return "Couldn't sync"
            case .paused: return "Paused"
            }
        case .alerts:
            switch (store.settings.showsAlertsOnMac, store.sendsAlertsToiCloud) {
            case (true, true): return "On this Mac and iPhone"
            case (false, true): return "On iPhone"
            case (true, false): return "On this Mac"
            case (false, false): return "Off on this Mac"
            }
        case .general, .keys:
            return nil
        }
    }
}

/// One page in the Settings sidebar: its symbol tile, title, the line under the header, and the
/// words search finds it by.
struct SettingsPage: Identifiable {
    var tab: SettingsTab
    var title: String
    var symbol: String
    var tint: Color
    var text: String
    var keywords: [String] = []

    var id: SettingsTab { tab }

    func matches(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return ([title, text] + keywords).contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static let groups: [(title: String, pages: [SettingsPage])] = [
        ("Essentials", [
            SettingsPage(tab: .general, title: "General", symbol: "gearshape.fill", tint: .gray,
                         text: "Start with your Mac, and about Tokenroom.", keywords: ["launch", "login", "version", "privacy", "headroom"]),
            SettingsPage(tab: .menuBar, title: "Menu Bar", symbol: "menubar.rectangle", tint: .blue,
                         text: "How usage looks in the menu bar, how often it's checked, and which providers show there.", keywords: ["meters", "percents", "refresh", "style"]),
        ]),
        ("Usage", [
            SettingsPage(tab: .providers, title: "Providers", symbol: "square.stack.3d.up.fill", tint: .indigo,
                         text: "The plans and tools Tokenroom reads, with the logins already on this Mac.",
                         keywords: Provider.allCases.map(\.displayName) + ["sign in", "enable"]),
            SettingsPage(tab: .keys, title: "API Keys", symbol: "key.fill", tint: .gray,
                         text: "Coding plans, balances, and organization spend, read with keys that stay in this Mac's Keychain.",
                         keywords: Provider.allCases.filter(\.readsWithKey).map(\.displayName) + ["token", "budget", "reference"]),
            SettingsPage(tab: .alerts, title: "Alerts", symbol: "bell.badge.fill", tint: .red,
                         text: "When to hear about a limit, a reset, or a balance. Shared with your iPhone.", keywords: ["notifications", "quiet hours", "threshold"]),
        ]),
        ("More", [
            SettingsPage(tab: .news, title: "News", symbol: "newspaper.fill", tint: .pink,
                         text: "New models and official announcements from the labs and tools you follow.", keywords: ["models", "labs", "feeds", "changelog"]),
            SettingsPage(tab: .iPhone, title: "iPhone & Watch", symbol: "iphone.gen3", tint: .green,
                         text: "Readings for Tokenroom on your iPhone and Apple Watch, through your iCloud.", keywords: ["icloud", "sync", "watch", "relay"]),
        ]),
    ]

    static func page(for tab: SettingsTab) -> SettingsPage {
        groups.flatMap(\.pages).first { $0.tab == tab } ?? groups[0].pages[0]
    }
}

/// A white symbol on a rounded tile, as System Settings draws its sidebar.
struct SettingsIcon: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(tint.gradient))
            .accessibilityHidden(true)
    }
}

/// The top of a Settings page: its tile, title, what it's for, and a short count. No card of its
/// own: the window's title and the sidebar already name the page, and the groups below are the
/// boxes. Its edge is theirs.
private struct SettingsPageHeader: View {
    var page: SettingsPage
    var summary: String?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsIcon(symbol: page.symbol, tint: page.tint, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(page.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(page.text)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let summary {
                SettingsTag(text: summary)
            }
        }
    }
}

struct SettingsHeaderInfo {
    var page: SettingsPage
    var summary: String?
}

private struct SettingsHeaderKey: EnvironmentKey {
    static let defaultValue: SettingsHeaderInfo? = nil
}

extension EnvironmentValues {
    /// The page header the Settings window puts at the top of each page's form.
    var settingsHeader: SettingsHeaderInfo? {
        get { self[SettingsHeaderKey.self] }
        set { self[SettingsHeaderKey.self] = newValue }
    }
}

/// The first section of every Settings page: its header, scrolling with the page, and anything
/// that belongs to the whole page, such as its search field.
struct SettingsHeaderSection<Accessory: View>: View {
    @Environment(\.settingsHeader) private var header
    private var accessory: Accessory

    init(@ViewBuilder accessory: () -> Accessory) {
        self.accessory = accessory()
    }

    var body: some View {
        if let header {
            Section {
                EmptyView()
            } header: {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsPageHeader(page: header.page, summary: header.summary)
                    accessory
                }
                // A section header sits on the rows' inset; this one takes the group's edge.
                .padding(.horizontal, -10)
                .padding(.bottom, 4)
            }
        }
    }
}

extension SettingsHeaderSection where Accessory == EmptyView {
    init() {
        accessory = EmptyView()
    }
}

/// A section's title. Under `SettingsHeaderSection`, a group draws its header small and tight
/// against the page's: these match the titles further down, with their air.
struct SettingsSectionTitle: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.headline)
            .foregroundStyle(.primary)
            .padding(.top, 10)
    }
}

/// The small capsule on a page's header: "11 of 16 on".
struct SettingsTag: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .fixedSize()
    }
}

/// AppKit's search field: the leading magnifier, the clear button, and Escape to clear. A
/// `TextField` in a grouped form reads as a row label with a stray caret.
private struct SettingsSearchField: NSViewRepresentable {
    var prompt: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = Field()
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        // Every keystroke, and the clear button, arrive as this one action.
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    /// An opening window offers its first text field the keyboard, which would start the page with
    /// a caret here. A click, Tab, or VoiceOver takes it.
    private final class Field: NSSearchField {
        override func becomeFirstResponder() -> Bool {
            let asked = NSWorkspace.shared.isVoiceOverEnabled
                || NSApp.currentEvent.map { [.leftMouseDown, .keyDown].contains($0.type) } == true
            return asked && super.becomeFirstResponder()
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        @objc func changed(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }
    }
}

/// The rest of an explanation, one click away, so a page's scanning path keeps one concise line.
private struct SettingsDetails: View {
    var title: String
    var text: String

    var body: some View {
        DisclosureGroup(title) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @Bindable var store: QuotaStore

    var body: some View {
        Form {
            SettingsHeaderSection()
            Section {
                Toggle("Launch at login", isOn: $store.settings.launchAtLogin)
            }
            if let legacy = LegacyMigration.legacyAppURL {
                Section {
                    Text("Headroom is still on this Mac. Quit it, remove it from Login Items in System Settings › General, and move it to the Trash.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        if LegacyMigration.isLegacyAppRunning {
                            Button("Quit Headroom") { store.quitLegacyApp() }
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([legacy])
                        }
                    }
                } header: {
                    Text("Headroom")
                }
            }
            Section {
                LabeledContent("Version", value: TokenroomIdentity.version)
                Link("Privacy", destination: TokenroomIdentity.privacyURL)
                Link("Source code", destination: TokenroomIdentity.repositoryURL)
            } header: {
                Text("About")
            } footer: {
                Text("Tokenroom isn't affiliated with any of the providers it shows.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Providers

private struct ProvidersSettings: View {
    @Bindable var store: QuotaStore
    var onManageKeys: () -> Void
    /// Providers signed in or configured on this Mac, checked off the main thread.
    @State private var detected: Set<Provider> = []
    @State private var search = ""

    /// Said once on the page rather than as a tag on nearly every row, under the first section
    /// that has such a provider; each row's tooltip and VoiceOver label say it too.
    private static let unofficialNote = "Tools you sign in to are read from the same endpoints their own apps use: unofficial, and they can change without notice."

    var body: some View {
        Form {
            SettingsHeaderSection {
                SettingsSearchField(prompt: "Search providers", text: $search)
            }
            let personal = Provider.allCases.filter { $0.category != .orgSpend && matches($0.displayName) }
            let connected = personal.filter { store.settings.isEnabled($0) }
            let detectedOff = personal.filter { !store.settings.isEnabled($0) && detected.contains($0) }
            let available = personal.filter { !store.settings.isEnabled($0) && !detected.contains($0) }
            let orgSpend = Provider.allCases.filter { $0.category == .orgSpend && matches($0.displayName) }
            let unofficialSection = [connected, detectedOff, available].first { $0.contains(where: \.isUnofficial) }

            if !connected.isEmpty {
                Section {
                    ForEach(connected) { providerRow($0) }
                    SettingsDetails(title: "How sign-ins work", text: "Claude, Grok Build, and Codex access tokens expire after a few hours; Tokenroom renews them in that tool's own login, so you stay signed in. It doesn't keep a copy of the token. Names and emails are never stored or sent anywhere.")
                } header: {
                    SettingsSectionTitle("Enabled")
                } footer: {
                    Text(footnote("Tokenroom uses the login you already have.", unofficial: connected == unofficialSection))
                }
            }
            if !detectedOff.isEmpty {
                Section {
                    ForEach(detectedOff) { providerRow($0) }
                } header: {
                    SettingsSectionTitle("Detected on this Mac")
                } footer: {
                    Text(footnote("Signed in or set up on this Mac. Turn one on to see its usage.", unofficial: detectedOff == unofficialSection))
                }
            }
            if !available.isEmpty {
                Section {
                    ForEach(available) { providerRow($0) }
                } header: {
                    SettingsSectionTitle("Available")
                } footer: {
                    if available == unofficialSection {
                        Text(Self.unofficialNote)
                    }
                }
            }
            // A grouped form draws a section's header and footer even with no rows left.
            if !orgSpend.isEmpty {
                Section {
                    ForEach(orgSpend) { providerRow($0) }
                } header: {
                    SettingsSectionTitle("Organization billing")
                } footer: {
                    Text("Month-to-date spend with an admin or management key. These never turn on by themselves; add a dedicated key you can revoke in API Keys.")
                }
            }
        }
        .formStyle(.grouped)
        .task {
            #if DEBUG
            if UserDefaults.standard.string(forKey: "TokenroomSnapshots") != nil { return }
            #endif
            detected = await BlockingIO.run {
                Set(Provider.allCases.filter { CredentialReaders.hasSession($0) })
            }
        }
    }

    private func footnote(_ text: String, unofficial: Bool) -> String {
        unofficial ? "\(text) \(Self.unofficialNote)" : text
    }

    private func providerRow(_ provider: Provider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                providerLabel(provider)
                Spacer(minLength: 8)
                rowActions(provider)
                providerToggle(provider)
            }
            if provider == .claude {
                DisclosureGroup("Advanced") {
                    ClaudeBridgeRow()
                    Text("Unofficial: read from the same endpoint \(provider.toolName) uses. It can change without notice.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
    }

    private func matches(_ name: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search)
    }

    private func needsKey(_ provider: Provider) -> Bool {
        guard store.settings.isEnabled(provider) else { return false }
        if case .signedOut = store.statuses[provider] ?? .loading { return true }
        return false
    }

    private func providerLabel(_ provider: Provider) -> some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: provider, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                Text(caption(provider))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(provider.isUnofficial ? "Unofficial: read from the same endpoint \(provider.toolName) uses. It can change without notice." : "")
        // The switch speaks for the whole row.
        .accessibilityHidden(true)
    }

    private func providerToggle(_ provider: Provider) -> some View {
        Toggle(isOn: Binding(
            get: { store.settings.isEnabled(provider) },
            // Through the store: one turned on is checked now, and iCloud hears of either.
            set: { store.setEnabled(provider, $0) }
        )) {
            Text(provider.displayName)
        }
        .labelsHidden()
        .toggleStyle(.switch)
        // The caption goes in the label: as the value it would replace the switch's on or off.
        .accessibilityLabel("\(provider.displayName), \(caption(provider))\(provider.isUnofficial ? ", unofficial source" : "")")
    }

    /// How a row connects, when that isn't what the section's note says: nearly every provider
    /// is a login read unofficially, so only the others say anything.
    private func connection(_ provider: Provider) -> String? {
        switch provider.access {
        case .localLogin: provider.descriptor.fallbackKey == nil ? nil : "Login or token"
        case .codingPlanKey: "Key"
        case .pastedKey: provider.category == .orgSpend ? "Admin key" : "Key"
        }
    }

    private func caption(_ provider: Provider) -> String {
        let connection = connection(provider)
        if store.settings.isEnabled(provider) {
            return [store.accountCaption(provider), connection].compactMap(\.self).joined(separator: " · ")
        }
        if detected.contains(provider) {
            return provider.usesAPIKey ? "Key found on this Mac" : "Signed in on this Mac"
        }
        if provider.usesAPIKey {
            return provider.category == .orgSpend ? "Needs an admin key" : "Needs an API key"
        }
        return ["Sign in with \(provider.installToolName)", connection].compactMap(\.self).joined(separator: " · ")
    }

    /// What a row needs next, beside its switch rather than under it, so it stays one row tall.
    @ViewBuilder
    private func rowActions(_ provider: Provider) -> some View {
        if provider.usesAPIKey {
            if needsKey(provider) {
                Button("Add Key…", action: onManageKeys)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Add a key in API Keys")
                    .accessibilityLabel("Add a \(provider.displayName) key in API Keys")
            }
        } else {
            signInActions(provider)
        }
    }

    @ViewBuilder
    private func signInActions(_ provider: Provider) -> some View {
        let status = store.statuses[provider] ?? .loading
        let needsSignIn: Bool = {
            guard store.settings.isEnabled(provider) else { return false }
            switch status {
            case .signedOut, .expired, .unreachable(nil):
                return true
            default:
                return false
            }
        }()
        if store.signIn.isWorking(provider) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for \(provider.installToolName)…")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Cancel") {
                    store.signIn.cancel()
                }
                .buttonStyle(.plain)
            }
        } else if case .needsInstall(let active, let tool, _) = store.signIn.phase, active == provider {
            HStack(spacing: 8) {
                Button("Install \(tool)") {
                    store.signIn.openInstallPage(provider)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Try Again") {
                    store.signIn.signIn(provider)
                }
                .buttonStyle(.plain)
            }
        } else if needsSignIn {
            Button(provider.signInTitle) {
                store.signIn.signIn(provider)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(provider.signInHint)
            .accessibilityLabel("\(provider.signInTitle), \(provider.displayName)")
        }
    }
}

// MARK: API keys

private struct KeysSettings: View {
    @Bindable var store: QuotaStore
    @State private var keySheet: Provider?
    /// Counts closed key sheets; rows read their key again when it changes.
    @State private var closedSheets = 0
    @State private var budgetRegions: [Provider: String] = [:]
    @State private var budgetClears: [Provider: Int] = [:]

    var body: some View {
        Form {
            SettingsHeaderSection()
            Section {
                ForEach(Provider.allCases.filter { $0.access == .codingPlanKey }) { provider in
                    KeyRow(provider: provider, keys: CredentialReaders.apiKeys, reload: closedSheets, isEnabled: store.settings.isEnabled(provider)) {
                        keyHeader(provider)
                    } onAdd: {
                        keySheet = provider
                    } onRemoved: {
                        // A key the coding tool keeps may still be there.
                        Task { await store.credentialsChanged(for: provider) }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                SettingsSectionTitle("Coding plans")
            } footer: {
                Text("Tokenroom uses the key your coding tool already has on this Mac (Claude Code settings, the kimi CLI, or OpenCode), or one you add here. Added keys stay in this Mac's Keychain.")
            }

            Section {
                ForEach(Provider.allCases.filter { $0.descriptor.fallbackKey != nil }) { provider in
                    KeyRow(provider: provider, keys: CredentialReaders.apiKeys, reload: closedSheets, isEnabled: store.settings.isEnabled(provider)) {
                        keyHeader(provider)
                    } onAdd: {
                        keySheet = provider
                    } onRemoved: {
                        Task { await store.credentialsChanged(for: provider) }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("Official APIs")
            } footer: {
                Text("Used when the app's own login is missing or refused: GitHub's documented billing API reads Copilot's AI credits with a fine-grained token.")
            }

            Section {
                ForEach(Provider.allCases.filter { $0.category == .apiBalance }) { provider in
                    keyedProvider(provider, budgetLabel: "Reference")
                }
            } header: {
                Text("Pay as you go")
            } footer: {
                Text("API keys stay in this Mac's Keychain. They're never synced or sent to your iPhone; only the readings are. A reference amount in the key's currency turns a balance into a meter.")
            }

            Section {
                ForEach(Provider.allCases.filter { $0.category == .orgSpend }) { provider in
                    keyedProvider(provider, budgetLabel: "Monthly budget")
                }
            } header: {
                Text("Organization billing")
            } footer: {
                Text("Admin and management keys can change your organization. Tokenroom only reads cost and billing with them. Create a dedicated key you can revoke.")
            }
        }
        .formStyle(.grouped)
        .sheet(item: $keySheet, onDismiss: { closedSheets += 1 }) { provider in
            AddKeySheet(provider: provider, keys: CredentialReaders.apiKeys) {
                store.settings.setEnabled(provider, true)
                // Checked now, not after the old key's spacing or a 429 it earned.
                Task { await store.credentialsChanged(for: provider) }
            }
        }
        .onChange(of: store.pendingKeyProvider, initial: true) { _, provider in
            guard let provider else { return }
            keySheet = provider
            store.pendingKeyProvider = nil
        }
    }

    private func keyHeader(_ provider: Provider) -> some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: provider, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(provider.displayName)
                Text(store.settings.isEnabled(provider) ? store.accountCaption(provider) : "Off")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func keyedProvider(_ provider: Provider, budgetLabel: String) -> some View {
        let unit = store.budgetUnit(for: provider, region: budgetRegions[provider])
        let reference = store.settings.budgetReference(for: provider)
        return VStack(alignment: .leading, spacing: 8) {
            KeyRow(provider: provider, keys: CredentialReaders.apiKeys, reload: closedSheets, isEnabled: store.settings.isEnabled(provider),
                   onMetadata: { metadata in
                       budgetRegions[provider] = metadata.map { provider.keySpec?.initialChoice(saved: $0) ?? "" }
                   }) {
                keyHeader(provider)
            } onAdd: {
                keySheet = provider
            } onRemoved: {
                store.setEnabled(provider, false)
            }
            BudgetField(label: budgetLabel, currency: unit.uppercased(), resetRevision: budgetClears[provider, default: 0], value: Binding(
                get: { store.settings.budgetReference(for: provider).flatMap { $0.unit == unit ? $0.amount : nil } },
                set: { value in
                    store.settings.setBudget(value, for: provider, unit: unit)
                    store.budgetDidChange(for: provider)
                }
            ))
            .padding(.leading, 28)
            if let reference, reference.unit != unit {
                Text("Saved reference: \(AmountFormat.text(reference.amount, unit: reference.unit)). Enter a new \(unit.uppercased()) amount to replace it; the saved amount only meters \(reference.unit.uppercased()) balances.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
            } else if let previous = store.settings.budget(for: provider), reference == nil {
                Text("Previous reference: \(previous.formatted(.number)) (currency unknown). Enter it again in \(unit.uppercased()) to activate it.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 28)
            }
            if store.settings.budget(for: provider) != nil, reference?.unit != unit {
                Button("Clear Saved Reference", role: .destructive) {
                    store.settings.setBudget(nil, for: provider, unit: unit)
                    store.budgetDidChange(for: provider)
                    budgetClears[provider, default: 0] += 1
                }.buttonStyle(.plain).font(.caption).padding(.leading, 28)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A provider's row of keys: its name, then `•••• a1b2` with Replace and Remove, or Add Key, on the
/// trailing edge. Warnings and messages stay under it.
private struct KeyRow<RowLabel: View>: View {
    var provider: Provider
    var keys: APIKeyStore
    /// Changes when a key sheet closes, so a key saved there shows.
    var reload = 0
    /// Only sample captures read this: they show a key on what's turned on, and touch no Keychain.
    var isEnabled = false
    var onMetadata: ((APIKeyStore.Metadata?) -> Void)? = nil
    @ViewBuilder var label: () -> RowLabel
    var onAdd: () -> Void
    var onRemoved: () -> Void
    @State private var metadata: APIKeyStore.Metadata?
    @State private var localKey: String?
    @State private var message: String?
    @State private var removing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                label()
                Spacer(minLength: 8)
                if let metadata {
                    Text("•••• \(metadata.last4)\(metadata.region.map { " · \($0)" } ?? "")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Button("Replace…", action: onAdd)
                        .disabled(removing)
                        .accessibilityLabel("Replace \(provider.displayName) key")
                    Button(removing ? "Removing…" : "Remove", role: .destructive) {
                        remove()
                    }
                    .disabled(removing)
                    .accessibilityLabel(removing ? "Removing \(provider.displayName) key" : "Remove \(provider.displayName) key")
                } else {
                    Button("Add Key…", action: onAdd)
                        .accessibilityLabel("Add \(provider.displayName) key")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Group {
                if metadata == nil, let localKey {
                    Text(localKey)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if let warning = metadata?.warning {
                    SettingsWarning(warning)
                }
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 28)
        }
        .task(id: reload) {
            #if DEBUG
            if UserDefaults.standard.string(forKey: "TokenroomSnapshots") != nil {
                metadata = isEnabled ? .init(last4: "a1b2", addedAt: .now) : nil
                return
            }
            #endif
            let keys = self.keys
            let provider = self.provider
            let loaded = await BlockingIO.run { (keys.metadata(for: provider), LocalKeys.settingsCaption(for: provider)) }
            metadata = loaded.0
            onMetadata?(loaded.0)
            localKey = loaded.1
        }
    }

    private func remove() {
        guard !removing else { return }
        removing = true
        message = nil
        let keys = self.keys
        let provider = self.provider
        Task {
            defer { removing = false }
            do {
                try await BlockingIO.run { try keys.remove(for: provider) }
                metadata = nil
                onMetadata?(nil)
                message = nil
                onRemoved()
            } catch {
                message = "Couldn't remove the key from the Keychain."
            }
        }
    }
}

/// A warning in a row: colour belongs to readings, so it's ink, stronger than the captions around it.
private struct SettingsWarning: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An amount in the key's currency; empty means no reference or budget.
private struct BudgetField: View {
    var label: String
    var currency: String
    var resetRevision = 0
    @Binding var value: Double?
    @State private var text = ""
    @State private var error: String?
    @State private var edited = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(label) (\(currency))").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                TextField("None", text: Binding(get: { text }, set: { text = $0; edited = true }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 11)).frame(width: 110)
                    .focused($focused).onSubmit(save)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { text = value.map { $0.formatted(.number.grouping(.never)) } ?? "" }
        .onChange(of: currency) { _, _ in
            text = value.map { $0.formatted(.number.grouping(.never)) } ?? ""
            edited = false
            error = nil
        }
        .onChange(of: resetRevision) { _, _ in
            text = value.map { $0.formatted(.number.grouping(.never)) } ?? ""
            edited = false
            error = nil
        }
        .onChange(of: focused) { _, focused in if !focused { save() } }
        .onDisappear(perform: save)
    }

    private func save() {
        guard edited else { return }
        switch BudgetInput.parse(text) {
        case .clear: error = nil; value = nil; edited = false
        case .amount(let amount): error = nil; value = amount; edited = false
        case .invalid: error = BudgetInput.error
        }
    }
}

/// Paste → Test & Save: one call with the key before it's stored.
private struct AddKeySheet: View {
    var provider: Provider
    var keys: APIKeyStore
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var region: String
    @State private var working = false
    @State private var saving = false
    @State private var validation = KeyValidationRevision()
    @State private var message: String?
    @State private var offerSaveAnyway = false
    @State private var acknowledgedAdmin = false
    /// Set when a test shows the key can change things (an xAI key with write access).
    @State private var warning: String?

    init(provider: Provider, keys: APIKeyStore, onSaved: @escaping () -> Void) {
        self.provider = provider
        self.keys = keys
        self.onSaved = onSaved
        _region = State(initialValue: provider.keySpec?.regions.first ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProviderIcon(provider: provider, size: 28)
                Text("Add \(provider.displayName) \(provider.keySpec?.label ?? "API key")")
                    .font(.headline)
            }
            SecureField(provider.keySpec?.prefixHint.isEmpty == false ? "\(provider.keySpec!.prefixHint)…" : "Paste your key", text: $key)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 320)
                .disabled(saving)
            if let regions = provider.keySpec?.regions, !regions.isEmpty {
                let picker = Picker(provider.keySpec?.choiceLabel ?? "Account", selection: $region) {
                    ForEach(regions, id: \.self) { Text($0).tag($0) }
                }.disabled(saving)
                // Two regions fit side by side; Copilot's seven plans don't fit the sheet that way.
                if regions.count > 2 {
                    picker.pickerStyle(.menu)
                } else {
                    picker.pickerStyle(.segmented)
                }
            }
            if let url = provider.keySpec?.createURL {
                Link(provider.keySpec?.createTitle ?? "Create a key", destination: url)
                    .font(.system(size: 11))
            }
            if let note = provider.keySpec?.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if provider.key?.isAdmin == true {
                VStack(alignment: .leading, spacing: 6) {
                    Text("This is an organization-wide key. It can read and change your organization's settings\(provider == .xaiOrg ? ", billing, and keys" : ""). Tokenroom only reads cost and billing with it, keeps it in this Mac's Keychain, and never sends it to other devices.")
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("I created a dedicated key I can revoke", isOn: $acknowledgedAdmin)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
            }
            if let warning {
                SettingsWarning(warning)
            }
            Text(message ?? "Tokenroom only reads your balance and usage with this key. It stays in this Mac's Keychain.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if offerSaveAnyway {
                    Button("Save Anyway") { Task { await save() } }
                        .disabled(working || (provider.key?.isAdmin == true && !acknowledgedAdmin))
                }
                Button(working ? (saving ? "Saving…" : "Testing…") : (warning == nil ? "Test & Save" : "Save With This Key")) {
                    if warning == nil {
                        test()
                    } else {
                        Task { await save() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working || (provider.key?.isAdmin == true && !acknowledgedAdmin))
            }
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: key) { _, _ in invalidateValidation() }
        .onChange(of: region) { _, _ in invalidateValidation() }
        .onDisappear { invalidateValidation() }
        .task {
            // Replacing a key starts from the choice saved with it, such as its Copilot plan.
            guard let spec = provider.keySpec, !spec.regions.isEmpty else { return }
            let keys = self.keys
            let provider = self.provider
            let saved = await BlockingIO.run { keys.metadata(for: provider) }
            if region == spec.initialChoice(saved: nil) {
                region = spec.initialChoice(saved: saved)
            }
        }
    }

    private var regionValue: String? {
        region.isEmpty ? nil : region
    }

    private var credential: APIKeyCredential {
        APIKeyCredential(key: key.trimmingCharacters(in: .whitespacesAndNewlines), region: regionValue)
    }

    private func invalidateValidation() {
        validation.invalidate()
        warning = nil
        message = nil
        offerSaveAnyway = false
    }

    private func test() {
        guard !working else { return }
        working = true
        message = nil
        warning = nil
        offerSaveAnyway = false
        let attempt = validation.begin(credential)
        Task {
            let result: Result<APIKeyClient.KeyCheck, Error>
            do {
                result = .success(try await APIKeyClient.check(for: provider, key: attempt.credential.key, region: attempt.credential.region))
            } catch { result = .failure(error) }
            working = false
            guard validation.accepts(attempt, current: credential) else { return }
            switch result {
            case .success(let check):
                if let found = check.warning { warning = found }
                else { await save() }
            case .failure(ProviderError.expired):
                message = "Couldn't use this key. Check it and its account, and try again."
            case .failure(ProviderError.notEntitled(let reason)):
                message = reason
            case .failure(ProviderError.unreachable), .failure(ProviderError.rateLimited):
                message = "Couldn't reach \(provider.displayName) to check the key."
                offerSaveAnyway = true
            case .failure:
                message = "Couldn't read \(provider.displayName)'s answer with this key."
                offerSaveAnyway = true
            }
        }
    }

    private func save() async {
        guard !working, provider.key?.isAdmin != true || acknowledgedAdmin,
              let attempt = validation.attempt,
              validation.accepts(attempt, current: credential) else { return }
        working = true
        saving = true
        defer { working = false; saving = false }
        let credential = attempt.credential
        let savedWarning = warning
        do {
            let keys = self.keys
            let provider = self.provider
            try await BlockingIO.run { try keys.save(credential.key, for: provider, region: credential.region, warning: savedWarning) }
            onSaved()
            dismiss()
        } catch {
            message = "Couldn't save the key in the Keychain."
        }
    }

}

// MARK: Alerts

private struct AlertsSettings: View {
    @Bindable var store: QuotaStore
    @State private var denied = false

    private var preferences: AlertPreferences {
        store.settings.alertPreferences
    }

    /// Alerts reach the iPhone only through iCloud; without it, this Mac is the only place.
    private var iPhoneNote: String {
        if store.sendsAlertsToiCloud {
            return "Your iPhone gets these through iCloud either way, once each, whichever device sees them first."
        }
        if store.relay?.isAvailable == true {
            return "Your iPhone gets these only while Send readings to iCloud is on, in iPhone & Watch."
        }
        return "This copy of Tokenroom can't use iCloud, so only this Mac can show these."
    }

    var body: some View {
        Form {
            SettingsHeaderSection()
            Section {
                Toggle("Show alerts on this Mac", isOn: Binding(
                    get: { store.settings.showsAlertsOnMac },
                    set: { isOn in
                        guard isOn else {
                            store.settings.showsAlertsOnMac = false
                            return
                        }
                        Task {
                            let allowed = await MacAlerts.requestPermission()
                            store.settings.showsAlertsOnMac = allowed
                            denied = !allowed
                        }
                    }
                ))
            } header: {
                SettingsSectionTitle("This Mac")
            } footer: {
                Text(denied
                    ? "Notifications are off for Tokenroom. Turn them on in System Settings › Notifications."
                    : iPhoneNote)
            }

            Section {
                ForEach(AlertPreferences.supportedThresholds, id: \.self) { level in
                    Toggle("\(level)% used", isOn: levelBinding(level, \.sessionThresholds))
                }
                Toggle("Before it runs out", isOn: binding(get: \.sessionRunsOut, set: { $0.sessionRunsOut = $1 }))
            } header: {
                Text("5-hour limits")
            } footer: {
                Text("\"Before it runs out\" alerts when the pace would use the limit up before it resets, once at least half is used.")
            }

            Section {
                ForEach(AlertPreferences.supportedThresholds, id: \.self) { level in
                    Toggle("\(level)% used", isOn: levelBinding(level, \.thresholds))
                }
                Toggle("Before it runs out, at least a day early", isOn: binding(get: \.limitRunsOut, set: { $0.limitRunsOut = $1 }))
            } header: {
                Text("Weekly and monthly limits")
            }

            Section {
                Toggle("A busy window resets", isOn: binding(get: \.resets, set: { $0.resets = $1 }))
                Toggle("Banked resets arrive or are about to expire", isOn: binding(get: \.banked, set: { $0.banked = $1 }))
                Toggle("A balance or budget runs low", isOn: binding(get: \.lowBalance, set: { $0.lowBalance = $1 }))
                Toggle("New models from labs you follow", isOn: binding(get: \.newModels, set: { $0.newModels = $1 }))
            } header: {
                Text("Also alert me when")
            } footer: {
                Text("Shared with Tokenroom on your iPhone through iCloud; a change on either device applies to both. Low balance alerts need a reference or budget in API Keys.")
            }

            Section {
                Toggle("Quiet hours", isOn: binding(get: \.quietHours, set: { $0.quietHours = $1 }))
                if preferences.quietHours {
                    Picker("From", selection: binding(get: \.quietStartHour, set: { $0.quietStartHour = $1 })) {
                        ForEach(0..<24, id: \.self) { Text(Self.hourText($0)).tag($0) }
                    }
                    Picker("Until", selection: binding(get: \.quietEndHour, set: { $0.quietEndHour = $1 })) {
                        ForEach(0..<24, id: \.self) { Text(Self.hourText($0)).tag($0) }
                    }
                }
            } footer: {
                Text("Only 95% alerts, limits that run out within the hour, and banked resets about to expire come through. The rest wait until quiet hours end.")
            }
        }
        .formStyle(.grouped)
        .task {
            // Pick up changes made on the iPhone.
            _ = await store.currentAlertPreferences()
        }
    }

    private func binding<Value>(get: @escaping (AlertPreferences) -> Value, set: @escaping (inout AlertPreferences, Value) -> Void) -> Binding<Value> {
        Binding(
            get: { get(store.settings.alertPreferences) },
            set: { value in store.updateAlertPreferences { set(&$0, value) } }
        )
    }

    private func binding<Value>(get keyPath: KeyPath<AlertPreferences, Value>, set: @escaping (inout AlertPreferences, Value) -> Void) -> Binding<Value> {
        binding(get: { $0[keyPath: keyPath] }, set: set)
    }

    /// One level (80, 95) of a list of levels, on or off.
    private func levelBinding(_ level: Int, _ keyPath: WritableKeyPath<AlertPreferences, [Int]>) -> Binding<Bool> {
        binding(
            get: { $0[keyPath: keyPath].contains(level) },
            set: { preferences, isOn in
                var levels = Set(preferences[keyPath: keyPath])
                if isOn { levels.insert(level) } else { levels.remove(level) }
                preferences[keyPath: keyPath] = levels.sorted()
            }
        )
    }

    static func hourText(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: News

private struct NewsSettings: View {
    @Bindable var store: QuotaStore
    @State private var search = ""

    var body: some View {
        Form {
            SettingsHeaderSection()
            Section {
                Toggle("Check for new models and announcements", isOn: Binding(
                    get: { store.settings.newsEnabled },
                    set: { isOn in
                        store.settings.newsEnabled = isOn
                        if isOn {
                            Task { await store.refreshNews(force: true) }
                        }
                    }
                ))
                SettingsDetails(title: "How often it checks", text: "Reads OpenRouter's public model list every hour, and official changelogs and blogs every hour, or every 5 minutes while the News window is on screen. A feed that can't be read is tried again after 5 minutes, then less often, and never sooner than its server asks.")
            } footer: {
                Text("No account, key, or usage is sent. Open News from the popover.")
            }
            if store.settings.newsEnabled, let news = store.news {
                Section {
                    EmptyView()
                } header: {
                    SettingsSearchField(prompt: "Search labs and sources", text: $search)
                        .padding(.horizontal, -10)
                }
                let vendors = news.vendorChoices.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                let sources = FeedSource.toggles.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
                if !vendors.isEmpty {
                    Section {
                        ForEach(vendors, id: \.id) { vendor in
                            Toggle(vendor.name, isOn: Binding(
                                get: { news.followedVendors.contains(vendor.id) },
                                set: { isOn in
                                    if isOn { news.followedVendors.insert(vendor.id) } else { news.followedVendors.remove(vendor.id) }
                                }
                            ))
                        }
                    } header: {
                        SettingsSectionTitle("Labs")
                    }
                }
                if !sources.isEmpty {
                    Section {
                        ForEach(sources) { source in
                            Toggle(source.name, isOn: Binding(
                                get: { news.followedSources.contains(source.id) },
                                set: { isOn in
                                    if isOn { news.followedSources.insert(source.id) } else { news.followedSources.remove(source.id) }
                                }
                            ))
                        }
                    } header: {
                        Text("Announcements")
                    } footer: {
                        Text("Choose curated voices and provider status in News → Following. Saves and reading choices stay on this device. Public articles open in your browser.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Menu bar

private struct MenuBarSettings: View {
    @Bindable var store: QuotaStore

    var body: some View {
        Form {
            SettingsHeaderSection()
            Section {
                Picker("Popover style", selection: $store.settings.popoverStyle) {
                    ForEach(PopoverStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                SettingsSectionTitle("Usage popover")
            } footer: {
                Text("\(store.settings.popoverStyle.summary) You can also switch styles with the palette button in the popover.")
            }
            Section {
                Picker("Style", selection: $store.settings.menuStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                // Through the store, so the new interval starts now rather than after the old wait.
                Picker("Refresh every", selection: Binding(
                    get: { store.settings.refreshMinutes },
                    set: { store.setRefreshMinutes($0) }
                )) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                }
            } header: {
                SettingsSectionTitle("Menu bar")
            } footer: {
                if store.menuMeters.count > 6, store.settings.menuStyle != .highest {
                    Text("Many providers are showing. Highest only keeps the menu bar narrow so macOS doesn't hide it.")
                }
            }
            Section {
                ForEach(store.popoverProviders) { provider in
                    Toggle(isOn: Binding(
                        get: { store.settings.showsInMenuBar(provider) },
                        set: { store.settings.setShowsInMenuBar(provider, $0) }
                    )) {
                        HStack(spacing: 8) {
                            ProviderIcon(provider: provider, size: 18)
                            Text(provider.displayName)
                        }
                    }
                }
            } header: {
                Text("Show in menu bar")
            } footer: {
                Text("Hidden providers stay in the popover. Balances without a limit never show in the menu bar.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: iPhone & Apple Watch

private struct RelaySettingsSection: View {
    @Bindable var relay: RelayPublisher
    @State private var sendingTest = false

    var body: some View {
        Section {
            if relay.isAvailable {
                Toggle(isOn: $relay.isEnabled) {
                    Text("Send readings to iCloud")
                    Text(relay.statusText)
                }
                TextField("Name on iPhone", text: $relay.label)
                LabeledContent("Test alert") {
                    Button("Send Test Alert") {
                        sendingTest = true
                        Task {
                            await relay.sendTestAlert()
                            sendingTest = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!relay.isEnabled || sendingTest)
                }
            } else {
                Text(relay.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Only percentages, reset times, window labels, plan names, and balances go to your private iCloud. Tokens and keys never leave this Mac.")
        }
    }
}

/// Opt-in: read Claude usage from Claude Code's own status line.
private struct ClaudeBridgeRow: View {
    /// Nil until `~/.claude/settings.json` has been read, off the main thread like every change to it.
    @State private var isOn: Bool?
    @State private var working = false
    @State private var message: String?
    @State private var overrides: [String] = []
    /// Where settings.json linked before Tokenroom 2.0.0 replaced the link with a file.
    @State private var replacedLink: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Read usage from Claude Code's status line", isOn: Binding(
                get: { isOn ?? false },
                set: { apply($0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(isOn == nil || working)
            Text(message ?? "Keeps Claude usage current without Claude's login. Changes only the status line in ~/.claude/settings.json and runs any status line you already have.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isOn == true, !overrides.isEmpty {
                Text("\(overrides.count == 1 ? "A project sets" : "\(overrides.count) projects set") its own status line, which replaces the bridge there: \(overrides.joined(separator: ", ")). Tokenroom never edits project settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let replacedLink {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Tokenroom 2.0.0 replaced ~/.claude/settings.json, a link to \(replacedLink), with a file. If you keep it with your dotfiles, link it again; Tokenroom 2.0.1 leaves links alone.")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss") {
                        self.replacedLink = nil
                        Task { await BlockingIO.run { ClaudeStatusLineBridge.standard.forgetReplacedLink() } }
                    }
                    .controlSize(.small)
                }
            }
        }
        .task {
            let bridge = ClaudeStatusLineBridge.standard
            let state = await BlockingIO.run { (isInstalled: bridge.isInstalled, replacedLink: bridge.replacedLink()) }
            isOn = state.isInstalled
            replacedLink = state.replacedLink
        }
        .task(id: isOn) {
            guard isOn == true else {
                overrides = []
                return
            }
            overrides = await BlockingIO.run { ClaudeStatusLineBridge.standard.projectOverrides().map(\.lastPathComponent) }
        }
    }

    private func apply(_ enable: Bool) {
        let bridge = ClaudeStatusLineBridge.standard
        working = true
        Task {
            let outcome = await BlockingIO.run { () -> (isInstalled: Bool, message: String?, replacedLink: String?) in
                do {
                    if enable {
                        try bridge.install()
                    } else {
                        try bridge.uninstall()
                    }
                    return (bridge.isInstalled, nil, bridge.replacedLink())
                } catch let error as ClaudeStatusLineBridge.BridgeError {
                    // What was wrong with the file: not JSON, two status lines, a link, read-only.
                    return (bridge.isInstalled, error.errorDescription, bridge.replacedLink())
                } catch {
                    return (bridge.isInstalled, "Couldn't change ~/.claude/settings.json.", bridge.replacedLink())
                }
            }
            isOn = outcome.isInstalled
            message = outcome.message
            replacedLink = outcome.replacedLink
            working = false
        }
    }
}
