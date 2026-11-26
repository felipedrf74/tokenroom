import Foundation

enum AppGroup {
    static var identifier: String? {
        configured("TokenroomAppGroup")
    }

    static var keychainGroup: String? {
        guard let group = configured("TokenroomKeychainGroup"),
              group.split(separator: ".").first?.count == 10
        else { return nil }
        return group
    }

    static var containerURL: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }

    static var defaults: UserDefaults {
        identifier.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private static func configured(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(")
        else { return nil }
        return value
    }
}
