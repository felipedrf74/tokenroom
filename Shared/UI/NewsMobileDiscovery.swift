import SwiftUI

#if os(iOS)
struct MobileNewsFollowing: View {
    private enum Group: String, CaseIterable { case all = "All sources", tools = "Tools & Labs", voices = "Curated voices", status = "Provider status" }
    @State private var group: Group = .all
    @Environment(\.dynamicTypeSize) private var typeSize
    @Bindable var news: NewsStore
    @Bindable var library: NewsLibrary
    var query = ""
    var suggestedProviders: Set<String> = []
    private var tools: [FeedSource] { FeedSource.toggles.filter { NewsSearch.matches(query, title: $0.name, source: "") } }
    private var voices: [NewsVoice] { NewsVoice.catalog.filter { NewsSearch.matches(query, title: $0.name, source: "") } }
    private var statuses: [FeedSource] { NewsStatusSource.catalog.filter { NewsSearch.matches(query, title: $0.name, source: "") } }
    private var labs: [(id: String, name: String)] { news.vendorChoices.filter { NewsSearch.matches(query, title: $0.name, source: "") } }
    private var hasMatches: Bool {
        ((group == .all || group == .tools) && (!tools.isEmpty || !labs.isEmpty)) ||
        ((group == .all || group == .voices) && !voices.isEmpty) ||
        ((group == .all || group == .status) && !statuses.isEmpty)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MobileNewsPageHeading(title: "Your sources", filterName: "Source group", filter: group.rawValue) {
                Picker("Source group", selection: $group) {
                    ForEach(Group.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.inline).labelsHidden()
            }
            if !hasMatches { ContentUnavailableView.search(text: query) }
            if group == .all || group == .tools {
                if !tools.isEmpty {
                    let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                    layout {
                        heading("Tools").frame(maxWidth: .infinity, alignment: .leading)
                        if !suggestedProviders.isEmpty, query.isEmpty {
                            Button("Add the tools I use") {
                                news.followedSources.formUnion(FeedSource.toggles.filter { $0.provider.map { suggestedProviders.contains($0.rawValue) } ?? false }.map(\.id))
                            }.buttonStyle(.plain).font(.subheadline).fontWeight(.medium).foregroundStyle(TokenroomTokens.newsAction).frame(minHeight: 44)
                        }
                    }.padding(.bottom, -8)
                    rows(tools) { sourceRow($0) }
                }
                if !labs.isEmpty {
                    heading("Model labs").padding(.top, 8)
                    rows(labs.map(LabChoice.init)) { lab in
                        Toggle(isOn: Binding(get: { news.followedVendors.contains(lab.id) }, set: { on in
                            if on { news.followedVendors.insert(lab.id) } else { news.followedVendors.remove(lab.id) }
                        })) {
                            HStack(spacing: 10) {
                                LabMark(vendor: lab.id, name: lab.name, size: 30).accessibilityHidden(true)
                                Text(lab.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            }
                        }.toggleStyle(NewsFollowToggleStyle()).padding(.trailing, -12).padding(.vertical, 2).accessibilityLabel("Follow \(lab.name) models")
                    }
                }
            }
            if (group == .all || group == .voices), !voices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        heading("Curated voices")
                        Text("Public articles and X profile links. A follow here stays in Tokenroom.").font(.footnote).foregroundStyle(MobileNewsPalette.secondary)
                    }
                    rows(voices) { voiceRow($0) }
                }.padding(.top, 8)
            }
            if (group == .all || group == .status), !statuses.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        heading("Provider status")
                        Text("Opt-in provider reports. Personal resets stay in Usage.").font(.footnote).foregroundStyle(MobileNewsPalette.secondary)
                    }
                    rows(statuses) { sourceRow($0) }
                }.padding(.top, 8)
            }
        }
    }
    private struct LabChoice: Identifiable {
        var id: String
        var name: String
        init(_ lab: (id: String, name: String)) { id = lab.id; name = lab.name }
    }
    /// One card of rows split by hairlines, with the source's follow mark at each row's end.
    private func rows<Item: Identifiable, Row: View>(_ items: [Item], @ViewBuilder row: @escaping (Item) -> Row) -> some View {
        MobileNewsPanel(verticalPadding: 2) {
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    row(item)
                }
            }
        }
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
    }
    /// The row's name. Tapping the row opens the source; the mark at its end follows it.
    private func rowTitle(_ name: String) -> some View {
        Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
    }
    private func sourceRow(_ source: FeedSource) -> some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .center, spacing: 4))
        let health = news.sources.contains(where: { $0.id == source.id }) ? news.sourceHealth(for: source) : nil
        return VStack(alignment: .leading, spacing: 4) {
            layout {
                NewsNavigationLink { NewsSourceDetail(news: news, library: library, source: source) } label: {
                    HStack(spacing: 10) {
                        MobileNewsSourceMark(sourceID: source.id, name: source.name, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            rowTitle(source.name)
                            if let caption = health?.followingCaption {
                                Text(caption).font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Toggle("Follow \(source.name)", isOn: Binding(get: {
                    source.kind == .officialStatus ? news.followedStatusSources.contains(source.id) : news.followedSources.contains(source.id)
                }, set: { on in
                    if source.kind == .officialStatus {
                        if on { news.followedStatusSources.insert(source.id) } else { news.followedStatusSources.remove(source.id) }
                    } else {
                        if on { news.followedSources.insert(source.id) } else { news.followedSources.remove(source.id) }
                    }
                })).toggleStyle(NewsFollowToggleStyle(showsLabel: false)).padding(.trailing, -12).accessibilityLabel("Follow \(source.name)")
            }
            if health != nil { NewsSourceHealth(news: news, source: source, showsCaption: false).padding(.leading, 40).padding(.bottom, 4) }
        }.padding(.vertical, 2)
    }
    private func voiceRow(_ voice: NewsVoice) -> some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .center, spacing: 4))
        return layout {
            NewsNavigationLink { NewsVoiceDetail(voice: voice, news: news, library: library) } label: {
                HStack(spacing: 10) {
                    MonogramMark(text: voice.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined(), tint: TokenroomTokens.newsMonogramTint, size: 30).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        rowTitle(voice.name)
                        Text(voice.feed == nil ? "Profile only" : "Public articles · X profile").font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Toggle("Follow \(voice.name)", isOn: Binding(get: { news.followedVoices.contains(voice.id) }, set: { on in
                if on { news.followedVoices.insert(voice.id) } else { news.followedVoices.remove(voice.id) }
            })).toggleStyle(NewsFollowToggleStyle(showsLabel: false)).padding(.trailing, -12).accessibilityLabel("Follow \(voice.name)")
        }.padding(.vertical, 2)
    }
}

struct MobileNewsSkillsShelf: View {
    @Bindable var skills: SkillsStore
    @Bindable var library: NewsLibrary
    var query = ""
    @Environment(\.dynamicTypeSize) private var typeSize
    private var matching: [SkillListing] {
        skills.listings.filter { NewsSearch.matches(query, title: $0.name + " " + ($0.summary ?? ""), source: $0.owner) }
    }
    private var selectedSort: Binding<SkillSort> {
        Binding(get: { skills.sort }, set: { value in Task { await skills.refresh(sort: value) } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MobileNewsPageHeading(title: "Discover skills", filterName: "Skill ranking", filter: skills.sort.label) {
                Picker("Skill ranking", selection: selectedSort) {
                    ForEach(SkillSort.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.inline).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(skills.sort.explanation).font(.footnote).foregroundStyle(MobileNewsPalette.secondary)
                if let date = skills.checkedAt { Text("ClawHub · Checked \(RelativeTime.ago(date))").font(.footnote).foregroundStyle(MobileNewsPalette.secondary) }
            }
            if skills.isRefreshing { ProgressView("Checking skills…") }
            if let problem = skills.problem {
                MobileNewsPanel {
                    Text(problem).font(.subheadline).foregroundStyle(MobileNewsPalette.secondary)
                    if let retry = skills.retryAt { Text("Retry after \(retry.formatted(date: .omitted, time: .shortened))").font(.caption) }
                    Button("Retry skills") { Task { await skills.refresh(sort: skills.sort, force: true) } }.frame(minHeight: 44)
                }
            }
            if matching.isEmpty, !skills.isRefreshing {
                let successfullyEmpty = query.isEmpty && skills.checkedAt != nil && skills.problem == nil
                ContentUnavailableView(query.isEmpty ? (successfullyEmpty ? "No skills in this ranking" : "No skills loaded") : "No matching skills", systemImage: "puzzlepiece.extension", description: Text(query.isEmpty ? (successfullyEmpty ? "Choose another ranking or check again later." : "Try again when ClawHub is available.") : "Search filters this loaded shelf of up to 30 skills."))
            }
            if !matching.isEmpty {
                MobileNewsPanel(verticalPadding: 2) {
                    VStack(spacing: 0) {
                        ForEach(Array(matching.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            skillRow(item)
                        }
                    }
                }
            }
            Link(destination: URL(string: "https://skills.sh")!) { NewsLinkLabel(title: "Explore skills.sh", symbol: "arrow.up.right") }.frame(minHeight: 44)
        }.task { await skills.refresh(sort: skills.sort) }
    }
    private func skillRow(_ item: SkillListing) -> some View {
        let stacked = typeSize >= .xxLarge
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(ZStackLayout(alignment: .topTrailing))
        return layout {
            NewsNavigationLink { SkillListingDetail(item: item, sort: skills.sort, checkedAt: skills.checkedAt, library: library) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.rankText + " · " + item.owner).font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                    Text(item.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    if let summary = item.summary { Text(summary).font(.subheadline).foregroundStyle(MobileNewsPalette.secondary).lineLimit(3) }
                    SwiftUI.Group {
                        if stacked { VStack(alignment: .leading, spacing: 4) { metrics(item) } }
                        else {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) { metrics(item) }
                                VStack(alignment: .leading, spacing: 4) { metrics(item) }
                            }
                        }
                    }.font(.caption).foregroundStyle(MobileNewsPalette.secondary).padding(.top, 2)
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).multilineTextAlignment(.leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            NewsSaveButton(library: library, item: item.bookmark(sort: skills.sort, checkedAt: skills.checkedAt), compact: true)
                .buttonStyle(.plain).padding(.top, stacked ? 0 : -14).padding(.trailing, stacked ? 0 : -14)
        }.padding(.vertical, 12)
    }
    @ViewBuilder private func metrics(_ item: SkillListing) -> some View {
        if let downloads = item.downloads { Label("\(downloads.formatted()) lifetime downloads", systemImage: "arrow.down").fixedSize(horizontal: false, vertical: true) }
        if let stars = item.stars { Label(stars.formatted(), systemImage: "star").accessibilityLabel("\(stars) stars") }
    }
}

struct MobileNewsSavedList: View {
    @Bindable var library: NewsLibrary
    var query = ""
    @State private var kind: NewsBookmark.Kind?
    @State private var undo = NewsRemovalUndo()
    @Environment(\.dynamicTypeSize) private var typeSize
    private var items: [NewsBookmark] {
        library.saved.filter { (kind == nil || $0.kind == kind) && NewsSearch.matches(query, title: $0.title, source: $0.publisher) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MobileNewsPageHeading(title: "Your reading list", filterName: "Saved item kind", filter: kind?.rawValue.capitalized ?? "All saved") {
                Picker("Saved item kind", selection: $kind) {
                    Text("All saved").tag(Optional<NewsBookmark.Kind>.none)
                    ForEach(NewsBookmark.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag(Optional.some($0)) }
                }.pickerStyle(.inline).labelsHidden()
            }
            if let problem = library.problem { Text(problem).font(.footnote).foregroundStyle(MobileNewsPalette.secondary) }
            if let removed = undo.item {
                Button { undo.restore(in: library) } label: {
                    Label("Undo removal of \(removed.title)", systemImage: "arrow.uturn.backward").font(.subheadline).frame(minHeight: 44)
                }
            }
            if items.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No saved items" : "No matching saved items", systemImage: "bookmark", description: Text("Saved titles, sources and supplied excerpts stay available on this device."))
            } else {
                MobileNewsPanel(verticalPadding: 2) {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            savedRow(item)
                        }
                    }
                }
            }
            if !items.isEmpty {
                Text("Original articles require a connection.").font(.caption).foregroundStyle(MobileNewsPalette.secondary)
            }
        }
    }
    private func savedRow(_ item: NewsBookmark) -> some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .top, spacing: 4))
        return layout {
            NewsNavigationLink { NewsSavedDetail(item: item, library: library) } label: {
                HStack(alignment: .top, spacing: 10) {
                    if item.kind == .skill {
                        Image(systemName: "puzzlepiece.extension").font(.title3).foregroundStyle(MobileNewsPalette.secondary).frame(width: 32).accessibilityHidden(true)
                    } else { MobileNewsSourceMark(name: item.publisher, size: 32) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.publisher + " · " + item.kind.rawValue.capitalized).font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(typeSize.isAccessibilitySize ? nil : 3).fixedSize(horizontal: false, vertical: true)
                        Text("Saved \(item.savedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 44).multilineTextAlignment(.leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(role: .destructive) { undo.remove(id: item.id, aliases: item.aliases, from: library) } label: {
                Image(systemName: "bookmark.slash").font(.system(size: 16)).frame(width: 44, height: 44)
            }.buttonStyle(.plain).foregroundStyle(MobileNewsPalette.secondary).accessibilityLabel("Remove \(item.title) from saved")
        }.padding(.vertical, 10)
    }
}
#endif
