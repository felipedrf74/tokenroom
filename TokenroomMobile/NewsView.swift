import SwiftUI

/// News as a short daily paper about your tools: Today (what's new since you looked, one top
/// story, more new models, each tool's own news, models retiring soon), then each kind of item
/// on its own. Announcements read as a River, newest first by day.
struct NewsView: View {
    @Bindable var news: NewsStore
    @Bindable var store: MobileStore
    @AppStorage("newsSection") private var filter: NewsFilter = .today
    @State private var showsAllLabs = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    chips
                    switch filter {
                    case .today: today
                    case .models: modelsList
                    case .announcements: river
                    case .retiring: retiringList
                    }
                    footer
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("News")
            .navigationSubtitle(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        NewsSettingsView(news: news, store: store)
                    } label: {
                        Label("Follow", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .refreshable {
                await news.refresh(maxAge: 0, preferences: store.alertPreferences)
            }
            .task {
                await news.refresh(maxAge: NewsFetcher.openInterval, preferences: store.alertPreferences)
            }
            .onAppear {
                // Clears the tab's badge; this visit's new items stay marked.
                news.markSeen()
            }
            .overlay {
                if isEmpty {
                    if news.isRefreshing {
                        ProgressView()
                    } else {
                        ContentUnavailableView("Nothing yet", systemImage: "newspaper", description: Text(problem ?? "Pull down to check for news."))
                    }
                }
            }
        }
    }

    private var edition: NewsEdition {
        NewsEditions.today(models: news.models(), announcements: news.announcements, retiring: news.retiring, since: news.visitBaseline)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(NewsFilter.allCases) { item in
                    Button {
                        filter = item
                    } label: {
                        Text(item.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(filter == item ? Color(.systemBackground) : Color.primary)
                            .background(Capsule().fill(filter == item ? Color.primary : Color(.tertiarySystemFill)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(filter == item ? .isSelected : [])
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, -20)
    }

    @ViewBuilder
    private var today: some View {
        let edition = edition
        if !edition.digest.isEmpty {
            section("Since you last looked · \(RelativeTime.ago(news.visitBaseline))") {
                NewsDigestView(digest: edition.digest) { filter = $0 }
            }
        }
        if let top = edition.topStory {
            section("Top story") {
                TopStoryView(release: top, isNew: news.isNew(top.created))
            }
        }
        if !edition.moreModels.isEmpty {
            section(edition.topStory == nil ? "New models" : "More new models", action: ("See All", { filter = .models })) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(edition.moreModels) { release in
                            ModelCardView(release: release, isNew: news.isNew(release.created))
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.horizontal, -20)
            }
        }
        if !edition.tools.isEmpty {
            section("From your tools", action: ("Follow…", nil)) {
                VStack(spacing: 12) {
                    ForEach(edition.tools.prefix(6)) { tool in
                        ToolNewsCard(tool: tool) { news.isNew($0) }
                    }
                }
            }
        }
        if !edition.retiring.isEmpty {
            section("Retiring soon") {
                card {
                    ForEach(Array(edition.retiring.prefix(5).enumerated()), id: \.element.id) { index, release in
                        if index > 0 { Divider().padding(.leading, 56) }
                        RetiringModelRow(release: release)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var modelsList: some View {
        let models = news.models(all: showsAllLabs)
        if !models.isEmpty {
            section(showsAllLabs ? "All labs" : "Labs you follow", action: (showsAllLabs ? "Followed" : "All", { showsAllLabs.toggle() })) {
                card {
                    ForEach(Array(models.prefix(50).enumerated()), id: \.element.id) { index, release in
                        if index > 0 { Divider() }
                        ModelReleaseRow(release: release, isNew: news.isNew(release.created))
                    }
                }
            }
        }
        if let problem = news.modelProblem {
            Text(problem).font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var river: some View {
        let byDay = Dictionary(grouping: news.announcements) { item in
            Calendar.current.startOfDay(for: item.published ?? .distantPast)
        }
        ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
            section(dayTitle(day)) {
                card {
                    let items = byDay[day] ?? []
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, 68) }
                        RiverRow(item: item, isNew: news.isNew(item.published))
                    }
                }
            }
        }
        if let problem = news.announcementProblem {
            Text(problem).font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var retiringList: some View {
        let retiring = news.retiring
        if !retiring.isEmpty {
            section("Retiring") {
                card {
                    ForEach(Array(retiring.enumerated()), id: \.element.id) { index, release in
                        if index > 0 { Divider().padding(.leading, 56) }
                        RetiringModelRow(release: release)
                    }
                }
            }
        }
    }

    private var footer: some View {
        Text("From OpenRouter's public model list and each tool's official changelog, blog, or releases. Tokenroom shows titles and links and opens the rest in Safari. Tokenroom isn't affiliated with these providers.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    /// "Today", "Yesterday", or the date.
    private func dayTitle(_ day: Date) -> String {
        if Calendar.current.isDateInToday(day) { return "Today" }
        if Calendar.current.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func section<Content: View>(_ title: String, action: (String, (() -> Void)?)? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                if let action {
                    if let run = action.1 {
                        Button(action.0, action: run)
                            .font(.subheadline)
                    } else {
                        NavigationLink(action.0) {
                            NewsSettingsView(news: news, store: store)
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 4)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
    }

    private var isEmpty: Bool {
        switch filter {
        case .today: news.models().isEmpty && news.announcements.isEmpty
        case .models: news.models(all: showsAllLabs).isEmpty
        case .announcements: news.announcements.isEmpty
        case .retiring: news.retiring.isEmpty
        }
    }

    private var problem: String? {
        switch filter {
        case .today, .models: news.modelProblem ?? news.announcementProblem
        case .announcements: news.announcementProblem
        case .retiring: news.modelProblem
        }
    }
}

struct NewsSettingsView: View {
    @Bindable var news: NewsStore
    @Bindable var store: MobileStore

    var body: some View {
        Form {
            Section {
                Toggle("Notify me about new models", isOn: $store.alertPreferences.newModels)
            } footer: {
                Text("One notification per batch, from the labs you follow, held until quiet hours end.")
            }
            Section("Labs") {
                ForEach(news.vendorChoices, id: \.id) { vendor in
                    Toggle(vendor.name, isOn: Binding(
                        get: { news.followedVendors.contains(vendor.id) },
                        set: { isOn in
                            if isOn { news.followedVendors.insert(vendor.id) } else { news.followedVendors.remove(vendor.id) }
                        }
                    ))
                }
            }
            Section {
                ForEach(FeedSource.toggles) { source in
                    Toggle(source.name, isOn: Binding(
                        get: { news.followedSources.contains(source.id) },
                        set: { isOn in
                            if isOn { news.followedSources.insert(source.id) } else { news.followedSources.remove(source.id) }
                        }
                    ))
                }
            } header: {
                Text("Announcements")
            } footer: {
                Text("Official changelogs and blogs only. Tokenroom shows titles and links, and opens the rest in Safari.")
            }
        }
        .navigationTitle("Follow")
        .navigationBarTitleDisplayMode(.inline)
    }
}
