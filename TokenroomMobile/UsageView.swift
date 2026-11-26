import SwiftUI
import UserNotifications

struct UsageView: View {
    @Bindable var store: MobileStore
    @Binding var path: [String]
    var openAlerts: () -> Void = {}
    @State private var showsDisconnected = false
    @State private var notificationsOff = false
    @State private var showsAllClose = false
    @State private var followError: String?
    @State private var order: [String] = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { tick in
            content(at: tick.date).onChange(of: tick.date, initial: true) { _, date in store.ageReadings(at: date) }
        }
        .task(id: scenePhase == .active) {
            guard scenePhase == .active else { return }
            await store.keepCurrent()
        }
    }

    private func content(at date: Date) -> some View {
        let readings = store.readings
        let board = UsageBoard(
            readings.map { (provider: $0.provider, history: $0.history, source: $0.source, origin: $0.origin) },
            showsAllClose: showsAllClose, now: date
        )
        let close = board.close
        let highlights = self.highlights(in: readings)
        return NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.sampleMode {
                        SampleBanner(store: store)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                    }
                    if !store.sampleMode, !readings.isEmpty || !store.disconnected.isEmpty {
                        RelayStatusNotice(store: store)
                    }
                    if !close.isEmpty {
                        CloseToLimitCard(windows: close, date: date, showsAll: $showsAllClose) { id in path = [id] }
                    }
                    if !highlights.isEmpty, !readings.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(highlights) { highlight in
                                    Button(action: highlight.action) {
                                        Label(highlight.title, systemImage: highlight.symbol)
                                            .font(.footnote.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        .padding(.horizontal, -20)
                    }
                    if !readings.isEmpty {
                        if !close.isEmpty {
                            Text("All plans")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16)
                                .padding(.top, 4)
                                .accessibilityAddTraits(.isHeader)
                        }
                        tiles(readings, board: board, at: date)
                    }
                    if !store.disconnected.isEmpty {
                        disconnectedSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Usage")
            .navigationSubtitle(header(board, at: date) ?? "")
            .navigationDestination(for: String.self) { id in
                if let reading = store.reading(id: id) {
                    ProviderDetailView(reading: reading, date: date)
                } else {
                    Text("Couldn't find a reading for this provider.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .navigationTitle(Provider(rawValue: id)?.displayName ?? "Usage")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
            .overlay {
                if readings.isEmpty, store.disconnected.isEmpty {
                    UsageEmptyState(store: store)
                }
            }
            .refreshable {
                await store.refresh(force: true, manual: true)
                rank()
            }
            .task {
                await checkNotifications()
            }
            .onAppear(perform: rank)
            .onChange(of: readings.map(\.id)) { _, ids in
                if !ids.contains(where: order.contains) { order = ids }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    rank()
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

    private func tiles(_ readings: [MobileStore.Reading], board: UsageBoard, at date: Date) -> some View {
        let tiles = UsageTiles.ordered(Array(zip(readings, board.plans)), id: \.0.id, as: order)
        let showsOrigin = !store.sampleMode && board.hasMixedOrigins
        let columns = typeSize >= .xxLarge ? 1 : 2
        let rows = stride(from: 0, to: tiles.count, by: columns).map { Array(tiles[$0..<min($0 + columns, tiles.count)]) }
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(rows, id: \.first?.0.id) { row in
                GridRow {
                    ForEach(row, id: \.0.id) { reading, plan in
                        NavigationLink(value: reading.id) {
                            UsageTileView(reading: reading, plan: plan, date: date, showsOrigin: showsOrigin)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            FollowButton(provider: reading.provider) { error in
                                if let error { followError = error }
                            }
                            Button("Details", systemImage: "info.circle") { path = [reading.id] }
                        }
                    }
                    if row.count < columns {
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
                        DisconnectedRow(reading: reading, reason: connectReason(for: reading))
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

    private func rank() {
        order = store.readings.map(\.id)
    }

    private struct Highlight: Identifiable {
        var id: String
        var title: String
        var symbol: String
        var action: () -> Void
    }

    private func highlights(in readings: [MobileStore.Reading]) -> [Highlight] {
        var items: [Highlight] = []
        let banked = readings.filter { $0.provider.availableBanked(at: .now) != nil }
        let bankedCount = banked.reduce(0) { $0 + ($1.provider.availableBanked(at: .now)?.available ?? 0) }
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

    private func header(_ board: UsageBoard, at date: Date) -> String? {
        guard !store.sampleMode, let source = board.sourceSummary else { return nil }
        let stale = board.staleCount
        let staleNote = stale > 0 ? " · \(stale) stale" : ""
        if store.isRefreshing { return "From \(source) · checking…" + staleNote }
        guard let checked = board.latestChecked else { return "From \(source)" }
        return "From \(source) · checked \(RelativeTime.ago(checked, now: date))" + staleNote
    }

    private func connectReason(for reading: MobileStore.Reading) -> String? {
        guard store.connectOnIPhone, reading.provider.message == nil,
              let provider = Provider(rawValue: reading.id),
              case .needsMac(let reason) = store.connectAction(for: provider)
        else { return nil }
        return reason
    }

    private var disconnectedFooter: String {
        if store.connectOnIPhone {
            return PhoneConnect.disconnectedFooter(store.disconnected.map { reading in
                Provider(rawValue: reading.id).map { store.connectAction(for: $0) } ?? .needsMac(reason: "")
            })
        }
        let fromKeys = store.disconnected.contains { store.keyedProviders.map(\.rawValue).contains($0.id) }
        let fromMac = store.disconnected.contains { !store.keyedProviders.map(\.rawValue).contains($0.id) }
        switch (fromMac, fromKeys) {
        case (true, true): return "Sign in to these on your Mac, or check their keys in Settings › API Keys."
        case (false, true): return "Check these keys in Settings › API Keys."
        default: return "Sign in to these on your Mac to see them here."
        }
    }
}

private struct RelayStatusNotice: View {
    var store: MobileStore

    var body: some View {
        if let notice {
            VStack(alignment: .leading, spacing: 8) {
                Label(notice.title, systemImage: "exclamationmark.icloud")
                    .font(.subheadline.weight(.semibold))
                Text(notice.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if notice.canRetry {
                    Button("Retry iCloud") { Task { await store.refresh(force: true) } }
                        .disabled(store.isRefreshing)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        }
    }

    private var notice: (title: String, detail: String, canRetry: Bool)? {
        switch store.relayPhase {
        case .failed(let message):
            return (message, "Couldn't sync readings with your other devices. Available readings stay below; check each provider's last successful check.", true)
        case .noAccount:
            return ("Sign in to iCloud", "Use the same Apple Account on your devices to sync usage. Providers added with keys can still check on this iPhone.", true)
        case .unavailable:
            return (store.relayIsInThisBuild ? "Tokenroom can't access iCloud" : "iCloud isn't available in this build", "Readings can't sync to your other devices. Providers added with keys can still check on this iPhone.", false)
        case .ready where store.needsNewerApp:
            return ("Update Tokenroom", "Some readings from your other devices need a newer version of this app. Available readings stay below.", false)
        default:
            return nil
        }
    }
}

private struct DisconnectedRow: View {
    var reading: MobileStore.Reading
    var reason: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ProviderMark(provider: reading.provider, size: 28)
                .opacity(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(reading.provider.name)
                if let message = reading.provider.message ?? reason {
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
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sample data")
                    .font(.footnote.weight(.semibold))
                Text("These readings aren't real.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Turn Off") {
                store.sampleMode = false
                Task { await store.refresh(force: true) }
            }
            .font(.footnote)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

struct UsageEmptyState: View {
    @Bindable var store: MobileStore
    @State private var addsKey = false
    @State private var signsIn = false

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
                    if store.relayPhase != .unavailable {
                        Button("Refresh") { Task { await store.refresh(force: true) } }
                            .disabled(store.isRefreshing)
                    }
                    if store.canSignInOnIPhone {
                        Button("Sign In to a Plan") { signsIn = true }
                            .buttonStyle(.borderedProminent)
                        Button("Add an API Key") { addsKey = true }
                    } else {
                        Button("Add an API Key") { addsKey = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("Try Sample Data") {
                        store.hasOnboarded = true
                        store.sampleMode = true
                    }
                }
            }
        }
        .sheet(isPresented: $signsIn) {
            NavigationStack {
                ConnectView(store: store)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { signsIn = false }
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

    private var onThisIPhone: String {
        store.canSignInOnIPhone ? "sign in to a plan or add an API key" : "add an API key"
    }

    private var content: (title: String, symbol: String, description: String) {
        switch store.relayPhase {
        case .unavailable:
            ("No readings yet", "key", "\(store.relayUnavailableText) \(onThisIPhone.capitalizedFirst) to read providers on this iPhone.")
        case .noAccount:
            ("Sign in to iCloud", "icloud.slash", "Use the same Apple Account as your Mac to see its readings, or \(onThisIPhone).")
        case .failed(let message):
            (message, "exclamationmark.icloud", "Pull down to try again, or \(onThisIPhone).")
        case .ready where store.needsNewerApp:
            ("Update Tokenroom", "arrow.down.app", "Your Mac sends readings this version can't read yet.")
        default:
            ("No readings yet", "laptopcomputer.and.iphone", "Open Tokenroom on your Mac, signed in to the same iCloud account: it sends its readings here. Or \(onThisIPhone) to read providers on this iPhone.")
        }
    }
}

enum PaceStyle {
    static func color(_ severity: Pace.Severity) -> Color {
        switch severity {
        case .critical: TokenroomTokens.criticalText
        case .tight: TokenroomTokens.accentText
        case .watch, .none: .secondary
        }
    }
}
