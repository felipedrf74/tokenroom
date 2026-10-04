import Foundation

/// Shared by the iPhone app, widgets, and Watch handoff. Old cache files stay quarantined after
/// an account change even if clearing the file fails or an old widget writes its result late.
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
        // A late writer can leave a file, but that file's old generation is never accepted.
        return generation == self.generation(in: defaults)
    }
}
