import SwiftUI
import WidgetKit

@main
struct TokenroomWidgetsBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
        SessionActivityWidget()
        FollowUsageControl()
    }
}

struct UsageWidget: Widget {
    static let kind = "usage"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: SelectProviderIntent.self, provider: ReadingsTimelineProvider()) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Usage")
        .description("How much of each plan you've used, and when it resets.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct ReadingsTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ReadingsEntry {
        var entry = ReadingsEntry.make(SampleData.cache(), choice: .automatic, date: .now)
        entry.isPlaceholder = true
        return entry
    }

    func snapshot(for configuration: SelectProviderIntent, in context: Context) async -> ReadingsEntry {
        // The widget gallery shows samples until there are real readings.
        let cache = PhoneCacheAccess.load(at: ReadingCache.defaultURL, defaults: AppGroup.defaults)
        return ReadingsEntry.make(context.isPreview && (cache?.items.isEmpty ?? true) ? SampleData.cache() : cache, choice: configuration.provider, arrangement: WidgetArrangement.load(from: AppGroup.defaults), style: configuration.style, date: .now)
    }

    func timeline(for configuration: SelectProviderIntent, in context: Context) async -> Timeline<ReadingsEntry> {
        let now = Date.now
        // WidgetKit budgets each widget on its own; two set up alike reload together. A widget
        // left on the recommended style keeps the name it was counted under before styles.
        let style = configuration.style == .recommended ? "" : "-\(configuration.style.rawValue)"
        let reloads = WidgetReloadLog.record("\(context.family)-\(configuration.provider.rawValue)\(style)", at: now)
        let result = await WidgetRefresher.timeline(now: now)
        let cache = result.cache
        // Reset, stale, and expiry boundaries update presentation without inventing usage.
        let horizon = now.addingTimeInterval(8 * 3600)
        let boundaries = cache?.presentationDates(after: now, until: horizon) ?? []
        let arrangement = WidgetArrangement.load(from: AppGroup.defaults)
        // Then where the countdowns of the rows this size draws change, as far as the entries
        // left over go: never in place of a reset or a reading going stale. At most 56 entries: now,
        // 31 of those boundaries, and 24 for countdowns.
        let rows = ReadingsEntry.make(cache, choice: configuration.provider, arrangement: arrangement, date: now).items.prefix(UsageWidgetView.rows(in: context.family))
        let wording = ReadingCache.countdownEntries(for: Array(rows), after: now, until: horizon)
        let dates = Array(Set([now] + boundaries.prefix(31) + wording)).sorted()
        return Timeline(
            entries: dates.map { ReadingsEntry.make(cache, choice: configuration.provider, arrangement: arrangement, style: configuration.style, date: $0) },
            policy: .after(result.nextReload(after: now, reloads: reloads))
        )
    }
}
