import AppKit
import SwiftUI

struct PopoverView: View {
    @Bindable var store: QuotaStore
    /// Opens Settings, on the given page or the last one shown.
    var onSettings: (SettingsTab?) -> Void
    var onNews: (NewsSection) -> Void
    @State private var showsDisconnected = false
    @State private var expanded: Set<Provider>
    @State private var selectedProvider: Provider?
    @Environment(\.colorScheme) private var colorScheme

    private var style: PopoverStyle { store.settings.popoverStyle }
    private var isClassic: Bool { style == .classic }
    private var detailProvider: Provider? {
        guard !isClassic, let selectedProvider, store.popoverProviders.contains(selectedProvider) else { return nil }
        return selectedProvider
    }

    init(store: QuotaStore, onSettings: @escaping (SettingsTab?) -> Void, onNews: @escaping (NewsSection) -> Void = { _ in }, expanded: Set<Provider> = []) {
        self.store = store
        self.onSettings = onSettings
        self.onNews = onNews
        _expanded = State(initialValue: expanded)
        _selectedProvider = State(initialValue: expanded.sorted { $0.rawValue < $1.rawValue }.first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, sideInset)
                .padding(.top, 14)
                .padding(.bottom, 10)

            if store.showsLegacyNotice {
                legacyNotice
                    .padding(.horizontal, TokenroomTokens.cardPadding)
                    .padding(.bottom, TokenroomTokens.cardGap)
            }

            let providers = store.popoverProviders
            if providers.isEmpty {
                emptyProviders
                    .padding(.horizontal, TokenroomTokens.cardPadding)
                    .padding(.bottom, 8)
            } else {
                if let provider = detailProvider {
                    // A short page sits at its own height, so a balance doesn't float in space.
                    ViewThatFits(in: .vertical) {
                        providerDetail(provider)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            providerDetail(provider)
                        }
                        .mask(Self.scrollFade)
                    }
                    .frame(maxHeight: 520)
                    .id(provider)
                } else {
                    ViewThatFits(in: .vertical) {
                        providerList
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            providerList
                        }
                        .mask(Self.scrollFade)
                    }
                    .frame(maxHeight: 520)
                }
            }

            highlights
                .padding(.horizontal, sideInset)
                .padding(.top, 10)

            Divider()
                .padding(.top, 10)
                .opacity(0.7)

            footer
                .padding(.horizontal, sideInset)
                .padding(.vertical, 10)
        }
        .frame(width: style.width)
        .background(PopoverSurface(style: style))
        .environment(\.colorScheme, style == .instrument ? .dark : colorScheme)
        .onChange(of: style) { _, _ in selectedProvider = nil }
        .transaction { $0.animation = nil }
    }

    /// Fades what scrolls under the footer, so a row is never cut through by a hard line.
    private static var scrollFade: some View {
        VStack(spacing: 0) {
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 18)
        }
    }

    /// One edge for the header, rows, and footer.
    private var sideInset: CGFloat { isClassic ? TokenroomTokens.cardPadding : 20 }

    private func providerDetail(_ provider: Provider) -> some View {
        PopoverProviderView(card: providerCard(provider, expanded: true), style: style, showsDetails: true)
    }

    private var providerList: some View {
        VStack(spacing: TokenroomTokens.cardGap) {
            cards(store.connectedProviders)
            let disconnected = store.disconnectedProviders
            if !disconnected.isEmpty {
                Button {
                    showsDisconnected.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showsDisconnected ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Not connected (\(disconnected.count))")
                        Spacer()
                    }
                    .font(.system(size: TokenroomTokens.captionSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, sideInset)
                .accessibilityLabel("Not connected, \(disconnected.count) providers")
                if showsDisconnected {
                    cards(disconnected)
                }
            }
        }
    }

    /// More than five connected providers: one line each until clicked.
    private var isCompact: Bool {
        store.connectedProviders.count > 5
    }

    private func cards(_ providers: [Provider]) -> some View {
        VStack(spacing: isClassic ? (isCompact ? 6 : TokenroomTokens.cardGap) : 0) {
            ForEach(providers, id: \.self) { provider in
                let isExpanded = expanded.contains(provider)
                if isClassic {
                    providerCard(provider, expanded: isExpanded)
                } else {
                    PopoverProviderView(card: providerCard(provider, expanded: false), style: style) {
                        selectedProvider = provider
                    }
                    if provider != providers.last { Divider().padding(.horizontal, 20) }
                }
            }
        }
        .padding(.horizontal, isClassic ? TokenroomTokens.cardPadding : 0)
    }

    private func providerCard(_ provider: Provider, expanded: Bool) -> ProviderCard {
        ProviderCard(
            provider: provider, status: store.presentationStatus(for: provider), checkedAt: store.lastChecked(provider),
            pace: store.pace(for: provider, now: store.presentationNow),
            windowPaces: expanded ? store.windowPaces(for: provider, now: store.presentationNow) : [:],
            weeks: store.weeks(for: provider), isExpanded: expanded, isCompact: isClassic && isCompact,
            onToggleExpanded: { if isClassic { toggle(provider) } else { selectedProvider = provider } },
            signInPhase: store.signIn.phase, onSignIn: { store.signIn.signIn(provider) },
            onCancelSignIn: { store.signIn.cancel() }, onInstall: { store.signIn.openInstallPage(provider) },
            date: store.presentationNow
        )
    }

    private func toggle(_ provider: Provider) {
        if expanded.contains(provider) {
            expanded.remove(provider)
        } else {
            expanded.insert(provider)
        }
    }

    /// Banked resets and news at a glance: "2 banked resets · 3 new models · 5 updates".
    @ViewBuilder
    private var highlights: some View {
        // A provider's page lists its own banked resets, and another's don't belong on it.
        let banked: (count: Int, providers: [Provider]) = detailProvider == nil ? store.bankedResets : (0, [])
        let news = store.settings.newsEnabled ? store.news : nil
        let models = news?.unseenModelCount ?? 0
        let updates = news?.unseenReleaseCount ?? 0
        if banked.count > 0 || models > 0 || updates > 0 {
            // Full labels when they fit, shorter ones when all three show.
            ViewThatFits(in: .horizontal) {
                highlightPills(banked: banked, models: models, updates: updates, short: false)
                highlightPills(banked: banked, models: models, updates: updates, short: true)
            }
        }
    }

    private func highlightPills(banked: (count: Int, providers: [Provider]), models: Int, updates: Int, short: Bool) -> some View {
        HStack(spacing: 6) {
            if banked.count > 0 {
                HighlightPill(
                    title: short ? "\(banked.count) banked" : (banked.count == 1 ? "1 banked reset" : "\(banked.count) banked resets"),
                    systemImage: "arrow.counterclockwise"
                ) {
                    if isClassic { expanded.formUnion(banked.providers) }
                    else { selectedProvider = banked.providers.first }
                }
                .help("Resets you can use when a limit runs out")
            }
            if models > 0 {
                HighlightPill(title: short ? "\(models) model\(models == 1 ? "" : "s")" : (models == 1 ? "1 new model" : "\(models) new models"), systemImage: "sparkles") {
                    onNews(.models)
                }
                .help("New models from the labs you follow")
            }
            if updates > 0 {
                HighlightPill(title: updates == 1 ? "1 update" : "\(updates) updates", systemImage: "megaphone") {
                    onNews(.announcements)
                }
                .help("Changelogs and announcements")
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: !short, vertical: false)
    }

    private var legacyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tokenroom replaces Headroom")
                .font(.system(size: TokenroomTokens.popoverNameSize, weight: .semibold))
            Text("Quit Headroom, remove it from Login Items in System Settings › General, and move it to the Trash so only one extra runs.")
                .font(.system(size: TokenroomTokens.captionSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Headroom's own login item can't be read or carried over; this takes its place.
            Toggle("Launch Tokenroom at login", isOn: $store.settings.launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.system(size: TokenroomTokens.captionSize))
            HStack(spacing: 12) {
                if LegacyMigration.isLegacyAppRunning {
                    Button("Quit Headroom") {
                        store.quitLegacyApp()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if let url = LegacyMigration.legacyAppURL {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: TokenroomTokens.captionSize, weight: .medium))
                }
                Button("Dismiss") {
                    store.dismissLegacyNotice()
                }
                .buttonStyle(.plain)
                .font(.system(size: TokenroomTokens.captionSize, weight: .medium))
            }
        }
        .padding(TokenroomTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var emptyProviders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No providers on")
                .font(.system(size: TokenroomTokens.popoverNameSize, weight: .semibold))
            Text("Turn on the tools you use in Settings, such as Claude, Codex, Cursor, or Copilot, then sign in to see usage.")
                .font(.system(size: TokenroomTokens.captionSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(TokenroomTokens.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    /// When sending to iCloud failed: said in the header, where it's seen, rather than only in
    /// Settings. States someone chose (sync off, no iCloud account on this Mac, Tokenroom's data
    /// deleted in iCloud settings) and unsigned builds stay in Settings, so nothing nags for good.
    var syncProblem: String? {
        guard let relay = store.relay else { return nil }
        switch relay.state {
        case .failed: return "Couldn't sync with iCloud"
        case .unavailable, .off, .waiting, .noAccount, .paused, .sent: return nil
        }
    }

    var checkedHeaderText: String {
        if store.isRefreshing { return "Checking…" }
        if let detailProvider { return "Checked \(RelativeTime.ago(store.lastChecked(detailProvider), now: store.presentationNow))" }
        // A signed-out provider keeps its last check from before; it isn't on show to be current.
        let shown = store.popoverProviders.filter { !(store.statuses[$0] ?? .loading).isDisconnected }
        let oldestCheck = shown.compactMap { store.lastChecked($0) }.min()
        return "Checked \(RelativeTime.ago(oldestCheck, now: store.presentationNow))"
    }

    private var header: some View {
        HStack(spacing: 10) {
            if detailProvider != nil {
                Button { selectedProvider = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 20, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to all providers")
                .help("Back to all providers")
            }
            if let provider = detailProvider {
                ProviderIcon(provider: provider, size: 26)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(detailProvider?.displayName ?? "Tokenroom")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Text(checkedHeaderText)
                    if let relay = store.relay, case .sent(let date) = relay.state {
                        // Quiet when the iPhone is getting readings: a mark, with when as its tooltip.
                        Image(systemName: "checkmark.icloud")
                            .imageScale(.small)
                            .help("Sent to your iPhone and Watch \(RelativeTime.ago(date, now: store.presentationNow))")
                            .accessibilityLabel("Sent to your iPhone and Watch \(RelativeTime.ago(date, now: store.presentationNow))")
                    }
                }
                .font(.system(size: TokenroomTokens.captionSize))
                .foregroundStyle(.secondary)
                if let problem = syncProblem {
                    Button { onSettings(.iPhone) } label: {
                        Label(problem, systemImage: "exclamationmark.icloud")
                            .font(.system(size: TokenroomTokens.captionSize, weight: .medium))
                            .foregroundStyle(TokenroomTokens.accentText)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(store.relay?.statusText ?? "")
                }
            }
            Spacer(minLength: 8)
            Menu {
                Picker("Popover style", selection: $store.settings.popoverStyle) {
                    ForEach(PopoverStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } label: {
                Image(systemName: "paintpalette").font(.system(size: 13)).frame(width: 26, height: 26)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Popover style, \(style.title)")
            .help("Popover style · \(style.title)")
            Button {
                Task { await store.refresh(force: true) }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 26, height: 26)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(store.isRefreshing)
            .help("Refresh")
            .accessibilityLabel("Refresh")
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                onSettings(nil)
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            Button {
                onNews(.today)
            } label: {
                Label("News", systemImage: "newspaper")
            }
            .buttonStyle(.plain)
            Spacer()
            // Quit is one click further, as in the system's own extras: rarely wanted, never lost.
            Menu {
                Button("Quit Tokenroom") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More")
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(minHeight: 22)
    }
}

/// A small action in the popover's footer strip.
private struct HighlightPill: View {
    var title: String
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
