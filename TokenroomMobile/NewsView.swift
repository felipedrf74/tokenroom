import SwiftUI

struct NewsView: View {
    @Bindable var news: NewsStore
    @Bindable var store: MobileStore
    @Bindable var library: NewsLibrary
    @Bindable var skills: SkillsStore
    @AppStorage("newsDestination") private var destination: NewsDestination = .today
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var search = ""
    @State private var showsSearch = false
    @State private var contentWidth: CGFloat = 350

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !showsSearch { masthead }
                    selector
                    NewsReaderContent(news: news, library: library, skills: skills, destination: destination, query: search,
                                      suggestedProviders: Set(store.readings.map { $0.provider.id }))
                }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 32)
                    .environment(\.mobileNewsAvailableWidth, contentWidth)
            }
            .onGeometryChange(for: CGFloat.self) { max(0, $0.size.width - 40) } action: { contentWidth = $0 }
            .background(MobileNewsPalette.canvas)
            .navigationTitle("News")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(showsSearch ? .visible : .hidden, for: .navigationBar)
            .searchable(text: $search, isPresented: $showsSearch, placement: .navigationBarDrawer(displayMode: .automatic), prompt: destination == .skills ? "Search these skills" : "Search titles and sources")
            .refreshable {
                if destination == .skills { await skills.refresh(sort: skills.sort, force: true) }
                else if destination != .saved { await news.refresh(maxAge: 0, preferences: store.alertPreferences, notifies: false) }
            }
            .task { await news.keepCurrent(preferences: { store.alertPreferences }) }
            .onChange(of: destination) { _, _ in search = "" }
        }
    }
    private var masthead: some View {
        let layout = typeSize >= .xxLarge ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 4) {
                Text("News").font(.largeTitle.weight(.bold)).accessibilityAddTraits(.isHeader)
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
                    .font(.subheadline).foregroundStyle(MobileNewsPalette.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                Button { showsSearch = true } label: { mastheadIcon("magnifyingglass") }.accessibilityLabel("Search News")
                NavigationLink { NewsSettingsView(news: news, store: store) } label: { mastheadIcon("gearshape") }.accessibilityLabel("News settings")
            }.buttonStyle(.plain)
        }
    }
    private func mastheadIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(.primary).frame(width: 44, height: 44)
            .background(.thinMaterial, in: Circle())
    }
    @ViewBuilder private var selector: some View {
        if typeSize.isAccessibilitySize {
            Menu {
                ForEach(NewsDestination.allCases) { item in Button(item.rawValue, systemImage: item.symbol) { destination = item } }
            } label: { Label(destination.rawValue, systemImage: destination.symbol).frame(minHeight: 44) }
        } else {
            Picker("News destination", selection: $destination) {
                ForEach(NewsDestination.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).padding(.vertical, 6).frame(minHeight: 44)
                .accessibilityRepresentation {
                    HStack {
                        ForEach(NewsDestination.allCases) { item in
                            Button(item.rawValue) { destination = item }
                                .accessibilityAddTraits(destination == item ? .isSelected : [])
                        }
                    }.accessibilityElement(children: .contain)
                }
        }
    }
}

struct NewsSettingsView: View {
    @Bindable var news: NewsStore
    @Bindable var store: MobileStore
    @State private var search = ""

    var body: some View {
        Form {
            Section {
                Toggle("Notify me about new models", isOn: $store.alertPreferences.newModels)
            } footer: {
                Text("One notification per batch, from the labs you follow, held until quiet hours end.")
            }
            Section("Labs") {
                ForEach(news.vendorChoices.filter { NewsSearch.matches(search, title: $0.name, source: $0.id) }, id: \.id) { vendor in
                    Toggle(vendor.name, isOn: Binding(
                        get: { news.followedVendors.contains(vendor.id) },
                        set: { isOn in
                            if isOn { news.followedVendors.insert(vendor.id) } else { news.followedVendors.remove(vendor.id) }
                        }
                    ))
                }
            }
            Section {
                ForEach(FeedSource.toggles.filter { NewsSearch.matches(search, title: $0.name, source: $0.id) }) { source in
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
                Text("Choose curated voices and provider status in Following. Saved metadata stays on this device. Public articles open in your browser.")
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search labs and sources")
        .navigationTitle("Follow")
        .navigationBarTitleDisplayMode(.inline).toolbar(.visible, for: .navigationBar)
    }
}
