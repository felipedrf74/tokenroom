import Foundation

/// Which providers this iPhone's widgets show, and in what order: the user's choice, kept in the
/// App Group's defaults for the app and its widgets. Provider IDs only, and never sent anywhere.
struct WidgetArrangement: Codable, Equatable, Sendable {
    enum Order: String, Codable, Sendable, CaseIterable {
        /// Most urgent first, as the readings are ranked.
        case urgency
        /// The order the user gave them.
        case manual
    }

    static let defaultsKey = "widgetArrangement"

    var order: Order = .urgency
    /// Provider IDs in the user's order. A provider that isn't listed (one connected since)
    /// follows the listed ones, as ranked.
    var sequence: [String] = []
    /// Providers left out of widgets.
    var hidden: Set<String> = []

    init(order: Order = .urgency, sequence: [String] = [], hidden: Set<String> = []) {
        self.order = order
        self.sequence = sequence
        self.hidden = hidden
    }

    private enum CodingKeys: String, CodingKey {
        case order, sequence, hidden
    }

    /// Lenient: a field a newer Tokenroom wrote differently falls back to its default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        order = (try? container.decode(Order.self, forKey: .order)) ?? .urgency
        sequence = (try? container.decode([String].self, forKey: .sequence)) ?? []
        hidden = Set((try? container.decode([String].self, forKey: .hidden)) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(order, forKey: .order)
        try container.encode(sequence, forKey: .sequence)
        try container.encode(hidden.sorted(), forKey: .hidden)
    }

    /// The saved choice, or the default (everything, most urgent first) when there is none or it
    /// can't be read.
    static func load(from defaults: UserDefaults) -> WidgetArrangement {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(WidgetArrangement.self, from: data)
        else { return WidgetArrangement() }
        return saved
    }

    func save(to defaults: UserDefaults) {
        guard self != WidgetArrangement() else {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    func isShown(_ id: String) -> Bool {
        !hidden.contains(id)
    }

    /// `ranked` (most urgent first) without the hidden providers, in the chosen order.
    func arranged<Item>(_ ranked: [Item], id: (Item) -> String) -> [Item] {
        let shown = ranked.filter { isShown(id($0)) }
        guard order == .manual else { return shown }
        return Self.inSequence(shown, sequence: sequence, id: id)
    }

    /// Every provider, hidden ones included, in the user's order: what the settings list shows.
    func listed<Item>(_ ranked: [Item], id: (Item) -> String) -> [Item] {
        Self.inSequence(ranked, sequence: sequence, id: id)
    }

    /// The listed providers first, in `sequence`; the rest after them, as they came.
    private static func inSequence<Item>(_ items: [Item], sequence: [String], id: (Item) -> String) -> [Item] {
        var position: [String: Int] = [:]
        for (index, provider) in sequence.enumerated() where position[provider] == nil {
            position[provider] = index
        }
        return items.enumerated().sorted { lhs, rhs in
            switch (position[id(lhs.element)], position[id(rhs.element)]) {
            case let (left?, right?): left < right
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// The arrangement after the user moved rows in a list showing `listed` (IDs as shown).
    /// Providers that aren't on screen now (no reading at the moment) keep their place after
    /// the ones that are, so they come back where they were left.
    func moving(_ listed: [String], from source: IndexSet, to destination: Int) -> WidgetArrangement {
        var visible = listed
        let moved = source.sorted().map { visible[$0] }
        let before = source.filter { $0 < destination }.count
        for index in source.sorted().reversed() { visible.remove(at: index) }
        visible.insert(contentsOf: moved, at: min(max(destination - before, 0), visible.count))
        var result = self
        result.sequence = visible + sequence.filter { !visible.contains($0) }
        result.order = .manual
        return result
    }

    func setting(_ id: String, shown: Bool) -> WidgetArrangement {
        var result = self
        if shown { result.hidden.remove(id) } else { result.hidden.insert(id) }
        return result
    }
}
