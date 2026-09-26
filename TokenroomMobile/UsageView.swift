import SwiftUI
import UserNotifications

/// The Usage tab: windows close to a limit first, then a tile per plan with its weekly (or
/// monthly) limit as a ring and its 5-hour limit as a bar, each with the even-pace mark.
struct UsageView: View {
    @Bindable var store: MobileStore
    @Binding var path: [String]
    var openAlerts: () -> Void = {}
    @State private var showsDisconnected = false
    @State private var notificationsOff = false
    /// Why following a tile's window failed, from its context menu.
    @State private var followError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.sampleMode {
                        SampleBanner(store: store)
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                    }
                    let close = closeWindows
                    if !close.isEmpty {
                        CloseToLimitCard(windows: close) { id in path = [id] }
                    }
                    if !highlights.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(highlights) { highlight in
                                    Button(action: highlight.action) {
                                        Label(highlight.title, systemImage: highlight.symbol)
                                            .font(.subheadline.weight(.medium))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.horizontal, -20)
                    }
                    if !store.readings.isEmpty {
                        tiles
                    }
                    if !store.disconnected.isEmpty {
                        disconnectedSection
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Usage")
            .navigationSubtitle(header ?? "")
            .navigationDestination(for: String.self) { id in
                if let reading = store.reading(id: id) {
                    ProviderDetailView(reading: reading)
                }
            }
            .overlay {
                if store.readings.isEmpty, store.disconnected.isEmpty {
                    UsageEmptyState(store: store)
                }
            }
            .refreshable {
                await store.refresh(force: true)
            }
            .task {
                await checkNotifications()
            }
            .onChange(of: scenePhase) { _, phase in
                // Back from Settings, where notifications may have been turned on.
                if phase == .active {
                    Task { await checkNotifications() }
                }
            }
            .alert("Couldn't follow it", isPresented: Binding(get: { followError != nil }, set: { if !$0 { followError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(followError ?? "")
            }
        }
    }

    /// Two tiles a row, each row as tall as its taller tile.
    private var tiles: some View {
        let readings = store.readings
        let rows = stride(from: 0, to: readings.count, by: 2).map { Array(readings[$0..<min($0 + 2, readings.count)]) }
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { reading in
                        NavigationLink(value: reading.id) {
                            UsageTileView(reading: reading)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            FollowButton(provider: reading.provider) { error in
                                if let error { followError = error }
                            }
                            Button("Details", systemImage: "info.circle") { path = [reading.id] }
                        }
                    }
                    if row.count == 1 {
                        Color.clear
                            .gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }

    private var disconnectedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $showsDisconnected) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.disconnected) { reading in
                        DisconnectedRow(reading: reading)
                    }
                }
                .padding(.top, 10)
            } label: {
                Text("Not connected (\(store.disconnected.count))")
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
            Text(disconnectedFooter)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        }
    }

    private var closeWindows: [CloseWindow] {
        UsageTiles.closeWindows(store.readings.map { (provider: $0.provider, history: $0.history) })
    }

    private struct Highlight: Identifiable {
        var id: String
        var title: String
        var symbol: String
        var action: () -> Void
    }

    /// Banked resets and alerts that are off. News counts live on the News tab's badge.
    private var highlights: [Highlight] {
        var items: [Highlight] = []
        let banked = store.readings.filter { ($0.provider.banked?.available ?? 0) > 0 }
        let bankedCount = banked.reduce(0) { $0 + ($1.provider.banked?.available ?? 0) }
        if bankedCount > 0, let first = banked.first {
            items.append(Highlight(id: "banked", title: bankedCount == 1 ? "1 banked reset" : "\(bankedCount) banked resets", symbol: "arrow.counterclockwise") {
                path = [first.id]
            })
        }
        if notificationsOff, !store.sampleMode {
            items.append(Highlight(id: "alerts", title: "Turn on alerts", symbol: "bell.badge") {
                openAlerts()
            })
        }
        return items
    }

    private func checkNotifications() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsOff = status == .denied || status == .notDetermined
    }

    private var header: String? {
        guard !store.sampleMode, let source = store.sourceSummary else { return nil }
        guard let checked = store.lastChecked else { return "From \(source)" }
        return "From \(source) · checked \(RelativeTime.ago(checked))"
    }

    /// Mac providers wait for a sign-in there; this iPhone's key providers for their key to work.
    private var disconnectedFooter: String {
        let fromKeys = store.disconnected.contains { store.keyedProviders.map(\.rawValue).contains($0.id) }
        let fromMac = store.disconnected.contains { !store.keyedProviders.map(\.rawValue).contains($0.id) }
        switch (fromMac, fromKeys) {
        case (true, true): return "Sign in to these on your Mac, or check their keys in Settings › API Keys."
        case (false, true): return "Check these keys in Settings › API Keys."
        default: return "Sign in to these on your Mac to see them here."
        }
    }
}

private struct DisconnectedRow: View {
    var reading: MobileStore.Reading

    var body: some View {
        HStack(spacing: 12) {
            MonogramMark(provider: reading.provider, size: 28)
                .opacity(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(reading.provider.name)
                if let message = reading.provider.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SampleBanner: View {
    @Bindable var store: MobileStore

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Sample data")
                    .font(.subheadline.weight(.semibold))
                Text("These readings aren't real.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Turn Off") {
                store.sampleMode = false
                Task { await store.refresh(force: true) }
            }
            .buttonStyle(.bordered)
        }
    }
}

struct UsageEmptyState: View {
    @Bindable var store: MobileStore
    @State private var addsKey = false

    var body: some View {
        Group {
            if store.relayPhase == .loading || store.relayPhase == .idle {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label(content.title, systemImage: content.symbol)
                } description: {
                    Text(content.description)
                } actions: {
                    Button("Add an API Key") { addsKey = true }
                        .buttonStyle(.borderedProminent)
                    Button("Try Sample Data") {
                        store.hasOnboarded = true
                        store.sampleMode = true
                    }
                }
            }
        }
        .sheet(isPresented: $addsKey) {
            NavigationStack {
                KeysView(store: store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { addsKey = false }
                        }
                    }
            }
        }
    }

    private var content: (title: String, symbol: String, description: String) {
        switch store.relayPhase {
        case .unavailable:
            ("No readings yet", "key", "This build can't use iCloud. Add an API key to read providers on this iPhone.")
        case .noAccount:
            ("Sign in to iCloud", "icloud.slash", "Use the same Apple Account as your Mac to see its readings, or add an API key.")
        case .failed(let message):
            (message, "exclamationmark.icloud", "Pull down to try again, or add an API key.")
        case .ready where store.needsNewerApp:
            ("Update Tokenroom", "arrow.down.app", "Your Mac sends readings this version can't read yet.")
        default:
            ("No readings yet", "laptopcomputer.and.iphone", "Open Tokenroom on your Mac, signed in to the same iCloud account: it sends its readings here. Or add an API key to read providers on this iPhone.")
        }
    }
}

enum PaceStyle {
    static func color(_ severity: Pace.Severity) -> Color {
        switch severity {
        case .critical: TokenroomTokens.critical
        case .tight: TokenroomTokens.tight
        case .watch, .none: .secondary
        }
    }
}
