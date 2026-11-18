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

    @ViewBuilder
    private var content: some View {
        if let first = entry.items.first {
            switch family {
            case .systemMedium:
                if entry.style.usesTiles(isSmall: false) {
                    TilesWidget(entry: entry, count: 4, showsSecond: false)
                } else {
                    ListWidget(entry: entry, count: 4, showsHistory: false)
                }
            case .systemLarge:
                if entry.style.usesTiles(isSmall: false) {
                    TilesWidget(entry: entry, count: 8, showsSecond: true)
                } else {
                    ListWidget(entry: entry, count: 8, showsHistory: true)
                }
            case .accessoryCircular:
                CircularWidget(item: first, isSample: entry.isSample, date: entry.date)
            case .accessoryRectangular:
                RectangularWidget(items: Array(entry.items.prefix(3)), date: entry.date, isSample: entry.isSample)
            case .accessoryInline:
                InlineWidget(items: Array(entry.items.prefix(3)), isSample: entry.isSample, date: entry.date)
                    .widgetURL(DeepLink.provider(first.id).url)
            default:
                SmallWidget(entry: entry, item: first, showsSecond: entry.style.usesTiles(isSmall: true))
            }
        } else {
            EmptyWidget(isAccessory: isAccessory, provider: entry.unavailableProvider, allHidden: entry.allHidden)
        }
    }
}

// MARK: Home Screen

/// What one provider's row or tile draws: the window it leads with, and that window's state.
/// Every figure, meter, and countdown on the row is this window's.
private struct RowReading {
    var provider: RelayProvider
    var window: RelayWindow?
    /// The even pace, 0–1 of the window.
    var pace: Double?
    var isAwaiting: Bool
    var limitReached: Bool

    init(_ item: ReadingCache.Item, date: Date) {
        provider = item.provider
        let lead = provider.leadWindow(now: date, history: item.history)
        window = lead
        isAwaiting = lead?.isAwaitingReading(at: date) == true
        limitReached = lead.map { $0.isMetered && $0.used >= 100 } == true && !isAwaiting
        pace = lead.flatMap { UsageRanking.pace(for: $0, isStale: !item.provider.isLive, history: item.history[$0.id], now: date)?.elapsedFraction }
    }

    /// Drawn faded: nobody has confirmed it lately, or its window has reset since.
    var isFaded: Bool { !provider.isLive || isAwaiting }
}

/// The slot beside a figure: a reached limit, a reset waiting for its reading, a stale reading,
/// or the time left, whichever comes first. In words, so it survives a tinted widget.
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
        } else if let resetsAt = reading.window?.resetsAt, resetsAt > date {
            ResetCountdown(resetsAt: resetsAt, date: date)
        }
    }
}

/// The line over a list or a grid of tiles: when the readings shown were last checked, what a
/// glance would otherwise miss (a limit reached further down, stale readings, how many more
/// providers there are), and the refresh button.
private struct WidgetHeader: View {
    var entry: ReadingsEntry
    /// How many providers the widget has room for.
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
                // The user's own order can leave a reached limit below the last row.
                Text("· \(hidden.provider.shortName) limit reached")
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

    /// A clock time, which stays true however long the entry is on screen; the day once it's
    /// another day's.
    static func time(_ checked: Date, now: Date) -> String {
        Calendar.current.isDate(checked, inSameDayAs: now)
            ? checked.formatted(date: .omitted, time: .shortened)
            : checked.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// A second window under the one a row leads with: its name, a thin meter, and its figure.
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
    /// The tile's layout: the reset beside the window's name, and a second window under it.
    var showsSecond: Bool

    var body: some View {
        let reading = RowReading(item, date: entry.date)
        let provider = reading.provider
        let window = reading.window
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ProviderMark(provider: provider, size: 20)
                Text(provider.shortName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if entry.isSample {
                    SampleTag()
                }
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
                    WidgetMeter(used: window.used, isStale: reading.isFaded, pace: reading.pace)
                }
                if showsSecond {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(window.displayTitle)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        RowStatus(reading: reading, date: entry.date)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                } else {
                    Text(window.displayTitle)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    ResetText(window: window, date: entry.date)
                }
            }
            if showsSecond {
                // One more line, by what matters most.
                if !provider.isLive {
                    Text("Checked \(WidgetHeader.time(provider.checkedAt ?? provider.fetchedAt ?? entry.date, now: entry.date))")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else if let window, let second = provider.secondWindow(lead: window, now: entry.date) {
                    SecondWindowLine(window: second, isStale: false)
                } else if let note = ReadingText.attention(provider, now: entry.date, lead: window), !reading.isAwaiting {
                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
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
}

private struct ListWidget: View {
    var entry: ReadingsEntry
    var count: Int
    var showsHistory: Bool

    var body: some View {
        let rows = Array(entry.items.prefix(count))
        // With few providers each row gets the roomy layout, rather than the dense one stretched.
        let roomy = rows.count <= (showsHistory ? 5 : 2)
        // The sparkline's column only when some row has one to draw.
        let history = showsHistory && rows.contains { item in
            item.provider.leadWindow(now: entry.date, history: item.history).flatMap { item.history[$0.id] }?.isEmpty == false
        }
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(entry: entry, shown: count)
            ForEach(rows) { item in
                Link(destination: DeepLink.provider(item.id).url) {
                    ListRow(item: item, date: entry.date, showsHistory: history, roomy: roomy, isLarge: showsHistory)
                        // Rows share the widget's height, whatever their number; a few on Large
                        // keep to the top rather than drift apart.
                        .frame(maxHeight: roomy && showsHistory ? 76 : .infinity)
                }
                // Links tint their labels; rows keep their own colors.
                .foregroundStyle(.primary)
            }
            if roomy, showsHistory {
                Spacer(minLength: 0)
            }
        }
    }
}

/// One provider on one line, in columns that line up down the widget: its mark and name, the
/// name of the window the figure measures, then the time left and the figure, with that
/// window's meter under them.
private struct ListRow: View {
    var item: ReadingCache.Item
    var date: Date
    var showsHistory: Bool
    /// Few rows: a larger figure, and the window and its reset on a line of their own.
    var roomy: Bool
    /// Large has the width for a provider's full name, and the height for a second window.
    var isLarge: Bool

    var body: some View {
        let reading = RowReading(item, date: date)
        let provider = reading.provider
        HStack(spacing: 8) {
            ProviderMark(provider: provider, size: roomy ? 24 : 18)
            VStack(alignment: .leading, spacing: 3) {
                if roomy {
                    line(reading, name: isLarge ? provider.name : provider.shortName, showsWindow: false, showsStatus: false)
                } else {
                    // The first form that fits: the full name on Large, then the short one, then
                    // without a routine time left. The last shortens the window's name, and
                    // keeps a reached limit, a reset, or a stale reading in words.
                    let routine = provider.isLive && !reading.limitReached && !reading.isAwaiting
                    ViewThatFits(in: .horizontal) {
                        if isLarge, provider.name != provider.shortName {
                            line(reading, name: provider.name, showsWindow: true, showsStatus: true)
                        }
                        line(reading, name: provider.shortName, showsWindow: true, showsStatus: true)
                        if routine {
                            line(reading, name: provider.shortName, showsWindow: true, showsStatus: false)
                        }
                        line(reading, name: provider.shortName, showsWindow: true, showsStatus: !routine)
                    }
                }
                if let window = reading.window, window.isMetered {
                    WidgetMeter(used: window.used, isStale: reading.isFaded, pace: reading.pace, height: roomy ? 6 : 5)
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
                    if isLarge, provider.isLive, let second = provider.secondWindow(lead: window, now: date) {
                        SecondWindowLine(window: second, isStale: false)
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
                .frame(width: 56, height: 22)
            }
        }
        .opacity(provider.isLive ? 1 : 0.6)
    }

    private func line(_ reading: RowReading, name: String, showsWindow: Bool, showsStatus: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(2)
            if showsWindow, let window = reading.window {
                Text(window.displayTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            if showsStatus {
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
                // Figures end on one edge and start on one, down the widget.
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

/// A tile per provider, two across: a larger figure than a list row has room for, and on Large
/// a second window under the first.
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
                            Tile(item: item, date: entry.date, showsSecond: showsSecond, roomy: items.count <= 2)
                        }
                        .foregroundStyle(.primary)
                    }
                    // An odd one out keeps its half, beside an empty place.
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
    /// One or two tiles in the widget: a larger mark and figure.
    var roomy = false

    var body: some View {
        let reading = RowReading(item, date: date)
        let provider = reading.provider
        VStack(alignment: .leading, spacing: roomy ? 5 : 3) {
            HStack(alignment: .center, spacing: 5) {
                ProviderMark(provider: provider, size: roomy ? 22 : 16)
                Text(provider.shortName)
                    .font((roomy ? Font.subheadline : .caption).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                Text(ReadingText.headline(reading.window, now: date))
                    .font(.system(size: roomy ? 24 : 17, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(headlineStyle(reading.window, isLive: provider.isLive))
                    .widgetAccentable()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(1)
            }
            if let window = reading.window {
                if window.isMetered {
                    WidgetMeter(used: window.used, isStale: reading.isFaded, pace: reading.pace, height: roomy ? 6 : 4)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(window.displayTitle)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    RowStatus(reading: reading, date: date)
                        .lineLimit(1)
                        .fixedSize()
                }
                .font((roomy ? Font.caption : .caption2).monospacedDigit())
                .foregroundStyle(.secondary)
                if showsSecond, provider.isLive, let second = provider.secondWindow(lead: window, now: date) {
                    SecondWindowLine(window: second, isStale: false)
                }
            }
        }
        .padding(.horizontal, roomy ? 10 : 8)
        .padding(.vertical, roomy ? 8 : 5)
        // With a second window on some tiles and not others, every tile starts at its top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: showsSecond ? .topLeading : .leading)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .opacity(provider.isLive ? 1 : 0.6)
    }
}

// MARK: Lock Screen

private struct CircularWidget: View {
    var item: ReadingCache.Item
    var isSample: Bool
    var date: Date

    var body: some View {
        let window = item.provider.leadWindow(now: date, history: item.history)
        Group {
            if let window, !window.isMetered, let amount = window.amount {
                // A balance has nothing to fill: its amount, rather than a ring reading 0.
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
                Gauge(value: min(max(window?.used ?? 0, 0), 100), in: 0...100) {
                    Text(window?.isAwaitingReading(at: date) == true ? "Reset" : item.provider.monogram)
                } currentValueLabel: {
                    // Samples say so where the number goes; the ring still shows the level.
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
                // Samples give up a row rather than their label.
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
                // The reading's level where colour shows. The Lock Screen flattens colour to
                // brightness, where a critical red would read dimmer than a healthy blue.
                WidgetMeter(used: used,
                            isStale: !item.provider.isLive || window?.isAwaitingReading(at: date) == true,
                            pace: window.flatMap { UsageRanking.pace(for: $0, isStale: !item.provider.isLive, history: item.history[$0.id], now: date)?.elapsedFraction },
                            height: 4)
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

// MARK: Pieces

private struct EmptyWidget: View {
    var isAccessory: Bool
    var provider: ProviderOption?
    /// There are readings, and the user switched every provider off for widgets.
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
                     : allHidden ? "Every provider is switched off for widgets. Open Tokenroom to choose which ones show."
                     : "Open Tokenroom to connect your Mac, sign in to a plan, or add a key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetURL(link)
        }
    }
}

/// A full-color meter on the Home Screen; a flat, accentable one when the system tints widgets.
private struct WidgetMeter: View {
    var used: Double
    var isStale: Bool
    /// The even pace, 0–1 of the window, as on the app's meters.
    var pace: Double? = nil
    var height: CGFloat = 6
    @Environment(\.widgetRenderingMode) private var systemRenderingMode
    @Environment(\.widgetPreviewStyle) private var preview

    var body: some View {
        if (preview?.renderingMode ?? systemRenderingMode) == .fullColor {
            MeterTrack(usedPercent: used, remaining: 100 - used, isStale: isStale, paceMark: pace, height: height)
        } else {
            FlatMeter(used: used, pace: isStale ? nil : pace, tint: .primary, height: height)
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

/// Time left until a reset: a ticking "48:12" in the last hour, so the widget needs no reloads
/// for the clock; "23h" or "3d 1h" further out.
struct ResetCountdown: View {
    var resetsAt: Date
    var date: Date

    var body: some View {
        if Self.ticks(resetsAt: resetsAt, date: date) {
            // A timer takes all the width it's offered and sets itself at the leading edge, so
            // the widest it can read stands in for its size and it sits at the trailing edge.
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
    return TokenroomTokens.ink(remaining: 100 - window.used, isStale: !isLive)
}
