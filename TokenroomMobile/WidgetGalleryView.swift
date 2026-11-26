#if DEBUG
import SwiftUI
import WidgetKit

struct WidgetGalleryView: View {
    var cache: ReadingCache
    var date: Date = .now

    private let homeSizes: [(family: WidgetFamily, size: CGSize)] = [
        (.systemSmall, CGSize(width: 170, height: 170)),
        (.systemMedium, CGSize(width: 364, height: 170)),
        (.systemLarge, CGSize(width: 364, height: 382)),
    ]
    private let lockSizes: [(family: WidgetFamily, size: CGSize)] = [
        (.accessoryCircular, CGSize(width: 76, height: 76)),
        (.accessoryRectangular, CGSize(width: 172, height: 76)),
        (.accessoryInline, CGSize(width: 250, height: 24)),
    ]

    private let compactSizes: [(family: WidgetFamily, size: CGSize)] = [
        (.systemSmall, CGSize(width: 155, height: 155)),
        (.systemMedium, CGSize(width: 329, height: 155)),
        (.systemLarge, CGSize(width: 329, height: 345)),
    ]

    var page = "home"

    private var eventful: ReadingCache {
        var result = cache
        let limit = result.items.lastIndex { $0.provider.windows.contains(where: \.isMetered) }
        for index in result.items.indices {
            if index == limit, index > 2 {
                for window in result.items[index].provider.windows.indices where result.items[index].provider.windows[window].isMetered {
                    result.items[index].provider.windows[window].used = 100
                }
            } else if index == 1 {
                result.items[index].provider.checkedAt = date.addingTimeInterval(-2 * 3600)
                result.items[index].provider.fetchedAt = date.addingTimeInterval(-2 * 3600)
            } else if index == 2, !result.items[index].provider.windows.isEmpty {
                result.items[index].provider.windows[0].resetsAt = date.addingTimeInterval(48 * 60 + 12)
            }
        }
        return result
    }

    private func card(_ family: WidgetFamily, size: CGSize, mode: WidgetRenderingMode = .fullColor, style: WidgetStyleOption = .recommended,
                      cache: ReadingCache? = nil, arrangement: WidgetArrangement = WidgetArrangement()) -> some View {
        widget(family, size: size, mode: mode, style: style, cache: cache, arrangement: arrangement)
            .background(mode == .fullColor ? AnyShapeStyle(.background) : AnyShapeStyle(.blue.opacity(0.25)), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if page == "lock" {
                    HStack(spacing: 14) {
                        ForEach(lockSizes.prefix(2), id: \.family) { item in
                            widget(item.family, size: item.size, mode: .vibrant)
                        }
                    }
                    .padding(12)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .environment(\.colorScheme, .dark)
                    widget(.accessoryInline, size: CGSize(width: 250, height: 24), mode: .vibrant)
                        .environment(\.colorScheme, .dark)
                        .padding(8)
                        .background(.black.opacity(0.55), in: Capsule())
                    HStack(spacing: 14) {
                        widget(.systemSmall, size: CGSize(width: 170, height: 170), mode: .accented)
                            .background(.blue.opacity(0.25), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        widget(.systemSmall, size: CGSize(width: 170, height: 170), mode: .fullColor)
                            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .environment(\.colorScheme, .dark)
                    }
                    widget(.systemMedium, size: CGSize(width: 364, height: 170), mode: .fullColor)
                        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .environment(\.colorScheme, .dark)
                    if let activity = sampleActivity {
                        SessionLockScreenView(attributes: activity.attributes, state: activity.state)
                            .frame(width: 370)
                            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .environment(\.colorScheme, .dark)
                    }
                } else if page == "compact" {
                    card(.systemMedium, size: compactSizes[1].size, style: .list)
                    card(.systemMedium, size: compactSizes[1].size, style: .tiles)
                    HStack(spacing: 14) {
                        card(.systemSmall, size: compactSizes[0].size, style: .list)
                        card(.systemSmall, size: compactSizes[0].size, style: .tiles)
                    }
                    card(.systemLarge, size: compactSizes[2].size, style: .list)
                    card(.systemLarge, size: compactSizes[2].size, style: .tiles)
                } else if page == "few" {
                    var few = cache
                    let _ = few.items = Array(cache.items.prefix(2))
                    card(.systemMedium, size: homeSizes[1].size, style: .list, cache: few)
                    card(.systemMedium, size: homeSizes[1].size, style: .tiles, cache: few)
                    card(.systemLarge, size: homeSizes[2].size, style: .list, cache: few)
                } else if page == "states" {
                    let own = WidgetArrangement(order: .manual, sequence: eventful.items.map(\.id), hidden: [eventful.items.first?.id ?? ""])
                    card(.systemMedium, size: homeSizes[1].size, style: .list, cache: eventful, arrangement: own)
                    card(.systemMedium, size: homeSizes[1].size, style: .tiles, cache: eventful, arrangement: own)
                    card(.systemMedium, size: homeSizes[1].size, mode: .accented, style: .list, cache: eventful, arrangement: own)
                    card(.systemMedium, size: homeSizes[1].size, mode: .accented, style: .tiles, cache: eventful, arrangement: own)
                    card(.systemLarge, size: homeSizes[2].size, style: .list, cache: eventful, arrangement: own)
                    card(.systemLarge, size: homeSizes[2].size, style: .tiles, cache: eventful, arrangement: own)
                    let twoWindows = WidgetArrangement(order: .manual, sequence: cache.items.filter { $0.provider.windows.filter(\.isMetered).count > 1 }.map(\.id))
                    HStack(spacing: 14) {
                        card(.systemSmall, size: homeSizes[0].size, style: .tiles, cache: cache, arrangement: twoWindows)
                        card(.systemSmall, size: homeSizes[0].size, style: .list, cache: cache, arrangement: twoWindows)
                    }
                    let balance = WidgetArrangement(order: .manual, sequence: eventful.items.filter { !$0.provider.windows.contains(where: \.isMetered) }.map(\.id))
                    card(.systemMedium, size: homeSizes[1].size, style: .list, cache: cache, arrangement: balance)
                    card(.systemMedium, size: homeSizes[1].size, style: .tiles, cache: cache, arrangement: balance)
                    var aged = cache
                    let _ = aged.items.indices.filter { !aged.items[$0].provider.windows.contains(where: \.isMetered) }.forEach { index in
                        aged.items[index].provider.checkedAt = date.addingTimeInterval(-2 * 3600)
                        aged.items[index].provider.fetchedAt = date.addingTimeInterval(-2 * 3600)
                    }
                    card(.systemMedium, size: homeSizes[1].size, style: .tiles, cache: aged, arrangement: balance)
                    card(.systemMedium, size: homeSizes[1].size, cache: eventful, arrangement: WidgetArrangement(hidden: Set(eventful.items.map(\.id))))
                } else {
                    let style: WidgetStyleOption = page == "tiles" ? .tiles : page == "list" ? .list : .recommended
                    ForEach(homeSizes, id: \.family) { item in
                        card(item.family, size: item.size, style: style)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .background(Color.gray.opacity(0.25))
    }

    private var sampleActivity: (attributes: SessionActivityAttributes, state: SessionActivityAttributes.ContentState)? {
        for item in cache.items {
            let provider = item.provider
            guard let window = LiveActivities.candidate(in: provider, now: date), let resetsAt = window.resetsAt else { continue }
            return (
                SessionActivityAttributes(providerID: provider.id, providerName: provider.name, shortName: provider.shortName, monogram: provider.monogram, tint: provider.tint, windowID: window.id, windowTitle: window.displayTitle, windowSeconds: window.periodSec),
                SessionActivityAttributes.ContentState(used: window.used, resetsAt: resetsAt, isStale: !provider.isLive)
            )
        }
        return nil
    }

    private func widget(_ family: WidgetFamily, size: CGSize, mode: WidgetRenderingMode, style: WidgetStyleOption = .recommended,
                        cache shown: ReadingCache? = nil, arrangement: WidgetArrangement = WidgetArrangement()) -> some View {
        UsageWidgetView(entry: ReadingsEntry.make(shown ?? cache, choice: .automatic, arrangement: arrangement, style: style, date: date))
            .environment(\.widgetPreviewStyle, WidgetPreviewStyle(family: family, renderingMode: mode))
            .padding(family == .accessoryInline || family == .accessoryCircular || family == .accessoryRectangular ? 0 : 16)
            .frame(width: size.width, height: size.height)
    }
}
#endif
