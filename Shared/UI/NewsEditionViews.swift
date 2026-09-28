import SwiftUI

// The News edition's pieces, for the iPhone's News tab and the Mac's News window. Headlines are
// set in the system serif; everything around them stays SF. Titles and links only: stories open
// in the browser.

extension TokenroomTokens {
    /// A card on the grouped background: News cards, Usage tiles.
    static var cardFill: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif os(macOS)
        // The popover's card fill: windows are white already.
        Color.primary.opacity(0.045)
        #else
        Color(white: 0.12)
        #endif
    }
}

/// A lab's mark in News: its organization's icon where Tokenroom has one, else a monogram.
struct LabMark: View {
    var vendor: String
    var name: String
    var size: CGFloat = 22

    var body: some View {
        if let provider = NewsEditions.labProviders[vendor] {
            ProviderMark(provider: provider, size: size)
        } else {
            MonogramMark(text: String(name.prefix(1)).uppercased(), tint: Color(hex: "#636366"), size: size)
        }
    }

    /// The lab's tint, for a top story's art.
    static func tint(_ vendor: String) -> Color {
        if vendor == "google" { return Color(hex: "#4285F4") }
        return Color(hex: NewsEditions.labProviders[vendor]?.tintHex ?? "#636366")
    }
}

/// "Since you last looked": new models, updates, and models retiring soon, each opening its list.
struct NewsDigestView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var digest: NewsEdition.Digest
    var open: (NewsFilter) -> Void

    var body: some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            cell(digest.models, digest.models == 1 ? "new model" : "new models", .models)
            Divider()
            cell(digest.updates, digest.updates == 1 ? "update" : "updates", .announcements)
            Divider()
            cell(digest.retiring, "retiring soon", .retiring)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(TokenroomTokens.cardFill))
    }

    private func cell(_ count: Int, _ label: String, _ filter: NewsFilter) -> some View {
        Button {
            open(filter)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count)")
                    .font(.system(.title2, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text(label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) \(label)")
    }
}

/// The filters over News: the edition, then each kind of item.
enum NewsFilter: String, CaseIterable, Identifiable {
    case today = "Today"
    case models = "Models"
    case announcements = "Announcements"
    case retiring = "Retiring"

    var id: String { rawValue }
}

/// The one top story: the newest model from a lab you follow, its context window set large on
/// the lab's tint, then the name and what it costs.
struct TopStoryView: View {
    var release: ModelRelease
    var isNew: Bool

    var body: some View {
        let story = VStack(alignment: .leading, spacing: 0) {
            art
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("New model · \(release.vendorName)".uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(0.6)
                        .foregroundStyle(TokenroomTokens.accentText)
                    if isNew {
                        NewBadge()
                    }
                }
                Text(release.shortName)
                    .font(.system(.title, design: .serif, weight: .bold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                ModelSpecs(release: release)
                    .padding(.top, 4)
                HStack(spacing: 6) {
                    LabMark(vendor: release.vendor, name: release.vendorName, size: 18)
                    Text("OpenRouter · \(RelativeTime.ago(release.created))")
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            }
            .padding(16)
        }
        .background(TokenroomTokens.cardFill)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
        if let link = release.link {
            // Links tint their labels; the story keeps its own colours.
            Link(destination: link) { story }
                .foregroundStyle(.primary)
        } else {
            story
        }
    }

    private var art: some View {
        ZStack(alignment: .bottomLeading) {
            LabMark.tint(release.vendor)
            if let context = release.contextText {
                VStack(alignment: .leading, spacing: 0) {
                    Text("CONTEXT WINDOW")
                        .font(.caption.weight(.bold))
                        .tracking(0.6)
                    Text(context)
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            }
            // Five meter capsules: Tokenroom's own motif, not a picture.
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array([0.37, 0.68, 0.53, 1.0, 0.79].enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(.white.opacity(0.35 + Double(index) * 0.13))
                        .frame(width: 14, height: 76 * level)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(18)
            .accessibilityHidden(true)
        }
        .frame(height: 132)
        .clipped()
    }
}

/// Context, input and output price per million tokens, in three columns.
struct ModelSpecs: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var release: ModelRelease

    var body: some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 0))
        return layout {
            spec(release.contextText ?? "—", "Context")
            Divider()
            spec(price(release.promptPrice), "Input / million")
            Divider()
            spec(price(release.completionPrice), "Output / million")
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
        .overlay(alignment: .top) { Divider() }
    }

    private func price(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value == 0 ? "Free" : ModelReleaseRow.price(value)
    }

    private func spec(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(.headline, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, label == "Context" || typeSize >= .xxLarge ? 0 : 12)
    }
}

/// A compact model: lab, name, context and prices, age. A dot marks it new.
struct ModelCardView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var release: ModelRelease
    var isNew: Bool
    var width: CGFloat? = 168

    var body: some View {
        let card = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                LabMark(vendor: release.vendor, name: release.vendorName, size: 20)
                Text(release.vendorName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isNew {
                    Circle()
                        .fill(TokenroomTokens.accentText)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("New")
                }
            }
            Text(release.shortName)
                .font(.system(.body, design: .serif, weight: .semibold))
                .lineLimit(2, reservesSpace: true)
            Text(details)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(RelativeTime.ago(release.created))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: width.map { typeSize >= .xxLarge ? max($0, 240) : $0 }, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(TokenroomTokens.cardFill))
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
        if let link = release.link {
            Link(destination: link) { card }
                .foregroundStyle(.primary)
        } else {
            card
        }
    }

    /// "1M context · $5 / $25".
    private var details: String {
        var parts: [String] = []
        if let context = release.contextText { parts.append("\(context) context") }
        if let prompt = release.promptPrice, let completion = release.completionPrice {
            parts.append(prompt == 0 && completion == 0 ? "Free" : "Input \(ModelReleaseRow.price(prompt)) / Output \(ModelReleaseRow.price(completion)) per million tokens")
        }
        return parts.joined(separator: " · ")
    }
}

/// One tool's news: its icon, name and kind of feed, then up to three headlines, the first larger.
struct ToolNewsCard: View {
    var tool: NewsEdition.Tool
    var isNew: (Date?) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let provider = tool.provider {
                    ProviderMark(provider: provider, size: 26)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(tool.source)
                        .font(.subheadline.weight(.semibold))
                    Text(tool.kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if tool.newCount > 0 {
                    Text("\(tool.newCount) new")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(TokenroomTokens.accentText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .accessibilityElement(children: .combine)

            ForEach(Array(tool.items.enumerated()), id: \.element.id) { index, item in
                Divider()
                    .padding(.leading, 16)
                headline(item, isLead: index == 0)
            }
        }
        .padding(.bottom, 4)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(TokenroomTokens.cardFill))
    }

    @ViewBuilder
    private func headline(_ item: FeedItem, isLead: Bool) -> some View {
        let row = VStack(alignment: .leading, spacing: 4) {
            Text(item.displayTitle)
                .font(.system(isLead ? .title3 : .body, design: .serif, weight: .semibold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if isNew(item.published) {
                    NewBadge()
                }
                if let published = item.published {
                    Text(RelativeTime.ago(published))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let alsoIn = item.alsoIn {
                    Text("Also in \(alsoIn)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
        if let link = item.link {
            Link(destination: link) { row }
                .foregroundStyle(.primary)
        } else {
            row
        }
    }
}

/// A model leaving: a calendar tile, the name, the lab and how long it has left. Inside a week
/// the date and countdown take the warning inks.
struct RetiringModelRow: View {
    var release: ModelRelease

    var body: some View {
        let days = release.daysUntilRetirement() ?? 0
        let soon = days <= 7
        HStack(spacing: 12) {
            VStack(spacing: 0) {
                Text((release.expires ?? .now).formatted(.dateTime.month(.abbreviated)).uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(soon ? TokenroomTokens.criticalText : .secondary)
                Text((release.expires ?? .now).formatted(.dateTime.day()))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: 44, height: 48)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(release.shortName)
                    .font(.headline)
                let retires = Text(days == 1 ? "Retires tomorrow" : "Retires in \(days) days")
                    .foregroundStyle(soon ? TokenroomTokens.accentText : .secondary)
                    .fontWeight(soon ? .medium : .regular)
                Text("\(release.vendorName) · \(retires)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A line in the chronological River: the time, a dot when new, the source line, and the
/// headline in serif.
struct RiverRow: View {
    var item: FeedItem
    var isNew: Bool

    var body: some View {
        let provider = FeedSource.catalog.first { $0.name == item.source }?.provider
        let row = HStack(alignment: .top, spacing: 10) {
            Text(item.published.map { $0.formatted(date: .omitted, time: .shortened) } ?? "")
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if isNew {
                        Circle()
                            .fill(TokenroomTokens.accentText)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel("New")
                    }
                    if let provider {
                        ProviderMark(provider: provider, size: 16)
                    }
                    Text(item.source)
                        .font(.caption.weight(.semibold))
                }
                Text(item.displayTitle)
                    .font(.system(.body, design: .serif, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let alsoIn = item.alsoIn {
                    Text("Also in \(alsoIn)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .multilineTextAlignment(.leading)
        .accessibilityElement(children: .combine)
        if let link = item.link {
            Link(destination: link) { row }
                .foregroundStyle(.primary)
        } else {
            row
        }
    }
}

/// Announcements as a River: newest first, a card per day ("Today", "Yesterday", then dates).
struct NewsRiver: View {
    var items: [FeedItem]
    var isNew: (Date?) -> Bool

    var body: some View {
        let byDay = Dictionary(grouping: items) { Calendar.current.startOfDay(for: $0.published ?? .distantPast) }
        ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.title(day))
                    .font(.headline)
                    .padding(.horizontal, 4)
                VStack(alignment: .leading, spacing: 10) {
                    let dayItems = byDay[day] ?? []
                    ForEach(Array(dayItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0 {
                            Divider()
                                .padding(.leading, 68)
                        }
                        RiverRow(item: item, isNew: isNew(item.published))
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(TokenroomTokens.cardFill))
            }
        }
    }

    /// "Today", "Yesterday", or the date.
    static func title(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
}
