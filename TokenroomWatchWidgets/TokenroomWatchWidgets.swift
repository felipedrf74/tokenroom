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
            completion(Timeline(entries: entries, policy: .after(cache?.nextReload(after: now, reloads: reloads) ?? WidgetSchedule.nextReload(after: now, items: [], reloads: reloads))))
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
            ResetSoonView(item: entry.item, windowID: entry.windowID, isSample: entry.isSample)
        }
        .configurationDisplayName("Resets Soon")
        .description("Shows up in the Smart Stack when a limit is at 80% or nears its reset.")
    }
}
