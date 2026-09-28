import SwiftUI
import WidgetKit

struct ReadingsEntry: TimelineEntry {
    var date: Date
    /// The chosen provider first, then most urgent first.
    var items: [ReadingCache.Item]
    var isSample: Bool
    /// When the oldest shown reading was last confirmed; the cache is saved on every rebuild,
    /// however old the readings in it.
    var checkedAt: Date?
    var isPlaceholder = false
    var unavailableProvider: ProviderOption? = nil

    /// The readings as they stand at `date`, the chosen provider first.
    static func make(_ cache: ReadingCache?, choice: ProviderOption, date: Date) -> ReadingsEntry {
        let presented = cache?.presented(at: date)
        var items = presented?.items ?? []
        if let id = choice.providerID {
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                return ReadingsEntry(date: date, items: [], isSample: cache?.isSample ?? false,
                                     checkedAt: nil, unavailableProvider: choice)
            }
            items.insert(items.remove(at: index), at: 0)
        }
        return ReadingsEntry(date: date, items: items, isSample: cache?.isSample ?? false, checkedAt: presented?.checkedAt)
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
