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
            Section {
                header
            }
            ForEach(Array(orderedWindows.enumerated()), id: \.element.id) { index, window in
                Section(window.displayTitle) {
                    WindowDetail(
                        window: window,
                        history: reading.history[window.id],
                        checkedAt: provider.checkedAt ?? provider.fetchedAt,
                        isStale: !provider.isLive || window.isAwaitingReading(at: date),
                        tint: Color(hex: provider.tint),
                        date: date,
                        // The hero above already shows the first metered window's number and facts.
                        isLead: index == 0 && heroWindow?.id == window.id
                    )
                }
                if index == 0, let candidate = LiveActivities.candidate(in: provider, now: date) {
                    Section {
                        FollowButton(provider: provider) { followError = $0 }
                    } footer: {
                        Text(followError ?? "Shows a countdown to the \(candidate.displayTitle.lowercased()) reset on the Lock Screen and in the Dynamic Island until it resets.")
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
                    Text("The line on each meter marks an even pace: where usage would be if spread evenly across the window. Tokenroom isn't affiliated with \(provider.name).")
                }
            }
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
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
            nameRow
            if let window = heroWindow {
                let stale = !provider.isLive || window.isAwaitingReading(at: date)
                HStack(spacing: 16) {
                    UsageRing(used: window.used, isStale: stale, label: ReadingText.headline(window, now: date), lineWidth: 10, paceMark: heroPace?.elapsedFraction)
                        .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(window.displayTitle)
                            .font(.headline)
                        Text(window.isAwaitingReading(at: date) ? "Reset · awaiting reading" : "\(TokenroomFormat.percentText(100 - window.used))% left")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let amount = window.amount, let detail = ReadingText.amountDetail(amount) {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        if !stale, let forecast = Forecast.text(for: window, history: reading.history[window.id], checkedAt: provider.checkedAt ?? provider.fetchedAt, now: date) {
                            Text(forecast)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
            // The last check is at the bottom, with where the reading came from.
            let facts = UsageFacts.facts(for: heroWindow, pace: heroPace, plan: provider.plan, checkedAt: nil, isStale: !provider.isLive, now: date)
            if !facts.isEmpty {
                UsageFactsGrid(facts: facts, columns: facts.count == 3 && typeSize < .xxLarge ? 3 : 2)
            }
        }
        .padding(.vertical, 6)
    }

    /// The provider and, when the reading isn't current, why. Plan and last check are facts below.
    private var nameRow: some View {
        HStack(spacing: 14) {
            ProviderMark(provider: provider, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.name)
                    .font(.title3.weight(.semibold))
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
    var tint: Color
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
                HistoryChart(history: history, tint: tint)
                    .frame(height: 120)
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
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
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
                MeterTrack(usedPercent: window.used, remaining: 100 - window.used, isStale: isStale || window.isAwaitingReading(at: date), paceMark: pace?.elapsedFraction, height: 10)
            }
            if let pace {
                Text(pace.caption(now: date))
                    .font(.subheadline.weight(.medium))
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
    var tint: Color

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
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Hour", point.date), y: .value("Used", point.used))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
            }
            // When the window reset during the week.
            ForEach(history.resets ?? [], id: \.self) { reset in
                RuleMark(x: .value("Reset", reset))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityLabel("Reset")
                    .accessibilityValue(reset.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.weekday(.narrow))
            }
        }
        .accessibilityLabel("Usage over the last 7 days")
    }
}
