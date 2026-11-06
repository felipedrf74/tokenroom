import Charts
import SwiftUI

struct ProviderDetailView: View {
    var reading: MobileStore.Reading
    var date: Date = .now
    @State private var followError: String?
    @Environment(\.dynamicTypeSize) private var typeSize

    private var provider: RelayProvider { reading.provider }

    /// The window the provider leads with, then the rest.
    private var orderedWindows: [RelayWindow] {
        guard let primary = provider.primaryWindow else { return provider.windows }
        return [primary] + provider.windows.filter { $0.id != primary.id }
    }

    var body: some View {
        List {
            // A balance has no ring to lead with: its section carries the mark instead of a card
            // of its own.
            if heroWindow != nil {
                Section {
                    header
                }
            }
            ForEach(Array(orderedWindows.enumerated()), id: \.element.id) { index, window in
                Section(window.displayTitle) {
                    if heroWindow == nil, index == 0 {
                        sourceRow
                    }
                    WindowDetail(
                        window: window,
                        history: reading.history[window.id],
                        checkedAt: provider.checkedAt ?? provider.fetchedAt,
                        isStale: !provider.isLive || window.isAwaitingReading(at: date),
                        date: date,
                        // The hero above already shows the first metered window's number and facts.
                        isLead: index == 0 && heroWindow?.id == window.id
                    )
                }
                if index == 0, let candidate = LiveActivities.candidate(in: provider, now: date) {
                    Section {
                        FollowButton(provider: provider) { followError = $0 }
                    } footer: {
                        Text(followError ?? "Shows a countdown to the \(WindowNames.inSentence(candidate.displayTitle)) reset on the Lock Screen and in the Dynamic Island until it resets.")
                    }
                }
            }
            if let banked = provider.banked, banked.available > 0 {
                Section {
                    Text(ReadingText.banked(banked, now: date))
                    ForEach(banked.expiries.filter { $0 > date }.sorted(), id: \.self) { expiry in
                        LabeledContent("Expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("Banked resets")
                } footer: {
                    Text("A banked reset clears a limit early. Use one from \(provider.shortName) when a limit runs out; Tokenroom only shows them.")
                }
            }
            if let extra = provider.extra, let text = ReadingText.extra(extra) {
                Section("Beyond the plan") {
                    Text(text)
                }
            }
            Section {
                LabeledContent("From", value: reading.source)
                if let checked = provider.checkedAt ?? provider.fetchedAt {
                    LabeledContent("Last successful check", value: RelativeTime.ago(checked, now: date))
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reading.source == SampleData.sourceLabel ? "Sample data" : reading.origin.phrase)
                    Text((provider.windows.contains(where: \.isMetered) ? "The line on each meter marks an even pace: where usage would be if spread evenly across the window. " : "") + "Tokenroom isn't affiliated with \(provider.name).")
                }
            }
        }
        // The name once, as the page's title, rather than in the bar and again in the hero.
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.large)
    }

    /// The window the hero ring shows: the lead window, when it has a meter.
    private var heroWindow: RelayWindow? {
        orderedWindows.first.flatMap { $0.isMetered ? $0 : nil }
    }

    private var heroPace: Pace? {
        heroWindow.flatMap { UsageRanking.pace(for: $0, isStale: !provider.isLive, history: reading.history[$0.id], now: date) }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            sourceRow
            if let window = heroWindow {
                let stale = !provider.isLive || window.isAwaitingReading(at: date)
                HStack(spacing: 16) {
                    UsageRing(used: window.used, isStale: stale, label: ReadingText.headline(window, now: date), lineWidth: 9, paceMark: heroPace?.elapsedFraction)
                        .frame(width: 100, height: 100)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(window.displayTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if window.isAwaitingReading(at: date) {
                            Text("Reset · awaiting reading")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        } else {
                            // What's left: the ring's used figure and this add up.
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                HeadlineValue("\(TokenroomFormat.percentText(100 - window.used))%", style: .title3, signStyle: .footnote, weight: .medium)
                                Text("left")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityElement(children: .combine)
                amountLines(window, isStale: stale)
            }
            // The last check is at the bottom, with where the reading came from.
            let facts = UsageFacts.facts(for: heroWindow, pace: heroPace, plan: provider.plan, checkedAt: nil, isStale: !provider.isLive, now: date)
            if !facts.isEmpty {
                Divider()
                UsageFactsGrid(facts: facts, columns: facts.count == 3 && typeSize < .xxLarge ? 3 : 2, labelFont: .caption, valueFont: .subheadline.weight(.medium), detailFont: .caption, detailLines: 1)
            }
        }
        .padding(.vertical, 6)
    }

    /// The amount and its forecast take the card's width, so a sentence ends where it should.
    @ViewBuilder
    private func amountLines(_ window: RelayWindow, isStale: Bool) -> some View {
        let forecast = isStale ? nil : Forecast.text(for: window, history: reading.history[window.id], checkedAt: provider.checkedAt ?? provider.fetchedAt, now: date)
        let amount = window.amount.flatMap { ReadingText.amountDetail($0) }
        if amount != nil || forecast != nil {
            VStack(alignment: .leading, spacing: 2) {
                if let amount {
                    Text(amount).font(.subheadline)
                }
                if let forecast {
                    Text(forecast).font(.footnote).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    /// Whose reading this is and, when it isn't current, why. The title above names the provider;
    /// plan and last check are facts below.
    private var sourceRow: some View {
        HStack(spacing: 10) {
            ProviderMark(provider: provider, size: 28)
            if !provider.isLive, let message = provider.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let category = categoryLine {
                Text(category)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var categoryLine: String? {
        switch provider.category {
        case "subscription": "Subscription"
        case "apiBalance": "Pay as you go"
        case "orgSpend": "Organization billing"
        default: nil
        }
    }
}

private struct WindowDetail: View {
    var window: RelayWindow
    var history: UsageHistory?
    /// When the reading was last confirmed, so a month's spend projects from then.
    var checkedAt: Date?
    var isStale: Bool
    var date: Date
    /// Shown in the hero above: only the week's chart is left to show here.
    var isLead = false

    private var pace: Pace? {
        window.isMetered ? UsageRanking.pace(for: window, isStale: isStale, history: history, now: date) : nil
    }

    var body: some View {
        if !isLead {
            summary
        }
        if let history, !history.isEmpty, window.isMetered {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last 7 days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HistoryChart(history: history, level: isStale ? nil : history.points.last.map { TokenroomTokens.usageColor(usedPercent: $0.used, isStale: false) })
                    .frame(height: 110)
            }
            .padding(.vertical, 4)
        } else if isLead {
            Text(ReadingText.reset(window, now: date) ?? window.displayTitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(ReadingText.headline(window, now: date))
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.isMetered ? TokenroomTokens.ink(remaining: 100 - window.used, isStale: isStale) : .primary)
                if window.isMetered, !window.isAwaitingReading(at: date) {
                    Text("used")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let amount = window.amount, let detail = ReadingText.amountDetail(amount), detail != ReadingText.headline(window, now: date) {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if window.isMetered {
                MeterTrack(usedPercent: window.used, remaining: 100 - window.used, isStale: isStale || window.isAwaitingReading(at: date), paceMark: pace?.elapsedFraction, height: 7)
            }
            if let pace {
                Text(pace.caption(now: date))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(PaceStyle.color(pace.severity))
            }
            if !isStale, let forecast = Forecast.text(for: window, history: history, checkedAt: checkedAt, now: date) {
                Text(forecast)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)

        if window.isAwaitingReading(at: date) {
            Text("Reset · awaiting reading").font(.footnote).foregroundStyle(.secondary)
        } else if let resetsAt = window.resetsAt {
            LabeledContent("Resets") {
                VStack(alignment: .trailing) {
                    Text(resetsAt.formatted(date: .abbreviated, time: .shortened))
                    if let relative = RelativeTime.resets(resetsAt, now: date) {
                        Text(relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private struct HistoryChart: View {
    var history: UsageHistory
    /// The latest reading's level, for its dot: a chart's one colour. Nil on a stale reading.
    var level: Color?

    private struct Point: Identifiable {
        var date: Date
        var used: Double
        var id: Date { date }
    }

    var body: some View {
        let points = history.points.map { Point(date: $0.date, used: $0.used) }
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Hour", point.date), y: .value("Used", point.used))
                    .foregroundStyle(TokenroomTokens.chartArea)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Hour", point.date), y: .value("Used", point.used))
                    .foregroundStyle(TokenroomTokens.chartLine)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let level, let latest = points.last {
                PointMark(x: .value("Hour", latest.date), y: .value("Used", latest.used))
                    .foregroundStyle(level)
                    .symbolSize(32)
            }
            // When the window reset during the week.
            ForEach(history.resets ?? [], id: \.self) { reset in
                RuleMark(x: .value("Reset", reset))
                    .foregroundStyle(Color.primary.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityLabel("Reset")
                    .accessibilityValue(reset.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine().foregroundStyle(TokenroomTokens.track)
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.narrow))
            }
        }
        .accessibilityLabel("Usage over the last 7 days")
    }
}
