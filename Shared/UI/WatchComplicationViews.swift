#if os(watchOS)
import SwiftUI
import WidgetKit

// The complications' and Smart Stack's views. They're here rather than in the widget target so the
// Watch app's debug gallery draws the same views, for screenshots without a watch face.

struct ComplicationEntry: TimelineEntry {
    var date: Date
    var items: [ReadingCache.Item]
    var isSample = false
}

struct ComplicationView: View {
    var entry: ComplicationEntry
    /// The family to draw when it isn't on a watch face: the debug gallery's.
    var preview: WidgetFamily? = nil
    @Environment(\.widgetFamily) private var systemFamily

    private var family: WidgetFamily { preview ?? systemFamily }

    var body: some View {
        content
            .widgetURL(link)
            .opacity(entry.items.first?.provider.isLive == false ? 0.7 : 1)
            .accessibilityValue(entry.items.first.map { "Last successful check \(RelativeTime.ago($0.provider.checkedAt ?? $0.provider.fetchedAt, now: entry.date))\($0.provider.isLive ? "" : ", stale")" + (ReadingText.attention($0.provider, now: entry.date, lead: $0.provider.leadWindow(now: entry.date, history: $0.history)).map { ", \($0)" } ?? "") } ?? "No readings")
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
            let window = first.provider.leadWindow(now: entry.date, history: first.history)
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
                            .tint(ringTint(used))
                        }
                    }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    // Samples give up a row to say so.
                    ForEach(entry.items.prefix(entry.isSample ? 2 : 3)) { item in
                        let row = item.provider.leadWindow(now: entry.date, history: item.history)
                        HStack(spacing: 4) {
                            Text(item.provider.shortName)
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 52, alignment: .leading)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            if row?.isMetered == false, row?.amount != nil {
                                // A balance: its amount, with no empty bar beside it.
                                Spacer(minLength: 0)
                            } else {
                                Gauge(value: min(max(row?.used ?? 0, 0), 100), in: 0...100) { EmptyView() }
                                    .gaugeStyle(.accessoryLinearCapacity)
                                    .tint(ringTint(row?.used ?? 0))
                            }
                            Text(ReadingText.headline(row, now: entry.date))
                                .font(.system(size: 12).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .opacity(item.provider.isLive && row?.isAwaitingReading(at: entry.date) != true ? 1 : 0.65)
                    }
                    let stale = entry.items.filter { !$0.provider.isLive }.count
                    if let item = entry.items.first(where: { $0.attention(now: entry.date) != nil }),
                       let note = item.attention(now: entry.date) {
                        Text(note + (stale > 0 ? " · \(stale) stale" : ""))
                            .font(.caption2.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.7)
                            .foregroundStyle(UsageRanking.limitWarning(for: item.provider, now: entry.date) == nil ? Color.secondary : TokenroomTokens.criticalText)
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
                    .tint(ringTint(used))
                }
            }
        } else {
            Image(systemName: "gauge.with.dots.needle.50percent")
        }
    }

    /// "Codex 78% · Claude 64%", after "Sample" for samples.
    private var inlineText: String {
        let readings = entry.items.prefix(2).map { item in
            let window = item.provider.leadWindow(now: entry.date, history: item.history)
            return "\(item.provider.shortName) \(ReadingText.headline(window, now: entry.date))" + (ReadingText.attention(item.provider, now: entry.date, lead: window).map { " · \($0)" } ?? "") + (!item.provider.isLive ? " · stale" : "")
        }
        return ((entry.isSample ? ["Sample"] : []) + readings).joined(separator: " · ")
    }

    /// The reading's one level colour, as a meter's, rather than every level at once.
    private func ringTint(_ used: Double) -> Color {
        TokenroomTokens.usageColor(usedPercent: used, isStale: false)
    }
}

struct ResetSoonView: View {
    var item: ReadingCache.Item?
    var windowID: String?
    var isSample = false

    var body: some View {
        if let item, let window = item.provider.windows.first(where: { $0.id == windowID }) ?? item.provider.primaryWindow {
            let date = Date.now
            HStack(spacing: 8) {
                ProviderMark(provider: item.provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.provider.shortName) \(WindowNames.inSentence(window.displayTitle)) \(ReadingText.headline(window, now: date))")
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Group {
                        if window.isAwaitingReading(at: date) {
                            Text("Reset · awaiting reading")
                        } else if let resetsAt = window.resetsAt, resetsAt > date {
                            Text("Resets in \(Text(resetsAt, style: .relative))")
                        }
                        if isSample {
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
#endif
