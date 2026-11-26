import SwiftUI
import WidgetKit

struct ReadingsEntry: TimelineEntry {
    var date: Date
    var items: [ReadingCache.Item]
    var isSample: Bool
    var checkedAt: Date?
    var isPlaceholder = false
    var unavailableProvider: ProviderOption? = nil
    var allHidden = false
    var style: WidgetStyleOption = .recommended

    static func make(_ cache: ReadingCache?, choice: ProviderOption, arrangement: WidgetArrangement = WidgetArrangement(), style: WidgetStyleOption = .recommended, date: Date) -> ReadingsEntry {
        let ranked = cache?.presented(at: date).items ?? []
        var items = arrangement.arranged(ranked, id: \.id)
        if let id = choice.providerID {
            guard let pinned = ranked.first(where: { $0.id == id }) else {
                return ReadingsEntry(date: date, items: [], isSample: cache?.isSample ?? false,
                                     checkedAt: nil, unavailableProvider: choice, style: style)
            }
            items.removeAll { $0.id == id }
            items.insert(pinned, at: 0)
        }
        return ReadingsEntry(date: date, items: items, isSample: cache?.isSample ?? false,
                             checkedAt: items.compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.min(),
                             allHidden: items.isEmpty && !ranked.isEmpty, style: style)
    }

    func checkedAt(first count: Int) -> Date? {
        items.prefix(count).compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.min()
    }

    func limitReached(beyond count: Int) -> ReadingCache.Item? {
        items.dropFirst(count).first { item in
            item.provider.isLive && item.provider.windows.contains { $0.isMetered && $0.used >= 100 && !$0.isAwaitingReading(at: date) }
        }
    }
}

struct WidgetPreviewStyle: Equatable {
    var family: WidgetFamily
    var renderingMode: WidgetRenderingMode = .fullColor
}

extension EnvironmentValues {
    @Entry var widgetPreviewStyle: WidgetPreviewStyle? = nil
}
