import SwiftUI

/// All styles consume the same presentation status and clock as the original card. The original
/// sign-in/error controls remain the fallback when there is no usable connected reading.
struct PopoverProviderView: View {
    var card: ProviderCard
    var style: PopoverStyle
    var showsDetails = false
    var onOpen: () -> Void = {}
    @State private var isHovered = false

    private var reading: RelayProvider {
        RelayProvider(provider: card.provider, status: card.status, checkedAt: card.checkedAt)
    }

    var body: some View {
        if Self.usesStyledReading(card.status), let snapshot = card.status.snapshot, let window = reading.primaryWindow {
            if showsDetails {
                detail(snapshot, window: window)
            } else {
                Button(action: onOpen) {
                    summary(window)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(isHovered ? 0.045 : 0))
                .onHover { isHovered = $0 }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summaryAccessibility(window))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Opens usage insights and every limit")
                .help("Show \(card.provider.displayName) details")
            }
        } else {
            card
        }
    }

    /// Cached values do not imply a working session. Expired sessions must keep their recovery
    /// controls throughout the cache grace period, in the overview and in an already-open detail.
    static func usesStyledReading(_ status: ProviderStatus) -> Bool {
        if case .expired = status { return false }
        return !status.isDisconnected && status.snapshot != nil
    }

    func summaryAccessibility(_ window: RelayWindow) -> String {
        [card.provider.displayName, ReadingText.headline(window, now: card.date),
         window.isMetered ? "used" : nil, ReadingText.caption(window, now: card.date),
         attention, primaryPaceWarning(window), statusNote].compactMap { $0 }.joined(separator: ", ")
    }

    private func primaryPaceWarning(_ window: RelayWindow) -> String? {
        guard attention == nil, !isDimmed(window), let pace = card.pace, !pace.isProjected, pace.needsAttention else { return nil }
        return pace.verdict == .limitReached ? "Limit reached" : "Ahead of pace"
    }

    private var attention: String? {
        ReadingText.attention(reading, now: card.date, lead: reading.primaryWindow)
    }

    private var statusNote: String? {
        ProviderCard.compactNote(card.status, provider: card.provider, checkedAt: card.checkedAt, now: card.date)?.text
    }

    private func isDimmed(_ window: RelayWindow) -> Bool {
        card.status.isStale || window.isAwaitingReading(at: card.date)
    }

    private func tint(_ window: RelayWindow) -> Color {
        TokenroomTokens.ink(remaining: window.isMetered ? 100 - window.used : 100, isStale: isDimmed(window))
    }

    @ViewBuilder private func summary(_ window: RelayWindow) -> some View {
        if style == .orbit, window.isMetered {
            HStack(spacing: 20) {
                ring(window, side: 96)
                VStack(alignment: .leading, spacing: 7) {
                    providerName(size: 16, icon: 28)
                    Text(ReadingText.reset(window, now: card.date)?.capitalizedFirst ?? window.displayTitle)
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text(window.displayTitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    summaryNote(window)
                }
                Spacer(minLength: 0)
                chevron
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 20)
        } else {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 12) {
                    providerName(size: 16, icon: 32)
                    Spacer(minLength: 4)
                    headline(window, size: window.isMetered ? 36 : 25)
                        .fixedSize(horizontal: window.isMetered, vertical: false)
                        .layoutPriority(1)
                    chevron
                }
                if window.isMetered {
                    PopoverMeter(style: style, used: window.used, isStale: isDimmed(window), height: style == .strata ? 18 : 11)
                }
                Text(ReadingText.caption(window, now: card.date))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                summaryNote(window)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(style == .strata ? Color.primary.opacity(0.025) : .clear)
        }
    }

    @ViewBuilder private func summaryNote(_ window: RelayWindow) -> some View {
        if let attention, attention != ReadingText.reset(window, now: card.date) {
            Text(attention).font(.system(size: 12, weight: .medium))
                .foregroundStyle(UsageRanking.limitWarning(for: reading, now: card.date) == nil ? Color.secondary : TokenroomTokens.criticalText)
                .fixedSize(horizontal: false, vertical: true)
        } else if let warning = primaryPaceWarning(window) {
            Text(warning).font(.system(size: 12, weight: .medium))
                .foregroundStyle(TokenroomTokens.accentText).fixedSize(horizontal: false, vertical: true)
        }
        if let statusNote {
            Text(statusNote).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func providerName(size: CGFloat, icon: CGFloat) -> some View {
        HStack(spacing: 10) {
            ProviderIcon(provider: card.provider, size: icon)
            Text(card.provider.displayName).font(.system(size: size, weight: .semibold))
                .foregroundStyle(card.status.isStale ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary).accessibilityHidden(true)
    }

    private func headline(_ window: RelayWindow, size: CGFloat) -> some View {
        PopoverValue(text: ReadingText.headline(window, now: card.date), size: size, monospaced: style == .instrument)
            .foregroundStyle(tint(window)).lineLimit(1).minimumScaleFactor(0.65)
    }

    private func ring(_ window: RelayWindow, side: CGFloat) -> some View {
        UsageRing(used: window.used, isStale: isDimmed(window), label: "", lineWidth: side * 0.085)
            // UsageRing's stroke straddles its frame; leave room for its cap on every side.
            .frame(width: side - 10, height: side - 10).padding(5)
            .overlay {
                PopoverValue(text: ReadingText.headline(window, now: card.date), size: side * 0.34)
                    .foregroundStyle(isDimmed(window) ? Color.secondary : Color.primary)
            }
            .opacity(isDimmed(window) ? TokenroomTokens.staleOpacity : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(ReadingText.headline(window, now: card.date)) used")
    }

    private func detail(_ snapshot: QuotaSnapshot, window: RelayWindow) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            hero(window)
            if let attention {
                Text(attention).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UsageRanking.limitWarning(for: reading, now: card.date) == nil ? Color.secondary : TokenroomTokens.criticalText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let statusNote {
                Label(statusNote, systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let facts = PopoverInsights.facts(window: window, isStale: card.status.isStale, now: card.date)
            if !facts.isEmpty {
                UsageFactsGrid(facts: facts, labelFont: .system(size: 10, weight: .medium),
                               valueFont: .system(size: 23, weight: .semibold), detailFont: .system(size: 11))
            }
            if window.isMetered, let history = card.weeks[window.id], !history.isEmpty {
                historyChart(history)
            }
            if !card.status.isStale, let forecast = Forecast.text(for: window, history: card.weeks[window.id], checkedAt: card.checkedAt ?? snapshot.fetchedAt, now: card.date) {
                Label(forecast, systemImage: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            if !window.isAwaitingReading(at: card.date), let pace = card.pace {
                paceComparison(window, pace: pace)
            }
            ForEach(reading.windows.dropFirst()) { secondary in
                Divider()
                secondaryWindow(secondary)
            }
            if let banked = snapshot.banked, banked.available > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label(ReadingText.banked(banked, now: card.date), systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .medium))
                    Text("Use one in \(card.provider.toolName) to reset a limit early.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach(banked.expiries.filter { $0 > card.date }.sorted(), id: \.self) { expiry in
                        Text("Expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            if let extra = snapshot.extra, let text = ReadingText.extra(extra) {
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            metadata(snapshot)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func hero(_ window: RelayWindow) -> some View {
        if style == .orbit, window.isMetered {
            VStack(spacing: 12) {
                providerName(size: 19, icon: 34)
                ring(window, side: 128)
                Text("\(window.displayTitle) used").font(.system(size: 13)).foregroundStyle(.secondary)
                if let reset = ReadingText.reset(window, now: card.date) {
                    Text(reset.capitalizedFirst).font(.system(size: 15, weight: .medium))
                }
            }.frame(maxWidth: .infinity)
        } else if style == .aurora, window.isMetered {
            VStack(alignment: .leading, spacing: 16) {
                providerName(size: 19, icon: 36)
                HStack(spacing: 22) {
                    ring(window, side: 138)
                    Text(ReadingText.caption(window, now: card.date)).font(.system(size: 14))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                providerName(size: 19, icon: 36)
                headline(window, size: window.isMetered ? 58 : 34)
                if window.isMetered {
                    PopoverMeter(style: style, used: window.used, isStale: isDimmed(window), height: style == .strata ? 28 : 13)
                }
                Text(ReadingText.caption(window, now: card.date)).font(.system(size: 14)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func paceComparison(_ window: RelayWindow, pace: Pace) -> some View {
        if pace.isProjected {
            Text(pace.caption(now: card.date)).font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        } else if !card.status.isStale {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Usage vs. time").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(pace.caption(now: card.date)).font(.system(size: 12))
                        .foregroundStyle(pace.needsAttention ? TokenroomTokens.accentText : Color.secondary)
                }
                PopoverMeter(style: style, used: window.used, isStale: false, paceMark: pace.elapsedFraction, height: 9)
                Text(PopoverInsights.paceDetail(pace)).font(.system(size: 12)).foregroundStyle(.secondary)
                Text("The marker shows \(TokenroomFormat.percentText(pace.elapsedFraction * 100))% of the period elapsed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                if let runOut = pace.runsOutAt {
                    Label("Projected limit: \(Pace.shortMoment(runOut, now: card.date, timeZone: .current))", systemImage: "hourglass")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(TokenroomTokens.accentText)
                    Text("Estimate at the observed pace; future usage can change it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func historyChart(_ history: UsageHistory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Last 7 days").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Quota used").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                VStack {
                    Text("100%")
                    Spacer()
                    Text("0%")
                }.font(.system(size: 9)).foregroundStyle(.secondary)
                Sparkline(history: history, tint: style == .instrument ? TokenroomTokens.usageHealthy : Color(hex: card.provider.tintHex), lineWidth: 2)
            }.frame(height: 68)
            Text(Sparkline.summary(history)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quota used over the last 7 days")
        .accessibilityValue(Sparkline.summary(history))
    }

    private func secondaryWindow(_ window: RelayWindow) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(window.displayTitle).font(.system(size: 14, weight: .medium))
                Spacer()
                headline(window, size: 25)
            }
            if window.isMetered {
                PopoverMeter(style: style, used: window.used, isStale: isDimmed(window),
                             paceMark: isDimmed(window) ? nil : card.windowPaces[window.id]?.elapsedFraction, height: style == .strata ? 15 : 9)
            }
            if let reset = ReadingText.reset(window, now: card.date) {
                Text(reset.capitalizedFirst).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !isDimmed(window), let pace = card.windowPaces[window.id] {
                Text(pace.caption(now: card.date)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.accessibilityElement(children: .combine)
    }

    private func metadata(_ snapshot: QuotaSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let plan = snapshot.planLabel { Text("Plan · \(plan)") }
            Text("Checked \(RelativeTime.ago(card.checkedAt ?? snapshot.fetchedAt, now: card.date))")
            if let source = ProviderCard.sourceCaption(snapshot) { Text(source) }
            if ProviderCard.readsUnofficially(card.provider, snapshot: snapshot) {
                Text("Unofficial: read from the same endpoint \(card.provider.toolName) uses. It can change without notice.")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
