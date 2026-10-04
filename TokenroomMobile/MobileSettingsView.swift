import SwiftUI

enum SettingsRoute: Hashable {
    case connect
    case keys
    case alerts
    case widgets
}

struct MobileSettingsView: View {
    @Bindable var store: MobileStore
    @Binding var path: [SettingsRoute]
    @State private var confirmsDelete = false
    @State private var deleteError: String?
    @State private var deleting = false

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    ReadingsStatusCard(store: store)
                    ForEach(store.relaySources) { source in
                        LabeledContent {
                            Text(source.envelope.map { RelativeTime.ago($0.checkedAt) } ?? "Needs a newer Tokenroom")
                        } label: {
                            SettingsRowLabel(source.label, symbol: source.kind == "iphone" ? "iphone" : "laptopcomputer", tint: .gray)
                        }
                    }
                    Toggle(isOn: $store.sampleMode) {
                        SettingsRowLabel("Sample Data", symbol: "sparkles", tint: .purple)
                    }
                } header: {
                    Text("Readings")
                } footer: {
                    Text("Your devices share readings through your iCloud. Providers added with keys can check on this iPhone; other providers check while Tokenroom runs on your Mac. Only usage, reset times, and plan names are sent, never logins or keys.")
                }

                if !store.sampleMode, !store.readings.isEmpty {
                    Section {
                        ForEach(store.readings) { reading in
                            LabeledContent {
                                Text(reading.origin.phrase)
                            } label: {
                                Label {
                                    Text(reading.provider.name)
                                } icon: {
                                    ProviderMark(provider: reading.provider, size: 24)
                                }
                            }
                        }
                    } header: {
                        Text("Where readings come from")
                    } footer: {
                        Text("Keys and logins stay on the device that reads them. Only usage syncs.")
                    }
                }

                Section {
                    NavigationLink(value: SettingsRoute.alerts) {
                        SettingsRowLabel("Alerts", symbol: "bell.badge.fill", tint: .red)
                    }
                    if store.connectOnIPhone {
                        NavigationLink(value: SettingsRoute.connect) {
                            SettingsRowLabel("Plans that need a Mac", symbol: "laptopcomputer", tint: .indigo)
                        }
                    }
                    NavigationLink(value: SettingsRoute.keys) {
                        LabeledContent {
                            if !store.keyedProviders.isEmpty {
                                Text("\(store.keyedProviders.count)")
                            }
                        } label: {
                            SettingsRowLabel("API Keys", symbol: "key.fill", tint: TokenroomTokens.tight)
                        }
                    }
                    NavigationLink(value: SettingsRoute.widgets) {
                        SettingsRowLabel("Widgets, Live Activity & Watch", symbol: "rectangle.stack.fill", tint: .blue)
                    }
                } footer: {
                    Text("Read providers right from this iPhone with API keys. Keys stay in its Keychain; they're never synced or sent to your other devices.")
                }

                Section {
                    Button(deleting ? "Deleting…" : "Delete Tokenroom Data from iCloud", role: .destructive) {
                        confirmsDelete = true
                    }
                    .disabled(deleting || store.relayPhase == .unavailable || store.relayPhase == .noAccount)
                } footer: {
                    Text(deleteError ?? "Removes every Tokenroom reading and history from your iCloud, for all your devices. Keys on this iPhone stay.")
                }

                Section("About") {
                    LabeledContent("Version", value: TokenroomIdentity.version)
                    // WidgetKit's budget is per widget, so the busiest one is what counts.
                    LabeledContent("Busiest widget's updates, last 24 hours", value: "\(WidgetReloadLog.count())")
                    Link(destination: TokenroomIdentity.privacyURL) {
                        SettingsRowLabel("Privacy", symbol: "hand.raised.fill", tint: .blue)
                    }
                    .foregroundStyle(.primary)
                    Link(destination: TokenroomIdentity.repositoryURL) {
                        SettingsRowLabel("Source Code", symbol: "chevron.left.forwardslash.chevron.right", tint: .gray)
                    }
                    .foregroundStyle(.primary)
                    Text("Tokenroom isn't affiliated with any of the providers it shows.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .connect: ConnectView(store: store)
                case .keys: KeysView(store: store)
                case .alerts: AlertsSettingsView(store: store)
                case .widgets: WidgetsHelpView()
                }
            }
            .confirmationDialog("Delete Tokenroom data from iCloud?", isPresented: $confirmsDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard !deleting else { return }
                    deleting = true
                    deleteError = nil
                    Task {
                        defer { deleting = false }
                        do {
                            try await store.deleteICloudData()
                            deleteError = nil
                        } catch {
                            deleteError = "Couldn't delete Tokenroom's data from iCloud. Try again later."
                        }
                    }
                }
            } message: {
                Text("Devices that collect usage send fresh readings on their next check.")
            }
        }
    }
}

/// A row's title beside a white symbol on a tinted tile, as the Settings app draws them.
struct SettingsRowLabel: View {
    var title: String
    var symbol: String
    var tint: Color

    init(_ title: String, symbol: String, tint: Color) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            SettingsTile(symbol: symbol, tint: tint)
        }
    }
}

struct SettingsTile: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 29

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(tint.gradient))
            .accessibilityHidden(true)
    }
}

/// The top of Settings: whether readings are coming in, and from how many devices.
private struct ReadingsStatusCard: View {
    var store: MobileStore

    var body: some View {
        HStack(spacing: 14) {
            SettingsTile(symbol: "icloud.fill", tint: tint, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("iCloud")
                    .font(.headline)
                Text(store.relayStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch store.relayPhase {
        case .ready: .blue
        case .failed, .noAccount: TokenroomTokens.tight
        default: .gray
        }
    }

    /// "12 providers · checked 2m ago".
    private var detail: String? {
        guard !store.readings.isEmpty else { return nil }
        let count = store.readings.count == 1 ? "1 provider" : "\(store.readings.count) providers"
        guard let checked = store.lastChecked else { return count }
        return "\(count) · checked \(RelativeTime.ago(checked))"
    }
}

/// Providers this iPhone can read with a key, grouped like the Mac's settings.
struct KeysView: View {
    @Bindable var store: MobileStore
    @State private var search = ""

    private let groups: [(title: String, providers: [Provider])] = [
        ("Coding plans", Provider.allCases.filter { $0.access == .codingPlanKey || $0.descriptor.fallbackKey != nil }),
        ("Pay as you go", Provider.allCases.filter { $0.access == .pastedKey && $0.category == .apiBalance }),
        ("Organization billing", Provider.allCases.filter { $0.category == .orgSpend }),
    ]

    var body: some View {
        List {
            ForEach(groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.providers.filter { NewsSearch.matches(search, title: $0.displayName, source: $0.rawValue) }) { provider in
                        NavigationLink {
                            KeyEditorView(store: store, provider: provider)
                        } label: {
                            KeyRowLabel(store: store, provider: provider)
                        }
                    }
                }
            }
        }
        .navigationTitle("API Keys")
        .searchable(text: $search, prompt: "Search providers")
    }
}

private struct KeyRowLabel: View {
    var store: MobileStore
    var provider: Provider
    @State private var metadata: APIKeyStore.Metadata?

    var body: some View {
        HStack(spacing: 12) {
            ProviderMark(provider: provider, size: 30)
            Text(provider.displayName)
            Spacer()
            Text(metadata.map { "•••• \($0.last4)" } ?? "Add")
                .font(metadata == nil ? .body : .body.monospaced())
                .foregroundStyle(.secondary)
        }
        .task(id: store.keyedProviders) {
            metadata = await store.metadata(for: provider)
        }
    }
}

struct KeyEditorView: View {
    var store: MobileStore
    var provider: Provider
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: APIKeyStore.Metadata?
    @State private var key = ""
    @State private var region: String
    @State private var replacing = false
    @State private var working = false
    @State private var saving = false
    @State private var validation = KeyValidationRevision()
    @State private var message: String?
    @State private var offerSaveAnyway = false
    @State private var acknowledgedAdmin = false
    @State private var budgetText = ""
    @State private var budgetError: String?
    /// Set when the key's test found something to warn about (an xAI key with write access).
    @State private var warning: String?

    init(store: MobileStore, provider: Provider) {
        self.store = store
        self.provider = provider
        _region = State(initialValue: provider.keySpec?.regions.first ?? "")
        _budgetText = State(initialValue: store.budget(for: provider).map { $0.formatted(.number.grouping(.never)) } ?? "")
    }

    private var spec: KeySpec? { provider.keySpec }

    var body: some View {
        Form {
            if let metadata, !replacing {
                Section {
                    LabeledContent("Key", value: "•••• \(metadata.last4)\(metadata.region.map { " · \($0)" } ?? "")")
                    if let warning = metadata.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(TokenroomTokens.accentText)
                    }
                    Button("Replace Key") {
                        invalidateValidation()
                        replacing = true
                    }
                    .disabled(working)
                    Button(working ? "Removing…" : "Remove Key", role: .destructive) { remove() }
                        .disabled(working)
                } footer: {
                    Text(message ?? "Added \(metadata.addedAt.formatted(date: .abbreviated, time: .omitted)).")
                }
            } else {
                Section {
                    SecureField(spec?.prefixHint.isEmpty == false ? "\(spec!.prefixHint)…" : "Paste your key", text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.password)
                        .disabled(saving)
                    if let regions = spec?.regions, !regions.isEmpty {
                        Picker(spec?.choiceLabel ?? "Account", selection: $region) {
                            ForEach(regions, id: \.self) { Text($0).tag($0) }
                        }.disabled(saving)
                    }
                    if let url = spec?.createURL {
                        Link(spec?.createTitle ?? "Create a key", destination: url)
                    }
                } header: {
                    Text(spec?.label ?? "API key")
                } footer: {
                    Text(message ?? [spec?.note, "Tokenroom only reads usage, balance, or spend with this key. It stays in this iPhone's Keychain."].compactMap { $0 }.joined(separator: " "))
                }
                if let warning {
                    Section {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(TokenroomTokens.accentText)
                    }
                }
                if spec?.isAdmin == true {
                    Section {
                        Text("This is an organization-wide key. It can read and change your organization's settings. Tokenroom only reads cost and billing with it.")
                            .font(.footnote)
                        Toggle("I created a dedicated key I can revoke", isOn: $acknowledgedAdmin)
                    }
                }
                Section {
                    Button(working ? (saving ? "Saving…" : "Testing…") : (warning == nil ? "Test & Save" : "Save With This Key")) {
                        if warning == nil { test() } else { Task { await save() } }
                    }
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working || (spec?.isAdmin == true && !acknowledgedAdmin))
                    if offerSaveAnyway {
                        Button("Save Anyway") { Task { await save() } }
                            .disabled(working || (spec?.isAdmin == true && !acknowledgedAdmin))
                    }
                }
            }
            if provider.category != .subscription {
                Section {
                    TextField("None", text: $budgetText)
                        .keyboardType(.decimalPad)
                        .onSubmit(saveBudget)
                        .onChange(of: budgetText) { _, text in
                            budgetError = BudgetInput.parse(text) == .invalid ? BudgetInput.error : nil
                        }
                    if let budgetError { Text(budgetError).font(.footnote).foregroundStyle(.red) }
                } header: {
                    Text(provider.category == .orgSpend ? "Monthly budget (\(store.budgetCurrency(for: provider)))" : "Reference (\(store.budgetCurrency(for: provider)))")
                } footer: {
                    Text(provider.category == .orgSpend
                        ? "A budget turns this month's spend into a meter, with alerts at 80% and 95%."
                        : "The amount you topped up to. It turns the balance into a meter, with an alert when it runs low.")
                }
            }
        }
        .navigationTitle(provider.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            metadata = await store.metadata(for: provider)
            // Replace Key starts from the choice saved with the key, such as its Copilot plan.
            if let metadata, let spec {
                region = spec.initialChoice(saved: metadata)
            }
        }
        .onChange(of: key) { _, _ in invalidateValidation() }
        .onChange(of: region) { _, _ in invalidateValidation() }
        .onDisappear { invalidateValidation() }
        .onDisappear(perform: saveBudget)
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
            try await store.saveKey(credential.key, for: provider, region: credential.region, warning: savedWarning)
            dismiss()
        } catch {
            message = "Couldn't save the key in the Keychain."
        }
    }
    private func remove() {
        guard !working else { return }
        working = true
        message = nil
        Task {
            defer { working = false }
            do {
                try await store.removeKey(for: provider)
                metadata = nil
                key = ""
                invalidateValidation()
            } catch {
                message = "Couldn't remove the key from the Keychain."
            }
        }
    }

    private func saveBudget() {
        guard provider.category != .subscription else { return }
        switch BudgetInput.parse(budgetText) {
        case .clear: budgetError = nil; store.setBudget(nil, for: provider)
        case .amount(let value):
            budgetError = nil
            if value != store.budget(for: provider) { store.setBudget(value, for: provider) }
        case .invalid: budgetError = BudgetInput.error
        }
    }
}

/// Where Tokenroom shows up outside the app, and how to add each.
struct WidgetsHelpView: View {
    var body: some View {
        List {
            Section {
                HelpRow(symbol: "square.grid.2x2", title: "Home Screen widgets", text: "Touch and hold the Home Screen, tap Edit, then Add Widget, and search for Tokenroom. Small shows one provider or the most urgent; Medium and Large show several, with a week of history on Large.")
                HelpRow(symbol: "lock.rectangle", title: "Lock Screen widgets", text: "Touch and hold the Lock Screen, tap Customize, then Lock Screen, and add Tokenroom's ring, list, or one-line widget.")
            } header: {
                Text("Widgets")
            }
            Section {
                HelpRow(symbol: "timer", title: "Follow a reset", text: "When a session, or a busy week, resets within 8 hours, open the provider and tap Follow on Lock Screen. A countdown stays on the Lock Screen and in the Dynamic Island until it resets.")
                HelpRow(symbol: "switch.2", title: "Control Center and the Action button", text: "Add the Follow Usage control to Control Center, or assign it to the Action button, to follow the most urgent reset with one press.")
            } header: {
                Text("Live Activity")
            }
            Section {
                HelpRow(symbol: "applewatch", title: "Apple Watch", text: "Install Tokenroom from the Watch app on this iPhone. The Watch reads your iCloud directly, so it keeps working when this iPhone is away. Add a Tokenroom complication to a watch face, and the Smart Stack shows a limit as it nears its reset.")
            }
        }
        .navigationTitle("Widgets & Watch")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct HelpRow: View {
    var symbol: String
    var title: String
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
