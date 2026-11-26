import Foundation

enum WidgetReloadLog {
    static let defaultsKey = "widgetReloads"
    static let keep: TimeInterval = 48 * 3600

    @discardableResult
    static func record(_ widget: String = "usage", at date: Date = .now, defaults: UserDefaults = AppGroup.defaults) -> Int {
        let now = date.timeIntervalSince1970
        var log = entries(defaults)
        log[widget, default: []].append(now)
        log = log.compactMapValues { times in
            let kept = times.filter { now - $0 < keep }.suffix(500)
            return kept.isEmpty ? nil : Array(kept)
        }
        defaults.set(log, forKey: defaultsKey)
        return lastDay(log[widget] ?? [], before: date)
    }

    static func count(lastDayBefore now: Date = .now, defaults: UserDefaults = AppGroup.defaults) -> Int {
        entries(defaults).values.map { lastDay($0, before: now) }.max() ?? 0
    }

    private static func entries(_ defaults: UserDefaults) -> [String: [Double]] {
        defaults.dictionary(forKey: defaultsKey) as? [String: [Double]] ?? [:]
    }

    private static func lastDay(_ times: [Double], before now: Date) -> Int {
        times.filter { now.timeIntervalSince1970 - $0 < 86_400 }.count
    }
}
