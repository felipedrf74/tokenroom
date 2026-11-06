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
        } else if style != .classic, !showsDetails, case .expired(let hint, _?) = card.status {
            expiredRow(hint: hint)
        } else {
            plainCard
        }
    }

    /// Signed-out and loading rows keep the card's controls, without its box in a style's list.
    private var plainCard: ProviderCard {
        var plain = card
        plain.isPlain = style != .classic
        return plain
    }

    /// The same row as a live reading, grey, with what went wrong and how to fix it. It opens the
    /// provider's page like any row, for the last reading's other limits, credits, and plan.
    private func expiredRow(hint: String) -> some View {
        let window = reading.primaryWindow
        return VStack(alignment: .leading, spacing: 6) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    if let window, window.isMetered, style == .orbit {
                        ring(window, side: 60, dimmed: true)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        providerName(size: 14, icon: 20)
                        if let window {
                            Text("\(window.displayTitle) · last reading")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(hint).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let statusNote {
                            Text(statusNote).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if let window, style != .orbit {
                        PopoverValue(text: ReadingText.headline(window, now: card.date), size: window.isMetered ? 24 : 18, monospaced: style == .instrument)
                            .foregroundStyle(.secondary)
                            .opacity(TokenroomTokens.staleOpacity)
                    }
                    chevron
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the last reading and every limit")
            card.signInControls
                .padding(.leading, reading.primaryWindow?.isMetered == true && style == .orbit ? 74 : 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
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
            HStack(spacing: 14) {
                ring(window, side: 60, paceMark: listPace(window))
                VStack(alignment: .leading, spacing: 3) {
                    providerName(size: 14, icon: 20)
                    Text(ReadingText.caption(window, now: card.date))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    summaryNote(window)
                }
                Spacer(minLength: 0)
                chevron
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 20)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    providerName(size: 14, icon: 22)
                    Spacer(minLength: 4)
                    headline(window, size: window.isMetered ? 24 : 18)
                        .fixedSize(horizontal: window.isMetered, vertical: false)
                        .layoutPriority(1)
                    chevron
                }
                if window.isMetered {
                    PopoverMeter(style: style, used: window.used, isStale: isDimmed(window), paceMark: listPace(window), height: style == .strata ? 10 : 7)
                }
                Text(ReadingText.caption(window, now: card.date))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                summaryNote(window)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    /// The even pace on a list row's ring or meter, as Classic's cards show it.
    private func listPace(_ window: RelayWindow) -> Double? {
        isDimmed(window) ? nil : card.pace?.elapsedFraction
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

    private func ring(_ window: RelayWindow, side: CGFloat, dimmed: Bool = false, paceMark: Double? = nil) -> some View {
        let dimmed = dimmed || isDimmed(window)
        // UsageRing's stroke straddles its frame; leave room for its cap on every side.
        let inset = max(3, side * 0.05)
        return UsageRing(used: window.used, isStale: dimmed, label: "", lineWidth: side * 0.095, paceMark: paceMark)
            .frame(width: side - inset * 2, height: side - inset * 2).padding(inset)
            .overlay {
                PopoverValue(text: ReadingText.headline(window, now: card.date), size: side * 0.3)
                    .foregroundStyle(dimmed ? Color.secondary : TokenroomTokens.ink(remaining: 100 - window.used, isStale: false))
            }
            .opacity(dimmed ? TokenroomTokens.staleOpacity : 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(ReadingText.headline(window, now: card.date)) used")
    }

    private func detail(_ snapshot: QuotaSnapshot, window: RelayWindow) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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
                UsageFactsGrid(facts: facts, labelFont: .system(size: 11),
                               valueFont: .system(size: 20, weight: .medium), detailFont: .system(size: 11),
                               isStale: isDimmed(window))
            }
            if window.isMetered, let history = card.weeks[window.id], !history.isEmpty {
                historyChart(history, window: window)
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

    /// The header above names the provider, so the hero is only the reading.
    @ViewBuilder private func hero(_ window: RelayWindow) -> some View {
        if style == .orbit || style == .aurora, window.isMetered {
            HStack(spacing: 18) {
                ring(window, side: 96, paceMark: listPace(window))
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(window.displayTitle) used").font(.system(size: 13)).foregroundStyle(.secondary)
                    if let reset = ReadingText.reset(window, now: card.date) {
                        Text(reset.capitalizedFirst).font(.system(size: 15, weight: .medium))
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                headline(window, size: window.isMetered ? 44 : 30)
                if window.isMetered {
                    PopoverMeter(style: style, used: window.used, isStale: isDimmed(window), height: style == .strata ? 14 : 9)
                }
                Text(ReadingText.caption(window, now: card.date)).font(.system(size: 13)).foregroundStyle(.secondary)
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
                PopoverMeter(style: style, used: window.used, isStale: false, paceMark: pace.elapsedFraction, height: 7)
                Text("\(PopoverInsights.paceDetail(pace)), with \(TokenroomFormat.percentText(pace.elapsedFraction * 100))% of the period elapsed.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if pace.runsOutAt != nil {
                    Text("Run-out is an estimate at the observed pace; future usage can change it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// The chart's one colour: its latest reading's level, on a current reading only.
    private func level(for history: UsageHistory, window: RelayWindow) -> Color? {
        guard !isDimmed(window), let latest = history.points.last?.used else { return nil }
        return TokenroomTokens.usageColor(usedPercent: latest, isStale: false)
    }

    private func historyChart(_ history: UsageHistory, window: RelayWindow) -> some View {
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
                Sparkline(history: history, level: level(for: history, window: window))
            }.frame(height: 60)
            Text(Sparkline.summary(history)).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Quota used over the last 7 days")
        .accessibilityValue(Sparkline.summary(history))
    }

    private func secondaryWindow(_ window: RelayWindow) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(window.displayTitle).font(.system(size: 13, weight: .medium))
                Spacer()
                headline(window, size: 18)
            }
            if window.isMetered {
                PopoverMeter(style: style, used: window.used, isStale: isDimmed(window),
                             paceMark: isDimmed(window) ? nil : card.windowPaces[window.id]?.elapsedFraction, height: style == .strata ? 10 : 7)
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
        // When it was checked is in the header, for this provider.
        VStack(alignment: .leading, spacing: 6) {
            if snapshot.planLabel != nil || ProviderCard.sourceCaption(snapshot) != nil || ProviderCard.readsUnofficially(card.provider, snapshot: snapshot) { Divider() }
            if let plan = snapshot.planLabel { Text("Plan · \(plan)") }
            if let source = ProviderCard.sourceCaption(snapshot) { Text(source) }
            if ProviderCard.readsUnofficially(card.provider, snapshot: snapshot) {
                Text("Unofficial: read from the same endpoint \(card.provider.toolName) uses. It can change without notice.")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
