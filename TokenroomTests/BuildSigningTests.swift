import XCTest
@testable import Tokenroom

final class BuildSigningTests: XCTestCase {
    private func profile(entitlements: [String: Any]?) throws -> Data {
        var plist: [String: Any] = ["Name": "Profile", "TeamName": "Team"]
        if let entitlements { plist["Entitlements"] = entitlements }
        let body = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return Data([0x30, 0x82, 0x1f, 0x00, 0xff, 0x00]) + body + Data([0xa0, 0x82, 0x00, 0xff])
    }

    func testDevelopmentProfileIsRecognized() throws {
        let data = try profile(entitlements: ["get-task-allow": true, "aps-environment": "development"])
        XCTAssertTrue(BuildSigning.isDevelopmentProfile(data))
    }

    func testDistributionProfileIsNotDevelopment() throws {
        let data = try profile(entitlements: ["get-task-allow": false, "aps-environment": "production"])
        XCTAssertFalse(BuildSigning.isDevelopmentProfile(data))
    }

    func testProfileWithoutTheEntitlementIsNotDevelopment() throws {
        XCTAssertFalse(BuildSigning.isDevelopmentProfile(try profile(entitlements: ["aps-environment": "development"])))
        XCTAssertFalse(BuildSigning.isDevelopmentProfile(try profile(entitlements: nil)))
    }

    func testUnreadableProfileIsNotDevelopment() {
        XCTAssertFalse(BuildSigning.isDevelopmentProfile(Data()))
        XCTAssertFalse(BuildSigning.isDevelopmentProfile(Data("<?xml version=\"1.0\"?><plist><dict><key>Entitlements".utf8)))
        XCTAssertFalse(BuildSigning.isDevelopmentProfile(Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertFalse(BuildSigning.isDevelopmentProfile(Data("<?xml version=\"1.0\"?><plist><dict><key>Entitlements</plist>".utf8)))
    }

    func testRealProfileShapeWithBinaryAroundThePlist() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>Entitlements</key>
        <dict>
        <key>application-identifier</key>
        <string>TEAMID.app.tokenroom.ios</string>
        <key>get-task-allow</key>
        <true/>
        </dict>
        </dict>
        </plist>
        """
        let data = Data([0x30, 0x80, 0x06, 0x09]) + Data(xml.utf8) + Data([0x00, 0x00, 0x31, 0x82])
        XCTAssertTrue(BuildSigning.isDevelopmentProfile(data))
    }
}
