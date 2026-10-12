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
        VStack(alignment: .leading, spacing: 16) {
            Text("Your sources").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
            Menu {
                ForEach(Group.allCases, id: \.self) { value in Button(value.rawValue) { group = value } }
            } label: { Label(group.rawValue, systemImage: "line.3.horizontal.decrease").frame(minHeight: 44) }
            if !hasMatches { ContentUnavailableView.search(text: query) }
            if group == .all || group == .tools {
                if !suggestedProviders.isEmpty, query.isEmpty {
                    Button("Add the tools I use", systemImage: "plus.circle") {
                        news.followedSources.formUnion(FeedSource.toggles.filter { $0.provider.map { suggestedProviders.contains($0.rawValue) } ?? false }.map(\.id))
                    }.frame(minHeight: 44)
                }
                if !tools.isEmpty {
                    heading("Tools")
                    MobileNewsPanel {
                        VStack(spacing: 0) {
                            ForEach(Array(tools.enumerated()), id: \.element.id) { index, source in
                                if index > 0 { Divider() }
                                sourceRow(source)
                            }
                        }
                    }
                }
                if !labs.isEmpty {
                    heading("Model labs")
                    MobileNewsPanel {
                        VStack(spacing: 0) {
                            ForEach(Array(labs.enumerated()), id: \.element.id) { index, lab in
                                if index > 0 { Divider() }
                                Toggle(isOn: Binding(get: { news.followedVendors.contains(lab.id) }, set: { on in
                                    if on { news.followedVendors.insert(lab.id) } else { news.followedVendors.remove(lab.id) }
                                })) {
                                    HStack(spacing: 10) {
                                        LabMark(vendor: lab.id, name: lab.name, size: 32).accessibilityHidden(true)
                                        Text(lab.name).font(.subheadline.weight(.semibold))
                                    }
                                }.frame(minHeight: 52).accessibilityLabel("Follow \(lab.name) models")
                            }
                        }
                    }
                }
            }
            if (group == .all || group == .voices), !voices.isEmpty {
                heading("Curated voices")
                Text("Public articles and X profile links. A follow here stays in Tokenroom.").font(.footnote).foregroundStyle(MobileNewsPalette.secondary)
                MobileNewsPanel {
                    VStack(spacing: 0) {
                        ForEach(Array(voices.enumerated()), id: \.element.id) { index, voice in
                            if index > 0 { Divider() }
                            voiceRow(voice)
                        }
                    }
                }
            }
            if (group == .all || group == .status), !statuses.isEmpty {
                heading("Provider status")
                Text("Opt-in provider reports. Personal resets stay in Usage.").font(.footnote).foregroundStyle(MobileNewsPalette.secondary)
                MobileNewsPanel {
                    VStack(spacing: 0) {
                        ForEach(Array(statuses.enumerated()), id: \.element.id) { index, source in
                            if index > 0 { Divider() }
                            sourceRow(source)
                        }
                    }
                }
            }
        }
    }
    private func heading(_ title: String) -> some View {
        Text(title).font(.headline).accessibilityAddTraits(.isHeader)
    }
    private func sourceRow(_ source: FeedSource) -> some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return VStack(alignment: .leading, spacing: 8) {
            layout {
                NewsNavigationLink { NewsSourceDetail(news: news, library: library, source: source) } label: {
                    HStack(spacing: 10) {
                        MobileNewsSourceMark(sourceID: source.id, name: source.name, size: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                            Text(source.kind.label).font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(MobileNewsPalette.secondary)
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
                })).labelsHidden().frame(minHeight: 44).accessibilityLabel("Follow \(source.name)")
            }
            if news.sources.contains(where: { $0.id == source.id }) { NewsSourceHealth(news: news, source: source) }
        }.padding(.vertical, 8)
    }
    private func voiceRow(_ voice: NewsVoice) -> some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return layout {
            NewsNavigationLink { NewsVoiceDetail(voice: voice, news: news, library: library) } label: {
                HStack(spacing: 10) {
                    MonogramMark(text: voice.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined(), tint: MobileNewsPalette.actionFill, size: 36).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(voice.name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text(voice.feed == nil ? "Profile only" : "Public articles · X profile").font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Toggle("Follow \(voice.name)", isOn: Binding(get: { news.followedVoices.contains(voice.id) }, set: { on in
                if on { news.followedVoices.insert(voice.id) } else { news.followedVoices.remove(voice.id) }
            })).labelsHidden().frame(minHeight: 44).accessibilityLabel("Follow \(voice.name)")
        }.padding(.vertical, 8)
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
            Text("Discover skills").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
            if typeSize >= .xxLarge {
                Menu {
                    ForEach(SkillSort.allCases) { sort in Button(sort.label) { selectedSort.wrappedValue = sort } }
                } label: { Label(skills.sort.label, systemImage: "line.3.horizontal.decrease").frame(minHeight: 44) }
            } else {
                Picker("Skill ranking", selection: selectedSort) {
                    Text("Trending").tag(SkillSort.trending)
                    Text("Downloads").tag(SkillSort.downloads)
                    Text("Newest").tag(SkillSort.newest)
                }.pickerStyle(.segmented).frame(minHeight: 44)
                    .accessibilityRepresentation {
                        HStack {
                            ForEach(SkillSort.allCases) { sort in
                                Button(sort.label) { selectedSort.wrappedValue = sort }
                                    .accessibilityAddTraits(skills.sort == sort ? .isSelected : [])
                            }
                        }.accessibilityElement(children: .contain)
                    }
            }
            Text(skills.sort.explanation).font(.footnote).foregroundStyle(MobileNewsPalette.secondary)
            if let date = skills.checkedAt { Text("ClawHub · Checked \(RelativeTime.ago(date))").font(.caption).foregroundStyle(MobileNewsPalette.secondary) }
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
            ForEach(matching) { item in
                MobileNewsPanel {
                    let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                    layout {
                        NewsNavigationLink { SkillListingDetail(item: item, sort: skills.sort, checkedAt: skills.checkedAt, library: library) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(TokenroomTokens.accentText).accessibilityHidden(true)
                                    Text(item.rankText).font(.caption.weight(.semibold)).foregroundStyle(TokenroomTokens.accentText)
                                }
                                Text(item.name).font(.headline).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                Text(item.owner).font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                                if let summary = item.summary { Text(summary).font(.subheadline).foregroundStyle(MobileNewsPalette.secondary).lineLimit(3) }
                                Group {
                                    if typeSize >= .xxLarge { VStack(alignment: .leading, spacing: 4) { metrics(item) } }
                                    else {
                                        ViewThatFits(in: .horizontal) {
                                            HStack(spacing: 12) { metrics(item) }
                                            VStack(alignment: .leading, spacing: 4) { metrics(item) }
                                        }
                                    }
                                }.font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).multilineTextAlignment(.leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        NewsSaveButton(library: library, item: item.bookmark(sort: skills.sort, checkedAt: skills.checkedAt), compact: true)
                    }
                }
            }
            Link("Explore skills.sh", destination: URL(string: "https://skills.sh")!).frame(minHeight: 44)
        }.task { await skills.refresh(sort: skills.sort) }
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
            Text("Your reading list").font(.title2.weight(.bold)).accessibilityAddTraits(.isHeader)
            Menu {
                Button("All saved") { kind = nil }
                ForEach(NewsBookmark.Kind.allCases, id: \.self) { value in Button(value.rawValue.capitalized) { kind = value } }
            } label: { Label(kind?.rawValue.capitalized ?? "All saved", systemImage: "line.3.horizontal.decrease").frame(minHeight: 44) }
            if let problem = library.problem { Text(problem).font(.footnote).foregroundStyle(MobileNewsPalette.secondary) }
            if let removed = undo.item {
                Button { undo.restore(in: library) } label: {
                    Label("Undo removal of \(removed.title)", systemImage: "arrow.uturn.backward").font(.subheadline).frame(minHeight: 44)
                }
            }
            if items.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No saved items" : "No matching saved items", systemImage: "bookmark", description: Text("Saved titles, sources and supplied excerpts stay available on this device."))
            } else {
                MobileNewsPanel {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            savedRow(item)
                        }
                    }
                }
            }
            Text("Original articles require a connection.").font(.caption).foregroundStyle(MobileNewsPalette.secondary)
        }
    }
    private func savedRow(_ item: NewsBookmark) -> some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .top, spacing: 4))
        return layout {
            NewsNavigationLink { NewsSavedDetail(item: item, library: library) } label: {
                HStack(alignment: .top, spacing: 10) {
                    if item.kind == .skill {
                        Image(systemName: "puzzlepiece.extension.fill").font(.title3).foregroundStyle(TokenroomTokens.accentText).frame(width: 36).accessibilityHidden(true)
                    } else { MobileNewsSourceMark(name: item.publisher, size: 36) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.publisher + " · " + item.kind.rawValue.capitalized).font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(typeSize.isAccessibilitySize ? nil : 3).fixedSize(horizontal: false, vertical: true)
                        Text("Saved \(item.savedAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(MobileNewsPalette.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minHeight: 44).multilineTextAlignment(.leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(role: .destructive) { undo.remove(id: item.id, aliases: item.aliases, from: library) } label: {
                Image(systemName: "bookmark.slash").font(.system(size: 18)).frame(width: 44, height: 44)
            }.accessibilityLabel("Remove \(item.title) from saved")
        }.padding(.vertical, 10)
    }
}
#endif
