import Foundation
#if os(macOS)
import Security
#endif

enum RelayAvailability {
    static let containerIdentifier: String? = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-container-identifiers" as CFString,
                nil
              ),
              let containers = value as? [String]
        else { return nil }
        return containers.first
        #else
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "TokenroomCloudContainer") as? String,
              !identifier.isEmpty, !identifier.hasPrefix("$(")
        else { return nil }
        return identifier
        #endif
    }()

    static var isAvailable: Bool {
        containerIdentifier != nil
    }
}

enum BuildSigning {
    static let developmentNotice = "Development build. Its iCloud is separate from the App Store's, so it only shows Macs running a development build too."

    static func isDevelopmentProfile(_ profile: Data) -> Bool {
        guard let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: profile[start.lowerBound..<end.upperBound], format: nil),
              let entitlements = (plist as? [String: Any])?["Entitlements"] as? [String: Any]
        else { return false }
        return entitlements["get-task-allow"] as? Bool == true
    }

    #if !os(macOS)
    static let usesDevelopmentCloud: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let profile = try? Data(contentsOf: url)
        else { return false }
        return isDevelopmentProfile(profile)
    }()
    #endif
}
