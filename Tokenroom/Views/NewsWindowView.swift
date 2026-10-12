import SwiftUI

/// The Mac's News sections are the iPhone's filters: Today, Models, Announcements, Retiring.
typealias NewsSection = NewsFilter

extension NewsFilter {
    static let defaultsKey = "macNewsSection"

    var symbol: String {
        switch self {
        case .today: "newspaper"
        case .models: "sparkles"
        case .announcements: "megaphone"
        case .retiring: "hourglass"
        }
    }
}

/// What the News window shows: one of the filters, a lab's models, or a tool's announcements.
enum NewsPage: Hashable {
    case destination(NewsDestination)
    case filter(NewsFilter)
    case lab(String)
    case tool(String)
}

/// The section the News window should show, set each time the popover opens it.
@Observable
@MainActor
final class NewsPageRequest {
    private(set) var section: NewsSection = .today
    /// Counts requests, so asking again for the section last asked for still leaves a lab, a
    /// tool, or a search the window shows now.
    private(set) var count = 0

    func open(_ section: NewsSection) {
        self.section = section
        count += 1
    }
}

/// Native sidebar navigation over the shared device-local reader.
struct NewsWindowView: View {
    @Bindable var store: QuotaStore
    var request: NewsPageRequest?
    var onOpenSettings: () -> Void
    @AppStorage(NewsSection.defaultsKey) private var savedFilter: NewsFilter = .today
    @State private var page: NewsPage?
    @State private var search = ""
    @State private var library = NewsRuntime.library()
    @State private var skills: SkillsStore
    @State private var collectionsExpanded = true
    @State private var labsExpanded = true
    @State private var toolsExpanded = false

    init(store: QuotaStore, request: NewsPageRequest? = nil, onOpenSettings: @escaping () -> Void, page: NewsPage? = nil) {
        self.store = store; self.request = request; self.onOpenSettings = onOpenSettings
        _page = State(initialValue: page)
        let skills = NewsRuntime.skillsStore()
        skills.allowsRefresh = { [weak store] in store?.settings.newsEnabled == true }
        _skills = State(initialValue: skills)
    }
    var body: some View {
        Group {
            if store.settings.newsEnabled, let news = store.news { content(news) }
            else {
                VStack(spacing: 20) {
                    Image(systemName: "newspaper").font(.largeTitle)
                    Text("Your AI briefing").font(.system(.largeTitle, design: .serif))
                    Text("Official updates, public articles and skills. Sources are public; your usage stays private.").foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
                    Button("Turn On News") { store.settings.newsEnabled = true; Task { await store.refreshNews(force: true) } }.buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(32)
            }
        }.frame(minWidth: 820, idealWidth: 1160, minHeight: 560, idealHeight: 800)
            .onChange(of: request?.count, initial: true) {
                guard let request, request.count > 0 else { return }
                search = ""
                page = request.section == .today ? .destination(.today) : .filter(request.section)
            }
    }
    private func content(_ news: NewsStore) -> some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    ForEach(NewsDestination.allCases) { item in Label(item.rawValue, systemImage: item.symbol).tag(NewsPage.destination(item)) }
                }
                Section(isExpanded: $collectionsExpanded) {
                        ForEach(NewsFilter.allCases.filter { $0 != .today }) { item in Label(item.rawValue, systemImage: item.symbol).tag(NewsPage.filter(item)) }
                        Label("Voices", systemImage: "person.2").tag(NewsPage.tool("voices"))
                        Label("Status", systemImage: "waveform.path.ecg").tag(NewsPage.tool("status"))
                } header: { Text("Collections") }
                Section("Sources") {
                    DisclosureGroup("Model labs", isExpanded: $labsExpanded) {
                        ForEach(news.vendorChoices.filter { news.followedVendors.contains($0.id) }, id: \.id) { lab in
                            HStack(spacing: 10) { LabMark(vendor: lab.id, name: lab.name, size: 20); Text(lab.name) }.tag(NewsPage.lab(lab.id))
                        }
                    }
                    DisclosureGroup("Tools", isExpanded: $toolsExpanded) {
                        ForEach(FeedSource.toggles.filter { news.followedSources.contains($0.id) }) { source in
                            HStack(spacing: 10) { MacNewsSourceMark(sourceID: source.id, name: source.name, size: 20); Text(source.name) }.tag(NewsPage.tool(source.id))
                        }
                    }
                }
            }.listStyle(.sidebar).navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            NavigationStack {
                detail(news)
                    .navigationTitle(title)
            }
            .toolbar {
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .principal) { windowBrand }.sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .principal) { windowBrand }
                }
                NewsWindowToolbar(commands: windowCommands(news))
            }.id(page)
        }
        .id(request?.count)
        // Pushed views own the visible AppKit toolbar, so they receive these
        // window commands rather than relying on the hidden root's toolbar.
        .environment(\.newsWindowCommands, windowCommands(news))
        .onAppear { if page == nil { page = request?.section == .today || request == nil && savedFilter == .today ? .destination(.today) : .filter(request?.section ?? savedFilter) } }
        .onChange(of: page) { _, page in search = ""; if case .filter(let filter)? = page { savedFilter = filter } }
    }
    private var windowBrand: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
            Text("Tokenroom News").font(.system(size: 14, weight: .medium))
        }
    }
    private func windowCommands(_ news: NewsStore) -> NewsWindowCommands {
        NewsWindowCommands(isChecking: news.isRefreshing || skills.isRefreshing, checkNow: {
            Task {
                if page == .destination(.skills) { await skills.refresh(sort: skills.sort, force: true) }
                else { await store.refreshNews(force: true) }
            }
        }, openSettings: onOpenSettings, settingsEnabled: !NewsRuntime.isInert())
    }
    @ViewBuilder private func detail(_ news: NewsStore) -> some View {
        switch page ?? .destination(.today) {
        case .destination(let destination): reader(news, destination: destination)
        case .filter(.today): reader(news, destination: .today)
        case .filter(.models): NewsCollectionView(news: news, library: library, collection: .model)
        case .filter(.announcements): NewsCollectionView(news: news, library: library, collection: .release)
        case .filter(.retiring): NewsCollectionView(news: news, library: library, collection: .retirement)
        case .lab(let vendor): NewsCollectionView(news: news, library: library, collection: .model, vendorID: vendor)
        case .tool(let id):
            if id == "voices" { NewsCollectionView(news: news, library: library, collection: .voice) }
            else if id == "status" { NewsCollectionView(news: news, library: library, collection: .status) }
            else if let source = FeedSource.toggles.first(where: { $0.id == id || $0.name == id }) { NewsSourceDetail(news: news, library: library, source: source) }
            else { ContentUnavailableView("Source unavailable", systemImage: "newspaper") }
        }
    }
    private func reader(_ news: NewsStore, destination: NewsDestination) -> some View {
        GeometryReader { viewport in
            ScrollView {
                NewsReaderContent(news: news, library: library, skills: skills, destination: destination, query: search,
                                  suggestedProviders: Set(store.statuses.compactMap { provider, status in status.snapshot == nil ? nil : provider.rawValue }))
                    .environment(\.macNewsAvailableWidth, max(0, min(1160, viewport.size.width) - 48))
                    .padding(24).frame(maxWidth: 1160, alignment: .leading).frame(maxWidth: .infinity)
            }
        }.searchable(text: $search, placement: .toolbar, prompt: destination == .skills ? "Search these skills" : "Search titles and sources")
    }
    private var title: String {
        switch page ?? .destination(.today) {
        case .destination(let item): item.rawValue
        case .filter(let item): item.rawValue
        case .lab(let id): store.news?.vendorChoices.first { $0.id == id }?.name ?? id
        case .tool(let id): FeedSource.toggles.first { $0.id == id }?.name ?? id.capitalized
        }
    }
}
