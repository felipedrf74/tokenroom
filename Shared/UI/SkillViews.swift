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
                Image(systemName: "puzzlepiece.extension").font(.largeTitle).foregroundStyle(TokenroomTokens.accentText).accessibilityHidden(true)
                Text("ClawHub · \(item.owner)").font(.headline).foregroundStyle(NewsControlMetrics.secondaryText)
                Text(item.name).font(.system(.largeTitle, design: .serif, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                if let summary = item.summary { Text(summary).textSelection(.enabled) }
                Text("Version: \(item.version ?? "Not specified")")
                if let date = item.updatedAt { Text("Updated \(date.formatted())").font(.footnote) }
                Text("Declared requirements").font(.headline)
                Text(item.requirements.isEmpty ? "Not specified" : item.requirements.joined(separator: "\n"))
                Text("Agent compatibility: Not specified").foregroundStyle(NewsControlMetrics.secondaryText)
                Text("\(sort.label) · \(item.rankText)").font(.headline)
                Text(sort.explanation).font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
                if let downloads = item.downloads { Text("\(downloads.formatted()) lifetime downloads") }
                if let stars = item.stars { Text("\(stars.formatted()) stars") }
                if let checkedAt { Text("Ranking checked \(checkedAt.formatted())").font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText) }
                NewsDetailActions(library: library, item: item.bookmark(sort: sort, checkedAt: checkedAt), openLabel: "Open on ClawHub")
                Text("Publisher metadata. Popularity does not establish compatibility. Tokenroom opens the listing for you to review.").font(.footnote).foregroundStyle(NewsControlMetrics.secondaryText)
            }.newsDetailLayout()
        }.newsReaderCanvas().navigationTitle("Skill")
    }
}

struct SkillsShelf: View {
    @Bindable var skills: SkillsStore
    @Bindable var library: NewsLibrary
    var query = ""
    var body: some View {
        #if os(macOS)
        MacNewsSkillsShelf(skills: skills, library: library, query: query)
        #else
        MobileNewsSkillsShelf(skills: skills, library: library, query: query)
        #endif
    }
}
#endif
