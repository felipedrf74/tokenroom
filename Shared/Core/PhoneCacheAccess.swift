import Foundation

enum PhoneCacheAccess {
    static let generationKey = "phoneCacheAccountGeneration"

    static func generation(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: generationKey)
    }

    static func invalidate(in defaults: UserDefaults) {
        defaults.set(UUID().uuidString, forKey: generationKey)
    }

    static func accepts(_ cache: ReadingCache, defaults: UserDefaults) -> Bool {
        cache.accountGeneration == generation(in: defaults)
    }

    static func load(at url: URL?, defaults: UserDefaults) -> ReadingCache? {
        guard let url, let cache = ReadingCache.load(from: url), accepts(cache, defaults: defaults) else { return nil }
        return cache
    }

    @discardableResult
    static func save(_ cache: ReadingCache, at url: URL?, defaults: UserDefaults, generation: String?) throws -> Bool {
        guard generation == self.generation(in: defaults), let url else { return false }
        var cache = cache
        cache.accountGeneration = generation
        cache.localSource?.accountGeneration = generation
        try cache.save(to: url)
        return generation == self.generation(in: defaults)
    }
}
