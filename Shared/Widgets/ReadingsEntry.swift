import SwiftUI
import WidgetKit

struct ReadingsEntry: TimelineEntry {
    var date: Date
    /// The chosen provider first, then the rest as arranged in the app (`WidgetArrangement`).
    var items: [ReadingCache.Item]
    var isSample: Bool
    /// When the oldest shown reading was last confirmed; the cache is saved on every rebuild,
    /// however old the readings in it.
    var checkedAt: Date?
    var isPlaceholder = false
    var unavailableProvider: ProviderOption? = nil
    /// There are readings, and every provider is switched off for widgets.
    var allHidden = false
    var style: WidgetStyleOption = .recommended

    /// The readings as they stand at `date`: the providers switched on for widgets, in the
    /// arrangement's order, with the widget's own provider first. A widget set to one provider
    /// shows it whether or not it's switched on in the app's list.
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

    /// When the oldest of the first `count` readings was last confirmed: what a widget showing
    /// that many rows says it's "as of".
    func checkedAt(first count: Int) -> Date? {
        items.prefix(count).compactMap { $0.provider.checkedAt ?? $0.provider.fetchedAt }.min()
    }

    /// A provider past the first `count` rows whose limit is reached: an order the user chose
    /// can put it out of sight, and the widget still has to say so.
    func limitReached(beyond count: Int) -> ReadingCache.Item? {
        items.dropFirst(count).first { item in
            item.provider.windows.contains { $0.isMetered && $0.used >= 100 && !$0.isAwaitingReading(at: date) }
        }
    }
}

/// Lets the app's debug gallery draw a widget as a family and rendering mode it picks; WidgetKit
/// sets both itself everywhere else.
struct WidgetPreviewStyle: Equatable {
    var family: WidgetFamily
    var renderingMode: WidgetRenderingMode = .fullColor
}

extension EnvironmentValues {
    @Entry var widgetPreviewStyle: WidgetPreviewStyle? = nil
}
