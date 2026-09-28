import AppIntents
import SwiftUI
import WidgetKit

@main
struct TokenroomWatchWidgets: WidgetBundle {
    var body: some Widget {
        UsageComplication()
        ResetSoonWidget()
    }
}

// MARK: Complications

struct ComplicationEntry: TimelineEntry {
    var date: Date
    var items: [ReadingCache.Item]
    var isSample = false
}

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry {
        ComplicationEntry(date: .now, items: SampleData.cache().items)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (ComplicationEntry) -> Void) {
        let saved = RelayReadings.cached(at: ReadingCache.defaultURL)
        let cache = context.isPreview && (saved?.items.isEmpty ?? true) ? SampleData.cache() : saved
        completion(ComplicationEntry(date: .now, items: cache?.presented(at: .now).items ?? [], isSample: cache?.isSample ?? false))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<ComplicationEntry>) -> Void) {
        let widget = "watch-\(context.family)"
        Task {
            let now = Date.now
            let reloads = WidgetReloadLog.record(widget, at: now)
            let cache = await RelayReadings.cache(at: ReadingCache.defaultURL, maxAge: 15 * 60, budget: 6, now: now)
            // Reset, stale, and expiry boundaries update presentation without inventing usage.
            let horizon = now.addingTimeInterval(8 * 3600)
            let boundaries = cache?.presentationDates(after: now, until: horizon) ?? []
            let entries = ([now] + boundaries.prefix(31)).map { date in
                ComplicationEntry(date: date, items: cache?.presented(at: date).items ?? [], isSample: cache?.isSample ?? false)
            }
            completion(Timeline(entries: entries, policy: .after(WidgetSchedule.nextReload(after: now, items: cache?.presented(at: .now).items ?? [], reloads: reloads))))
        }
    }
}

struct UsageComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "watch.usage", provider: ComplicationProvider()) { entry in
            ComplicationView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("Your most urgent limit, or the three most used.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

private struct ComplicationView: View {
    var entry: ComplicationEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(link)
            .opacity(entry.items.first?.provider.isLive == false ? 0.7 : 1)
            .accessibilityValue(entry.items.first.map { "Last successful check \(RelativeTime.ago($0.provider.checkedAt ?? $0.provider.fetchedAt, now: entry.date))\($0.provider.isLive ? "" : ", stale")" + (ReadingText.attention($0.provider, now: entry.date).map { ", \($0)" } ?? "") } ?? "No readings")
    }

    /// Circular and corner complications show one provider and open it; the rest open the list.
    private var link: URL? {
        guard let first = entry.items.first, family == .accessoryCircular || family == .accessoryCorner else { return Self.listURL }
        return DeepLink.provider(first.id).url
    }

    /// Not a provider's link, so the Watch app opens on its list rather than where it was left.
    private static let listURL = URL(string: "\(DeepLink.scheme)://usage")

    @ViewBuilder
    private var content: some View {
        if let first = entry.items.first {
            let window = first.provider.primaryWindow
            let used = min(max(window?.used ?? 0, 0), 100)
            switch family {
            case .accessoryCorner:
                let balance = window.flatMap { $0.isMetered ? nil : $0.amount }
                // A balance has nothing to fill: its amount, and the provider's name for a label.
                Text(window?.isAwaitingReading(at: entry.date) == true ? "—" : (balance.map(ReadingText.circleAmount) ?? ReadingText.headline(window, now: entry.date)))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .widgetCurvesContent()
                    .widgetLabel {
                        if entry.isSample {
                            Text("Sample")
                        } else if window?.isAwaitingReading(at: entry.date) == true {
                            Text("\(first.provider.shortName) · Reset · awaiting reading")
                        } else if balance != nil {
                            Text(first.provider.shortName)
                        } else {
                            Gauge(value: used, in: 0...100) {
                                Text(first.provider.shortName)
                            }
                            .tint(ringTint)
                        }
                    }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    // Samples give up a row to say so.
                    ForEach(entry.items.prefix(entry.isSample ? 2 : 3)) { item in
                        let row = item.provider.primaryWindow
                        HStack(spacing: 4) {
                            Text(item.provider.shortName)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 52, alignment: .leading)
                                .lineLimit(1)
                            if row?.isMetered == false, row?.amount != nil {
                                // A balance: its amount, with no empty bar beside it.
                                Spacer(minLength: 0)
                            } else {
                                Gauge(value: min(max(row?.used ?? 0, 0), 100), in: 0...100) { EmptyView() }
                                    .gaugeStyle(.accessoryLinearCapacity)
                                    .tint(ringTint)
                            }
                            Text(ReadingText.headline(row, now: entry.date))
                                .font(.system(size: 12).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .opacity(item.provider.isLive && row?.isAwaitingReading(at: entry.date) != true ? 1 : 0.65)
                    }
                    let stale = entry.items.filter { !$0.provider.isLive }.count
                    if let item = entry.items.first(where: { ReadingText.attention($0.provider, now: entry.date) != nil }),
                       let note = ReadingText.attention(item.provider, now: entry.date) {
                        Text(note + (stale > 0 ? " · \(stale) stale" : ""))
                            .font(.caption2.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.7)
                            .foregroundStyle(UsageRanking.limitWarning(for: item.provider, now: entry.date) == nil ? Color.secondary : TokenroomTokens.usageCritical)
                    } else {
                        if stale > 0 { Text("\(stale) stale").font(.caption2).foregroundStyle(.secondary) }
                    }
                    if entry.isSample {
                        Text("Sample data")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            case .accessoryInline:
                Text(inlineText)
            default:
                if let window, !window.isMetered, let amount = window.amount {
                    // A balance has nothing to fill: its amount, rather than a ring reading 0.
                    ZStack {
                        AccessoryWidgetBackground()
                        VStack(spacing: 0) {
                            Text(window.isAwaitingReading(at: entry.date) ? "—" : ReadingText.circleAmount(amount))
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .minimumScaleFactor(0.5)
                            Text(entry.isSample ? "Sample" : window.isAwaitingReading(at: entry.date) ? "Reset" : first.provider.monogram)
                                .font(.system(size: 10, weight: .medium))
                                .minimumScaleFactor(0.6)
                        }
                        .lineLimit(1)
                        .padding(4)
                    }
                } else {
                    Gauge(value: used, in: 0...100) {
                        Text(window?.isAwaitingReading(at: entry.date) == true ? "Reset" : first.provider.monogram)
                    } currentValueLabel: {
                        // Samples say so where the number goes; the ring still shows the level.
                        if entry.isSample {
                            Text("Sample")
                                .font(.system(size: 9, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        } else {
                            Text(window?.isAwaitingReading(at: entry.date) == true ? "—" : TokenroomFormat.percentText(used))
                                .monospacedDigit()
                        }
                    }
                    .gaugeStyle(.accessoryCircular)
                    .tint(ringTint)
                }
            }
        } else {
            Image(systemName: "gauge.with.dots.needle.50percent")
        }
    }

    /// "Codex 78% · Claude 64%", after "Sample" for samples.
    private var inlineText: String {
        let readings = entry.items.prefix(2).map { "\($0.provider.shortName) \(ReadingText.headline($0.provider.primaryWindow, now: entry.date))" + (ReadingText.attention($0.provider, now: entry.date).map { " · \($0)" } ?? "") + (!$0.provider.isLive ? " · stale" : "") }
        return ((entry.isSample ? ["Sample"] : []) + readings).joined(separator: " · ")
    }

    private var ringTint: Gradient {
        Gradient(colors: [TokenroomTokens.usageHealthy, TokenroomTokens.usageWatch, TokenroomTokens.usageTight, TokenroomTokens.usageCritical])
    }
}

// MARK: Smart Stack

/// One provider's window, chosen by `relevance()`; not something people configure.
struct WindowIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage Window"

    @Parameter(title: "Provider")
    var providerID: String?

    @Parameter(title: "Window")
    var windowID: String?

    init() {}

    init(providerID: String, windowID: String) {
        self.providerID = providerID
        self.windowID = windowID
    }
}

struct ResetSoonEntry: RelevanceEntry {
    var item: ReadingCache.Item?
    var windowID: String?
    var isSample = false
}

/// Relevant in the Smart Stack for the last 8 hours before a session or a busy window resets,
/// and for the next half day whenever a window is at 80% or more (`WidgetSchedule.relevance`).
struct ResetSoonProvider: RelevanceEntriesProvider {
    func relevance() async -> WidgetRelevance<WindowIntent> {
        let now = Date.now
        let items = RelayReadings.cached(at: ReadingCache.defaultURL)?.presented(at: now).items ?? []
        let attributes = items.flatMap { item in
            WidgetSchedule.relevance(of: item.provider, now: now).map { relevant in
                WidgetRelevanceAttribute(
                    configuration: WindowIntent(providerID: item.id, windowID: relevant.window.id),
                    context: .date(range: relevant.span, kind: .default)
                )
            }
        }
        return WidgetRelevance(attributes)
    }

    func entry(configuration: WindowIntent, context: Context) async throws -> ResetSoonEntry {
        let cache = RelayReadings.cached(at: ReadingCache.defaultURL)
        return ResetSoonEntry(item: cache?.presented(at: .now).items.first { $0.id == configuration.providerID }, windowID: configuration.windowID, isSample: cache?.isSample ?? false)
    }

    func placeholder(context: Context) -> ResetSoonEntry {
        let item = SampleData.cache().items.first { $0.id == Provider.claude.rawValue }
        return ResetSoonEntry(item: item, windowID: "session")
    }
}

struct ResetSoonWidget: Widget {
    var body: some WidgetConfiguration {
        RelevanceConfiguration(kind: "watch.resetSoon", provider: ResetSoonProvider()) { entry in
            ResetSoonView(entry: entry)
        }
        .configurationDisplayName("Resets Soon")
        .description("Shows up in the Smart Stack when a limit is at 80% or nears its reset.")
    }
}

private struct ResetSoonView: View {
    var entry: ResetSoonEntry

    var body: some View {
        if let item = entry.item, let window = item.provider.windows.first(where: { $0.id == entry.windowID }) ?? item.provider.primaryWindow {
            let date = Date.now
            HStack(spacing: 8) {
                ProviderMark(provider: item.provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.provider.shortName) \(window.displayTitle.lowercased()) \(ReadingText.headline(window, now: date))")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Group {
                        if window.isAwaitingReading(at: date) {
                            Text("Reset · awaiting reading")
                        } else if let resetsAt = window.resetsAt, resetsAt > date {
                            Text("Resets in \(Text(resetsAt, style: .relative))")
                        }
                        if entry.isSample {
                            Text("Sample data")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .widgetURL(DeepLink.provider(item.id).url)
        } else {
            Text("No window resets soon")
                .font(.footnote)
        }
    }
}
