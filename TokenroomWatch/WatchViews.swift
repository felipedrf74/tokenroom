import SwiftUI

struct WatchRootView: View {
    var store: WatchStore
    var date: Date = .now
    @State private var path: [String] = []

    private var items: [ReadingCache.Item] { store.items(at: date) }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if items.isEmpty {
                    WatchEmptyView(store: store)
                } else {
                    List {
                        if store.problem == .unreachable {
                            Label("Couldn't reach iCloud. Showing saved readings.", systemImage: "icloud.slash")
                                .font(.footnote)
                        }
                        ForEach(items) { item in
                            NavigationLink(value: item.id) {
                                WatchRow(item: item, date: date)
                            }
                        }
                        Button(store.isRefreshing ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise") {
                            Task { await store.refresh(force: true) }
                        }.disabled(store.isRefreshing)
                        let stale = items.filter { !$0.provider.isLive }.count
                        if stale > 0 { Text("\(stale) stale reading\(stale == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary) }
                        if store.cache?.isSample == true {
                            Text("Sample data")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else if let checked = items.compactMap({ $0.provider.checkedAt ?? $0.provider.fetchedAt }).min() {
                            Text("Checked \(RelativeTime.ago(checked, now: date))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Tokenroom")
            .navigationDestination(for: String.self) { id in
                if let item = store.item(id: id, at: date) {
                    WatchDetailView(item: item, date: date)
                } else {
                    // Gone since it was opened (signed out of iCloud, aged out): say so, not a blank page.
                    Text("Couldn't find a reading for this provider.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .onOpenURL { url in
            // Complications and the Smart Stack link to a provider; the rest open the list.
            if case .provider(let id) = DeepLink(url) {
                store.openedProvider = id
            } else {
                store.openedProvider = nil
                path = []
            }
        }
        // Opened from a complication or the Smart Stack; if the readings aren't in yet, once they are.
        .onChange(of: store.openedProvider, initial: true) { _, _ in openRequestedProvider() }
        .onChange(of: items.map(\.id)) { _, _ in openRequestedProvider() }
    }

    private func openRequestedProvider() {
        guard let id = store.openedProvider, store.item(id: id, at: date) != nil else { return }
        path = [id]
        store.openedProvider = nil
    }
}

private struct WatchEmptyView: View {
    var store: WatchStore

    var body: some View {
        if store.isRefreshing {
            ProgressView()
        } else {
            ScrollView {
                VStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.title2)
                        .foregroundStyle(.tint)
                    Text(title)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    if offersConnect {
                        Button("Set up on iPhone", systemImage: "iphone") { store.openConnectOnPhone() }
                    }
                    Button("Retry", systemImage: "arrow.clockwise") { Task { await store.refresh(force: true) } }
                }
            }
        }
    }

    /// Only on the plain empty state, while the iPhone offers its connect screen and is reachable.
    private var offersConnect: Bool {
        store.problem == nil && store.canOpenConnectOnPhone
    }

    private var symbol: String {
        switch store.problem {
        case .noAccount: "person.crop.circle.badge.questionmark"
        case .unreachable: "icloud.slash"
        case nil: "gauge.with.dots.needle.50percent"
        }
    }

    private var title: String {
        switch store.problem {
        case .noAccount: "Sign in to iCloud"
        case .unreachable: "Couldn't reach iCloud"
        case nil: "No readings yet"
        }
    }

    private var message: String {
        switch store.problem {
        case .noAccount: "Use the same Apple Account on this Watch as on your iPhone and Mac."
        case .unreachable: "The Watch shows what your iPhone and Mac send through iCloud. It tries again soon."
        case nil where offersConnect: "Open Tokenroom on your iPhone."
        case nil: "Open Tokenroom on your iPhone or Mac. The Watch shows what they send through your iCloud."
        }
    }
}

private struct WatchRow: View {
    var item: ReadingCache.Item
    var date: Date

    var body: some View {
        let provider = item.provider
        let window = provider.primaryWindow
        HStack(spacing: 10) {
            if let window, window.isMetered {
                // The provider's icon in the ring; the row reads its name, so the ring has no label.
                UsageRing(used: window.used, isStale: !provider.isLive || window.isAwaitingReading(at: date), label: "")
                    .frame(width: 40, height: 40)
                    .overlay { ProviderMark(provider: provider, size: 22) }
            } else {
                ProviderMark(provider: provider, size: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(provider.shortName)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Spacer(minLength: 2)
                    Text(ReadingText.headline(window, now: date))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(headlineColor(window, isLive: provider.isLive, now: date))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let note = ReadingText.attention(provider, now: date),
                   UsageRanking.limitWarning(for: provider, now: date) != nil || window?.isAwaitingReading(at: date) != true {
                    Text(note).font(.caption2.weight(.semibold))
                        .foregroundStyle(UsageRanking.limitWarning(for: provider, now: date) == nil ? Color.secondary : TokenroomTokens.usageCritical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !provider.isLive, let checked = provider.checkedAt ?? provider.fetchedAt {
                    Text("Checked \(RelativeTime.ago(checked, now: date))").font(.caption2).foregroundStyle(.secondary)
                }
                if let window {
                    Text(ReadingText.reset(window, now: date) ?? window.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .opacity(provider.isLive ? 1 : 0.7)
        .accessibilityElement(children: .combine)
    }
}

struct WatchDetailView: View {
    var item: ReadingCache.Item
    var date: Date = .now

    var body: some View {
        let provider = item.provider
        List {
            if let plan = provider.plan {
                Text(plan)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let lead = provider.primaryWindow, lead.isMetered {
                let pace = UsageRanking.pace(for: lead, isStale: !provider.isLive, history: item.history[lead.id], now: date)
                HStack(spacing: 10) {
                    UsageRing(used: lead.used, isStale: !provider.isLive || lead.isAwaitingReading(at: date),
                              label: ReadingText.headline(lead, now: date), lineWidth: 6, paceMark: pace?.elapsedFraction)
                        .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(lead.displayTitle)
                            .font(.footnote.weight(.semibold))
                        if let detail = detail(lead, pace: pace) {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(pace?.needsAttention == true ? TokenroomTokens.accentText : .secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
            }
            ForEach(provider.windows.filter { !($0.id == provider.primaryWindow?.id && $0.isMetered) }) { window in
                let pace = window.isMetered ? UsageRanking.pace(for: window, isStale: !provider.isLive, history: item.history[window.id], now: date) : nil
                WindowRow(
                    title: window.displayTitle,
                    headline: ReadingText.headline(window, now: date),
                    usedPercent: window.isMetered ? window.used : nil,
                    isStale: !provider.isLive || window.isAwaitingReading(at: date),
                    paceMark: pace?.elapsedFraction,
                    caption: detail(window, pace: pace),
                    titleFont: .caption,
                    captionFont: .caption2
                )
                .padding(.vertical, 2)
            }
            if let banked = provider.banked, banked.available > 0 {
                Text(ReadingText.banked(banked, now: date))
                    .font(.footnote)
            }
            if let extra = provider.extra, let text = ReadingText.extra(extra) {
                Text(text)
                    .font(.footnote)
            }
            if let checked = provider.checkedAt ?? provider.fetchedAt {
                Text("Last successful check \(RelativeTime.ago(checked, now: date))").font(.footnote).foregroundStyle(.secondary)
            }
            Text(item.watchOriginLine)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .navigationTitle(provider.shortName)
    }

    /// "resets in 2h 10m · Ahead of pace".
    private func detail(_ window: RelayWindow, pace: Pace?) -> String? {
        var parts: [String] = []
        if let reset = ReadingText.reset(window, now: date) {
            parts.append(reset)
        }
        if let pace, pace.needsAttention {
            parts.append(pace.caption())
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private func headlineColor(_ window: RelayWindow?, isLive: Bool, now: Date = .now) -> Color {
    guard let window, window.isMetered else { return .primary }
    return TokenroomTokens.ink(remaining: 100 - window.used, isStale: !isLive || window.isAwaitingReading(at: now))
}
