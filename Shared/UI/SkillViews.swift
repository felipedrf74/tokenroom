import SwiftUI

#if os(iOS) || os(macOS)
struct SkillListingDetail: View {
    var item: SkillListing
    var sort: SkillSort
    var checkedAt: Date?
    @Bindable var library: NewsLibrary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("ClawHub · \(item.owner)").font(.headline).foregroundStyle(.secondary)
                Text(item.name).font(.system(.largeTitle, design: .serif, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                if let summary = item.summary { Text(summary).textSelection(.enabled) }
                Text("Version: \(item.version ?? "Not specified")")
                if let date = item.updatedAt { Text("Updated \(date.formatted())").font(.footnote) }
                Text("Declared requirements").font(.headline)
                Text(item.requirements.isEmpty ? "Not specified" : item.requirements.joined(separator: "\n"))
                Text("Agent compatibility: Not specified").foregroundStyle(.secondary)
                Text("\(sort.label) · \(item.rankText)").font(.headline)
                Text(sort.explanation).font(.footnote).foregroundStyle(.secondary)
                if let downloads = item.downloads { Text("\(downloads.formatted()) lifetime downloads") }
                if let stars = item.stars { Text("\(stars.formatted()) stars") }
                if let checkedAt { Text("Ranking checked \(checkedAt.formatted())").font(.footnote).foregroundStyle(.secondary) }
                NewsDetailActions(library: library, item: item.bookmark(sort: sort, checkedAt: checkedAt), openLabel: "Open on ClawHub")
                Text("Publisher metadata. Popularity does not establish compatibility. Tokenroom opens the listing for you to review.").font(.footnote).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.navigationTitle("Skill")
    }
}

struct SkillsShelf: View {
    @Bindable var skills: SkillsStore
    @Bindable var library: NewsLibrary
    var query = ""
    private var matching: [SkillListing] {
        skills.listings.filter { NewsSearch.matches(query, title: $0.name + " " + ($0.summary ?? ""), source: $0.owner) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Menu {
                ForEach(SkillSort.allCases) { sort in Button(sort.label) { Task { await skills.refresh(sort: sort) } } }
            } label: { Label(skills.sort.label, systemImage: "line.3.horizontal.decrease").frame(minHeight: 44) }
            Text("Discover skills in the ClawHub ecosystem").font(.headline)
            Text(skills.sort.explanation).font(.footnote).foregroundStyle(.secondary)
            if let date = skills.checkedAt { Text("ClawHub · Checked \(RelativeTime.ago(date))").font(.footnote).foregroundStyle(.secondary) }
            if skills.isRefreshing { ProgressView("Checking skills…") }
            if let problem = skills.problem {
                Text(problem).foregroundStyle(.secondary)
                if let retry = skills.retryAt { Text("Retry after \(retry.formatted(date: .omitted, time: .shortened))").font(.footnote) }
                Button("Retry skills") { Task { await skills.refresh(sort: skills.sort, force: true) } }.frame(minHeight: 44)
            }
            if matching.isEmpty, !skills.isRefreshing {
                let successfullyEmpty = query.isEmpty && skills.checkedAt != nil && skills.problem == nil
                ContentUnavailableView(query.isEmpty ? (successfullyEmpty ? "No skills in this ranking" : "No skills loaded") : "No matching skills", systemImage: "sparkles", description: Text(query.isEmpty ? (successfullyEmpty ? "ClawHub returned an empty ranking. Choose another ranking or check again later." : "Try again when ClawHub is available.") : "Search filters this loaded shelf of up to 30 skills."))
            }
            ForEach(matching) { item in
                NewsCard {
                    NewsNavigationLink { SkillListingDetail(item: item, sort: skills.sort, checkedAt: skills.checkedAt, library: library) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ClawHub · \(item.rankText) · \(item.owner)").font(.caption).foregroundStyle(.secondary)
                            Text(item.name).font(.system(.headline, design: .serif)).foregroundStyle(.primary)
                            if let summary = item.summary { Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
                            if let downloads = item.downloads { Text("\(downloads.formatted()) lifetime downloads").font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).multilineTextAlignment(.leading)
                    }.buttonStyle(.plain)
                    NewsSaveButton(library: library, item: item.bookmark(sort: skills.sort, checkedAt: skills.checkedAt))
                }
            }
            Link("Explore skills.sh", destination: URL(string: "https://skills.sh")!).frame(minHeight: 44)
        }.task { await skills.refresh(sort: skills.sort) }
    }
}
#endif
