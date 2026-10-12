import Foundation

/// Runtime composition keeps screenshot/test hosts inert and stores device-local saves
/// separately from the usage relay and the transient public catalog.
@MainActor enum NewsRuntime {
    static let isolatedDefaults: UserDefaults = {
        let name = "TokenroomInertNewsHost"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()
    static func isInert(launchDefaults: UserDefaults = .standard,
                        isUnitTestHost: Bool = LaunchEnvironment.isUnitTestHost) -> Bool {
        if isUnitTestHost { return true }
        #if DEBUG
        if launchDefaults.bool(forKey: "TokenroomNewsPreview") { return true }
        return ["TokenroomSnapshotNews", "TokenroomSnapshots", "TokenroomGallery"].contains {
            launchDefaults.string(forKey: $0) != nil
        }
        #else
        return false
        #endif
    }
    static func newsStore(launchDefaults: UserDefaults = .standard,
                          isUnitTestHost: Bool = LaunchEnvironment.isUnitTestHost,
                          inertDefaults: UserDefaults? = nil) -> NewsStore {
        if isInert(launchDefaults: launchDefaults, isUnitTestHost: isUnitTestHost) {
            #if DEBUG
            let fixture = launchDefaults.string(forKey: "TokenroomSnapshotNews").map {
                NewsCache.load(from: URL(fileURLWithPath: $0).deletingLastPathComponent())
            }
            #else
            let fixture: NewsCache? = nil
            #endif
            // Fixtures are inputs only. A refresh/navigation must not rewrite them.
            return NewsStore(defaults: inertDefaults ?? isolatedDefaults, directory: nil,
                             initialCache: fixture, fetch: { .init(cache: $0.cache, newModels: []) }, notify: { _, _, _ in })
        }
        return NewsStore()
    }
    static var libraryDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Tokenroom/News")
    }
    static func library() -> NewsLibrary {
        NewsLibrary(directory: isInert() ? nil : libraryDirectory)
    }
    static func skillsStore() -> SkillsStore {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "TokenroomSnapshotNews") {
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
            let bodies = Dictionary(uniqueKeysWithValues: SkillSort.allCases.compactMap { sort -> (String, Data)? in
                let name = sort == .trending ? "skills.json" : "skills-\(sort.rawValue).json"
                return (try? Data(contentsOf: folder.appendingPathComponent(name))).map { (sort.apiValue, $0) }
            })
            return SkillsStore(fetch: { request in
                guard let url = request.url,
                      let sort = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "sort" })?.value else { return .unreachable }
                return bodies[sort].map { .body($0) } ?? .unreachable
            })
        }
        #endif
        if isInert() { return SkillsStore(fetch: { _ in .unreachable }) }
        return SkillsStore()
    }
}
