import SwiftUI
import WidgetKit

struct UsageWidgetView: View {
    var entry: ReadingsEntry
    @Environment(\.widgetFamily) private var systemFamily
    @Environment(\.widgetPreviewStyle) private var preview

    private var family: WidgetFamily {
        preview?.family ?? systemFamily
    }

    var body: some View {
        content
            .redacted(reason: entry.isPlaceholder ? .placeholder : [])
            .containerBackground(isAccessory ? AnyShapeStyle(.clear) : AnyShapeStyle(.background), for: .widget)
    }

    private var isAccessory: Bool {
        [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
    }

    nonisolated static func rows(in family: WidgetFamily) -> Int {
        switch family {
        case .systemMedium: 4
        case .systemLarge: 8
        case .accessoryRectangular, .accessoryInline: 3
        default: 1
        }
    }

    @ViewBuilder
    private var content: some View {
        if let first = entry.items.first {
            switch family {
            case .systemMedium:
                if entry.style.usesTiles(isSmall: false) {
                    TilesWidget(entry: entry, count: Self.rows(in: .systemMedium), showsSecond: false)
                } else {
                    ListWidget(entry: entry, count: Self.rows(in: .systemMedium), showsHistory: false)
                }
            case .systemLarge:
                if entry.style.usesTiles(isSmall: false) {
                    TilesWidget(entry: entry, count: Self.rows(in: .systemLarge), showsSecond: true)
                } else {
                    ListWidget(entry: entry, count: Self.rows(in: .systemLarge), showsHistory: true)
                }
            case .accessoryCircular:
                CircularWidget(item: first, isSample: entry.isSample, date: entry.date)
            case .accessoryRectangular:
                RectangularWidget(items: Array(entry.items.prefix(Self.rows(in: .accessoryRectangular))), date: entry.date, isSample: entry.isSample)
            case .accessoryInline:
                InlineWidget(items: Array(entry.items.prefix(Self.rows(in: .accessoryInline))), isSample: entry.isSample, date: entry.date)
                    .widgetURL(DeepLink.provider(first.id).url)
            default:
                SmallWidget(entry: entry, item: first, showsSecond: entry.style.usesTiles(isSmall: true))
            }
        } else {
            EmptyWidget(isAccessory: isAccessory, provider: entry.unavailableProvider, allHidden: entry.allHidden)
        }
    }
}

private struct RowReading {
    var provider: RelayProvider
    var window: RelayWindow?
    var pace: Double?
    var isAwaiting: Bool
    var limitReached: Bool

    init(_ item: ReadingCache.Item, date: Date) {
        provider = item.provider
        let lead = provider.leadWindow(now: date, history: item.history)
        window = lead
        isAwaiting = lead?.isAwaitingReading(at: date) == true
        limitReached = item.provider.isLive && lead.map { $0.isMetered && $0.used >= 100 } == true && !isAwaiting
        pace = lead.flatMap { UsageRanking.pace(for: $0, isStale: !item.provider.isLive, history: item.history[$0.id], now: date)?.elapsedFraction }
    }

    var isFaded: Bool { !provider.isLive || isAwaiting }
}

private struct RowStatus: View {
    var reading: RowReading
    var date: Date

    var body: some View {
        if reading.limitReached {
            Text("Limit reached")
                .fontWeight(.semibold)
                .foregroundStyle(TokenroomTokens.criticalText)
        } else if reading.isAwaiting {
            Text("Reset")
        } else if !reading.provider.isLive {
            Text("Stale")
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
        } else if let resetsAt = reading.window?.resetsAt, resetsAt > date {
            ResetCountdown(resetsAt: resetsAt, date: date)
        }
    }
}

private struct WidgetHeader: View {
    var entry: ReadingsEntry
    var shown: Int

    var body: some View {
        let stale = entry.items.prefix(shown).filter { !$0.provider.isLive }.count
        HStack(spacing: 4) {
            if entry.isSample {
                SampleTag()
            } else if let checked = entry.checkedAt(first: shown) {
                Text("Updated \(Self.time(checked, now: entry.date))")
            } else {
                Text("Usage")
            }
            if let hidden = entry.limitReached(beyond: shown) {
                Text("· \(hidden.provider.name) limit reached")
                    .fontWeight(.semibold)
                    .foregroundStyle(TokenroomTokens.criticalText)
            } else if stale > 0 {
                Text("· \(stale) stale")
            } else if entry.items.count > shown {
                Text("· +\(entry.items.count - shown) more")
            }
            Spacer(minLength: 0)
            Button(intent: RefreshReadingsIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh")
        }
        .font(.caption2)
        .lineLimit(1)
        .foregroundStyle(.secondary)
    }

    static func time(_ checked: Date, now: Date) -> String {
        Calendar.current.isDate(checked, inSameDayAs: now)
            ? checked.formatted(date: .omitted, time: .shortened)
            : checked.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct SecondWindowLine: View {
    var window: RelayWindow
    var isStale: Bool

    var body: some View {
        HStack(spacing: 5) {
            Text(window.displayTitle)
                .lineLimit(1)
            WidgetMeter(used: window.used, isStale: isStale, height: 3)
            Text("\(TokenroomFormat.percentText(window.used))%")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct SmallWidget: View {
    var entry: ReadingsEntry
    var item: ReadingCache.Item
    var showsSecond: Bool

    var body: some View {
        let reading = RowReading(item, date: entry.date)
        let provider = reading.provider
        let window = reading.window
        let second = showsSecond && provider.isLive && !reading.isAwaiting ? window.flatMap { provider.secondWindow(lead: $0, now: entry.date) } : nil
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                if provider.name != provider.shortName {
                    header(provider, name: provider.name)
                }
                header(provider, name: provider.shortName)
            }
            Spacer(minLength: 0)
            Text(ReadingText.headline(window, now: entry.date))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .foregroundStyle(headlineStyle(window, isLive: provider.isLive))
                .widgetAccentable()
            if let window {
                if window.isMetered {
                    WidgetMeter(used: window.used, isStale: reading.isFaded, pace: reading.pace, isAwaitingReading: reading.isAwaiting)
                }
                if let second {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(window.displayTitle)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Spacer(minLength: 2)
                        RowStatus(reading: reading, date: entry.date)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    SecondWindowLine(window: second, isStale: false)
                } else {
                    Text(window.displayTitle)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    ResetText(window: window, date: entry.date)
                }
            }
            if second == nil {
                if let note = ReadingText.attention(provider, now: entry.date, lead: window),
                   UsageRanking.limitWarning(for: provider, now: entry.date) != nil || !reading.isAwaiting {
                    Text(note).font(.caption2.weight(.semibold))
                        .foregroundStyle(UsageRanking.limitWarning(for: provider, now: entry.date) == nil ? Color.secondary : TokenroomTokens.criticalText).lineLimit(2)
                }
                if !provider.isLive {
                    Text("Stale · checked \(RelativeTime.ago(provider.checkedAt ?? provider.fetchedAt, now: entry.date))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .widgetURL(DeepLink.provider(provider.id).url)
    }

    private func header(_ provider: RelayProvider, name: String) -> some View {
        HStack(spacing: 6) {
            ProviderMark(provider: provider, size: 20)
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            if entry.isSample {
                SampleTag()
            }
        }
    }
}

private struct ListWidget: View {
    var entry: ReadingsEntry
    var count: Int
    var showsHistory: Bool

    var body: some View {
        let rows = Array(entry.items.prefix(count))
        let roomy = rows.count <= (showsHistory ? 5 : 2)
        let charted = showsHistory && rows.count <= 3
        let history = showsHistory && rows.contains { item in
            item.provider.leadWindow(now: entry.date, history: item.history).flatMap { item.history[$0.id] }?.isEmpty == false
        }
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(entry: entry, shown: count)
            ForEach(rows) { item in
                Link(destination: DeepLink.provider(item.id).url) {
                    ListRow(item: item, date: entry.date, showsHistory: history && !charted, roomy: roomy, isLarge: showsHistory, charted: charted)
                        .frame(maxHeight: roomy && showsHistory && !charted ? 76 : .infinity)
                }
                .foregroundStyle(.primary)
            }
            if roomy, showsHistory, !charted {
                Spacer(minLength: 0)
            }
        }
    }
}

private struct ListRow: View {
    var item: ReadingCache.Item
    var date: Date
    var showsHistory: Bool
    var roomy: Bool
    var isLarge: Bool
    var charted = false

    var body: some View {
        let reading = RowReading(item, date: date)
        let provider = reading.provider
        HStack(alignment: charted ? .top : .center, spacing: 8) {
            ProviderMark(provider: provider, size: roomy ? 24 : 18)
            VStack(alignment: .leading, spacing: 3) {
                ViewThatFits(in: .horizontal) {
                    if provider.name != provider.shortName {
                        line(reading, name: provider.name)
                    }
                    line(reading, name: provider.shortName)
                }
                if let window = reading.window, window.isMetered {
                    WidgetMeter(used: window.used, isStale: reading.isFaded, pace: reading.pace, height: roomy ? 6 : 5, isAwaitingReading: reading.isAwaiting)
                }
                if roomy, let window = reading.window {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(window.displayTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        status(reading)
                    }
                    let second = isLarge && provider.isLive ? provider.secondWindow(lead: window, now: date) : nil
                    if let second {
                        SecondWindowLine(window: second, isStale: false)
                    }
                    if charted, let series = item.history[window.id], !series.isEmpty {
                        Sparkline(history: series, lineWidth: 1.5, level: reading.isFaded ? nil : TokenroomTokens.usageColor(usedPercent: window.used, isStale: false))
                            .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 84)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                        Text(second == nil ? "Last 7 days" : "\(window.displayTitle), last 7 days")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            if showsHistory {
                Group {
                    let series = reading.window.flatMap { item.history[$0.id] }
                    if let series, !series.isEmpty {
                        Sparkline(history: series, lineWidth: 1, level: reading.isFaded ? nil : reading.window.map { TokenroomTokens.usageColor(usedPercent: $0.used, isStale: false) })
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 44, height: 22)
            }
        }
        .opacity(provider.isLive ? 1 : 0.8)
    }

    private func line(_ reading: RowReading, name: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(2)
            if !roomy, let window = reading.window {
                Text(window.displayTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if !roomy {
                status(reading)
                    .layoutPriority(1)
            }
            Text(ReadingText.headline(reading.window, now: date))
                .font(.system(size: roomy ? 20 : 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(headlineStyle(reading.window, isLive: reading.provider.isLive))
                .widgetAccentable()
                .lineLimit(1)
                .fixedSize()
                .frame(minWidth: 38, alignment: .trailing)
                .layoutPriority(3)
        }
    }

    private func status(_ reading: RowReading) -> some View {
        RowStatus(reading: reading, date: date)
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct TilesWidget: View {
    var entry: ReadingsEntry
    var count: Int
    var showsSecond: Bool

    var body: some View {
        let items = Array(entry.items.prefix(count))
        let rows = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        VStack(alignment: .leading, spacing: 6) {
            WidgetHeader(entry: entry, shown: count)
            ForEach(rows, id: \.first?.id) { row in
                HStack(spacing: 6) {
                    ForEach(row) { item in
                        Link(destination: DeepLink.provider(item.id).url) {
                            Tile(item: item, date: entry.date, showsSecond: showsSecond || items.count <= 2, roomy: items.count <= 2)
                        }
                        .foregroundStyle(.primary)
                    }
                    if row.count == 1, items.count > 1 {
                        Color.clear
                    }
                }
            }
        }
    }
}

private struct Tile: View {
    var item: ReadingCache.Item
    var date: Date
    var showsSecond: Bool
    var roomy = false

    var body: some View {
        let reading = RowReading(item, date: date)
        let provider = reading.provider
        VStack(alignment: .leading, spacing: roomy ? 5 : 3) {
            ViewThatFits(in: .horizontal) {
                if provider.name != provider.shortName {
                    top(reading, name: provider.name)
                }
                top(reading, name: provider.shortName)
            }
            if let window = reading.window {
                if window.isMetered {
                    WidgetMeter(used: window.used, isStale: reading.isFaded, pace: reading.pace, height: roomy ? 6 : 4, isAwaitingReading: reading.isAwaiting)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(window.displayTitle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                        Spacer(minLength: 2)
                        RowStatus(reading: reading, date: date)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(window.displayTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        figure(reading, size: roomy ? 20 : 15)
                    }
                }
                if showsSecond {
                    if provider.isLive, let second = provider.secondWindow(lead: window, now: date) {
                        SecondWindowLine(window: second, isStale: false)
                    } else if let series = item.history[window.id], !series.isEmpty {
                        Sparkline(history: series, lineWidth: 1, level: reading.isFaded ? nil : TokenroomTokens.usageColor(usedPercent: window.used, isStale: false))
                            .frame(maxWidth: .infinity)
                            .frame(height: 13)
                    }
                }
            }
        }
        .padding(.horizontal, roomy ? 10 : 8)
        .padding(.vertical, roomy ? 8 : 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: showsSecond && !roomy ? .topLeading : .leading)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .opacity(provider.isLive ? 1 : 0.8)
    }

    private func top(_ reading: RowReading, name: String) -> some View {
        HStack(alignment: .center, spacing: 5) {
            ProviderMark(provider: reading.provider, size: roomy ? 20 : 16)
            Text(name)
                .font((roomy ? Font.footnote : .caption).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 2)
            if reading.window?.isMetered != false {
                figure(reading, size: roomy ? 22 : 17)
                    .layoutPriority(1)
            } else if reading.isFaded {
                RowStatus(reading: reading, date: date)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
    }

    private func figure(_ reading: RowReading, size: CGFloat) -> some View {
        Text(ReadingText.headline(reading.window, now: date))
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(headlineStyle(reading.window, isLive: reading.provider.isLive))
            .widgetAccentable()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

private struct CircularWidget: View {
    var item: ReadingCache.Item
    var isSample: Bool
    var date: Date

    var body: some View {
        let window = item.provider.leadWindow(now: date, history: item.history)
        Group {
            if let window, !window.isMetered, let amount = window.amount {
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 0) {
                        Text(window.isAwaitingReading(at: date) ? "—" : ReadingText.circleAmount(amount))
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .minimumScaleFactor(0.5)
                        Text(isSample ? "Sample" : window.isAwaitingReading(at: date) ? "Reset" : item.provider.monogram)
                            .font(.system(size: 10, weight: .semibold))
                            .minimumScaleFactor(0.6)
                    }
                    .lineLimit(1)
                    .padding(6)
                    .widgetAccentable()
                }
            } else {
                Gauge(value: min(max(window?.meterUsed(at: date) ?? 0, 0), 100), in: 0...100) {
                    Text(window?.isAwaitingReading(at: date) == true ? "Reset" : item.provider.monogram)
                } currentValueLabel: {
                    if isSample {
                        Text("Sample")
                            .font(.system(size: 11, weight: .semibold))
                    } else {
                        Text(window.map { $0.isAwaitingReading(at: date) ? "—" : TokenroomFormat.percentText($0.used) } ?? "–")
                            .monospacedDigit()
                    }
                }
                .gaugeStyle(.accessoryCircular)
                .widgetAccentable()
            }
        }
        .widgetURL(DeepLink.provider(item.id).url)
        .opacity(item.provider.isLive && window?.isAwaitingReading(at: date) != true ? 1 : 0.65)
        .accessibilityValue("Last successful check \(RelativeTime.ago(item.provider.checkedAt ?? item.provider.fetchedAt, now: date))\(item.provider.isLive ? "" : ", stale")" + (ReadingText.attention(item.provider, now: date, lead: window).map { ", \($0)" } ?? ""))
    }
}

private struct RectangularWidget: View {
    var items: [ReadingCache.Item]
    var date: Date
    var isSample: Bool

    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 2) {
                rows(items)
                statusLine
            }
            VStack(alignment: .leading, spacing: 3) {
                rows(Array(items.prefix(2)))
                statusLine
            }
        }
        .widgetURL(items.first.map { DeepLink.provider($0.id).url })
    }

    private var sampleLine: some View {
        Text("Sample data")
            .font(.caption2)
            .lineLimit(1)
    }

    @ViewBuilder
    private var statusLine: some View {
        if isSample {
            sampleLine
        } else if let item = items.first(where: { $0.attention(now: date) != nil }),
                  let note = item.attention(now: date) {
            let stale = items.filter { !$0.provider.isLive }.count
            Text("\(item.provider.shortName) · \(note)" + (stale > 0 ? " · \(stale) stale" : ""))
                .font(.caption2.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.7)
                .foregroundStyle(UsageRanking.limitWarning(for: item.provider, now: date) == nil ? Color.secondary : TokenroomTokens.criticalText)
        } else if items.contains(where: { !$0.provider.isLive }) {
            Text("\(items.filter { !$0.provider.isLive }.count) stale").font(.caption2).lineLimit(1)
        } else if let first = items.first, let resetsAt = first.provider.leadWindow(now: date, history: first.history)?.resetsAt, resetsAt > date {
            HStack(spacing: 3) {
                Image(systemName: "arrow.counterclockwise")
                Text(first.provider.shortName)
                ResetCountdown(resetsAt: resetsAt, date: date).monospacedDigit()
            }.font(.caption2).lineLimit(1)
        }
    }

    private func rows(_ items: [ReadingCache.Item]) -> some View {
        ForEach(items) { item in
            let window = item.provider.leadWindow(now: date, history: item.history)
            let used = window?.used ?? 0
            HStack(spacing: 6) {
                Text(item.provider.shortName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: 58, alignment: .leading)
                if window?.isMetered == false {
                    Spacer(minLength: 0)
                } else {
                    WidgetMeter(used: used,
                                isStale: !item.provider.isLive || window?.isAwaitingReading(at: date) == true,
                                pace: window.flatMap { UsageRanking.pace(for: $0, isStale: !item.provider.isLive, history: item.history[$0.id], now: date)?.elapsedFraction },
                                height: 4,
                                isAwaitingReading: window?.isAwaitingReading(at: date) == true)
                }
                Text(ReadingText.headline(window, now: date))
                    .font(.caption2.monospacedDigit())
                    .lineLimit(1)
            }
            .opacity(item.provider.isLive && window?.isAwaitingReading(at: date) != true ? 1 : 0.65)
            .accessibilityValue("Last successful check \(RelativeTime.ago(item.provider.checkedAt ?? item.provider.fetchedAt, now: date))\(item.provider.isLive ? "" : ", stale")" + (ReadingText.attention(item.provider, now: date, lead: window).map { ", \($0)" } ?? ""))
        }
    }
}

private struct InlineWidget: View {
    var items: [ReadingCache.Item]
    var isSample: Bool
    var date: Date

    var body: some View {
        ViewThatFits {
            Text(line(items))
            Text(line(Array(items.prefix(2))))
            Text(line(Array(items.prefix(1))))
        }
    }

    private func line(_ items: [ReadingCache.Item]) -> String {
        let readings = items.map { item in
            let window = item.provider.leadWindow(now: date, history: item.history)
            return "\(item.provider.shortName) \(ReadingText.headline(window, now: date))" + (ReadingText.attention(item.provider, now: date, lead: window).map { " · \($0)" } ?? "")
        }
        let stale = items.filter { !$0.provider.isLive }.count
        return ((isSample ? ["Sample"] : []) + readings + (stale > 0 ? ["\(stale) stale"] : [])).joined(separator: " · ")
    }
}

private struct EmptyWidget: View {
    var isAccessory: Bool
    var provider: ProviderOption?
    var allHidden = false

    private var name: String? { provider?.providerID.flatMap(Provider.init(rawValue:))?.displayName }
    private var link: URL {
        if allHidden { return DeepLink.widgets.url }
        return provider?.providerID.map { DeepLink.provider($0).url } ?? DeepLink.settings.url
    }

    var body: some View {
        if isAccessory {
            Text(name.map { "\($0): no recent reading" } ?? (allHidden ? "No providers selected" : "No readings yet"))
                .font(.caption2)
                .accessibilityLabel(name.map { "\($0), no recent reading" } ?? (allHidden ? "No providers selected" : "No readings yet"))
                .widgetURL(link)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(name ?? (allHidden ? "No providers selected" : "No readings yet"))
                    .font(.headline)
                Text(name != nil ? "No recent reading. Open Tokenroom to refresh this provider."
                     : allHidden ? "Every provider is switched off for widgets. Tap to choose which ones show."
                     : "Open Tokenroom to connect your Mac, sign in to a plan, or add a key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(link)
        }
    }
}

private struct WidgetMeter: View {
    var used: Double
    var isStale: Bool
    var pace: Double? = nil
    var height: CGFloat = 6
    var isAwaitingReading = false
    @Environment(\.widgetRenderingMode) private var systemRenderingMode
    @Environment(\.widgetPreviewStyle) private var preview

    var body: some View {
        if (preview?.renderingMode ?? systemRenderingMode) == .fullColor {
            MeterTrack(usedPercent: used, remaining: 100 - used, isStale: isStale, paceMark: pace, height: height, isAwaitingReading: isAwaitingReading)
        } else {
            FlatMeter(used: used, pace: isStale ? nil : pace, tint: .primary, height: height, isAwaitingReading: isAwaitingReading)
        }
    }
}

private struct ResetText: View {
    var window: RelayWindow
    var date: Date

    var body: some View {
        if let resetsAt = window.resetsAt, resetsAt > date {
            Text("Resets in \(ResetCountdown.text(resetsAt: resetsAt, date: date))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if window.isAwaitingReading(at: date) {
            Text("Reset · awaiting reading")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct ResetCountdown: View {
    var resetsAt: Date
    var date: Date

    var body: some View {
        if Self.ticks(resetsAt: resetsAt, date: date) {
            Text("59:59")
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(timerInterval: date...resetsAt, countsDown: true)
                        .multilineTextAlignment(.trailing)
                }
        } else {
            Self.text(resetsAt: resetsAt, date: date)
        }
    }

    static func ticks(resetsAt: Date, date: Date) -> Bool {
        resetsAt > date && resetsAt.timeIntervalSince(date) < ReadingCache.countdownTicksWithin
    }

    static func text(resetsAt: Date, date: Date) -> Text {
        guard resetsAt > date else { return Text("now") }
        if ticks(resetsAt: resetsAt, date: date) {
            return Text(timerInterval: date...resetsAt, countsDown: true)
        }
        return Text(RelativeTime.remaining(until: resetsAt, now: date))
    }
}

private struct SampleTag: View {
    var body: some View {
        Text("Sample")
            .font(.system(size: 9, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Color.primary.opacity(0.08), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

private func headlineStyle(_ window: RelayWindow?, isLive: Bool) -> Color {
    guard let window, window.isMetered else { return .primary }
    guard isLive else { return Color.primary.opacity(0.75) }
    return TokenroomTokens.ink(remaining: 100 - window.used, isStale: false)
}
