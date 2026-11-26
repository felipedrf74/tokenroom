import Foundation

enum CollectorKind: String, Codable, Sendable, CaseIterable {
    case mac
    case thisPhone
    case otherPhone

    init(recordKind: String) {
        self = recordKind == "iphone" ? .otherPhone : .mac
    }

    init(legacyLabel label: String, localLabel: String = "This iPhone") {
        switch label {
        case localLabel: self = .thisPhone
        case "iPhone": self = .otherPhone
        default: self = .mac
        }
    }

    var phrase: String {
        switch self {
        case .thisPhone: "On this iPhone"
        case .otherPhone: "From your other iPhone"
        case .mac: "From your Mac"
        }
    }

    var watchPhrase: String {
        switch self {
        case .thisPhone, .otherPhone: "From your iPhone"
        case .mac: "From your Mac"
        }
    }
}
