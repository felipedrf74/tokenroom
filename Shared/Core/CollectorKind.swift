import Foundation

/// Which device a reading came from, as this device sees it. Kept with cached readings (the
/// Watch reads them too), so it lives beside them rather than with the iPhone's keys.
enum CollectorKind: String, Codable, Sendable, CaseIterable {
    case mac
    case thisPhone
    case otherPhone

    /// From a CloudKit `Source` record's `kind`: anything but `iphone` is a Mac, which is also
    /// what `CloudRelay` reads a record without the field as.
    init(recordKind: String) {
        self = recordKind == "iphone" ? .otherPhone : .mac
    }

    /// For a cached reading saved before readings carried their origin: the iPhone publishes
    /// under the label "iPhone", and this iPhone's own readings are "This iPhone". Anything else
    /// is a Mac's label (renamable in its Settings).
    init(legacyLabel label: String, localLabel: String = "This iPhone") {
        switch label {
        case localLabel: self = .thisPhone
        case "iPhone": self = .otherPhone
        default: self = .mac
        }
    }

    /// The origin line on a reading, on this iPhone.
    var phrase: String {
        switch self {
        case .thisPhone: "On this iPhone"
        case .otherPhone: "From your other iPhone"
        case .mac: "From your Mac"
        }
    }

    /// The same origin seen from the Apple Watch, which never collects: this iPhone's readings
    /// are "your iPhone" there, and it can't tell which of several iPhones handed one over.
    var watchPhrase: String {
        switch self {
        case .thisPhone, .otherPhone: "From your iPhone"
        case .mac: "From your Mac"
        }
    }
}
