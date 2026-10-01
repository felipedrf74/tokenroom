import Foundation
import XCTest
@testable import Tokenroom

final class PhoneConnectTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Providers whose only login is on a Mac, plus Copilot, whose phone path is a token.
    let neverSignIn: [Provider] = [.claude, .openai, .grok, .grokBot, .cursor, .antigravity, .devin, .copilot]

    private func reading(_ provider: Provider, checkedAt: Date, used: Double = 40) -> RelayProvider {
        let window = QuotaWindow(id: "weekly", kind: .weekly, title: "Weekly", usedPercent: used, resetsAt: checkedAt.addingTimeInterval(3 * 86_400))
        let snapshot = try! QuotaSnapshot.headlined(by: [window], provider: provider, fetchedAt: checkedAt)
        return RelayProvider(provider: provider, status: .live(snapshot), checkedAt: checkedAt)
    }

    private func source(_ kind: CollectorKind, _ providers: [Provider], checkedAt: Date) -> PhoneConnect.CoveringSource {
        PhoneConnect.CoveringSource(
            kind: kind,
            envelope: RelayEnvelope(producer: kind == .mac ? "mac" : "iphone", appVersion: "1", checkedAt: checkedAt,
                                    providers: providers.map { reading($0, checkedAt: checkedAt) })
        )
    }

    // MARK: Allowlist

    func testTheDefaultDecisionNeverSignsIn() {
        XCTAssertTrue(PhoneConnect.productionAllowlist.isEmpty)
        let liveMac = source(.mac, Provider.allCases, checkedAt: now.addingTimeInterval(-600))
        let staleMac = source(.mac, Provider.allCases, checkedAt: now.addingTimeInterval(-(ReadingFreshness.staleAfter + 60)))
        for provider in neverSignIn {
            for sources in [[], [liveMac], [staleMac]] {
                XCTAssertNotEqual(PhoneConnect.action(for: provider, sources: sources, now: now), .signIn, provider.rawValue)
            }
        }
        for provider in Provider.allCases {
            XCTAssertNotEqual(PhoneConnect.action(for: provider, sources: [], now: now), .signIn, provider.rawValue)
        }
    }

    func testAnAllowlistATestPassesSignsInOnlyThatProvider() {
        XCTAssertEqual(PhoneConnect.action(for: .cursor, sources: [], now: now, allowlist: [.cursor]), .signIn)
        XCTAssertEqual(PhoneConnect.action(for: .claude, sources: [], now: now, allowlist: [.cursor]), .needsMac(reason: PhoneConnect.reason(for: .claude)))
        // A key provider stays a key even on the allowlist.
        XCTAssertEqual(PhoneConnect.action(for: .copilot, sources: [], now: now, allowlist: [.copilot]), .addKey)
    }

    // MARK: Coverage

    func testALiveMacReadingKeepsAPastedKeyForThatProvider() {
        let mac = source(.mac, [.copilot, .openrouter], checkedAt: now.addingTimeInterval(-600))
        XCTAssertEqual(PhoneConnect.action(for: .copilot, sources: [mac], now: now), .addKey)
        XCTAssertEqual(PhoneConnect.action(for: .openrouter, sources: [mac], now: now), .addKey)
    }

    func testALiveMacClaudeReadingIsFromTheMacUntilItGoesStale() {
        let checked = now.addingTimeInterval(-600)
        let mac = source(.mac, [.claude], checkedAt: checked)
        XCTAssertEqual(PhoneConnect.action(for: .claude, sources: [mac], now: now), .fromMac)
        let later = checked.addingTimeInterval(ReadingFreshness.staleAfter + 1)
        XCTAssertEqual(PhoneConnect.action(for: .claude, sources: [mac], now: later), .needsMac(reason: PhoneConnect.reason(for: .claude)))
        let gone = checked.addingTimeInterval(RelayMerge.maxSourceAge + 1)
        XCTAssertEqual(PhoneConnect.action(for: .claude, sources: [mac], now: gone), .needsMac(reason: PhoneConnect.reason(for: .claude)))
    }

    func testAnotherIPhoneIsNotAMac() {
        let phone = source(.otherPhone, [.claude], checkedAt: now.addingTimeInterval(-60))
        XCTAssertEqual(PhoneConnect.action(for: .claude, sources: [phone], now: now), .needsMac(reason: PhoneConnect.reason(for: .claude)))
    }

    func testASignedOutMacCardDoesNotCover() {
        var signedOut = RelayProvider(provider: .cursor, status: .signedOut("Sign in to Cursor to see usage."), checkedAt: now.addingTimeInterval(-60))
        signedOut.checkedAt = now.addingTimeInterval(-60)
        let mac = PhoneConnect.CoveringSource(kind: .mac, envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now, providers: [signedOut]))
        XCTAssertEqual(PhoneConnect.action(for: .cursor, sources: [mac], now: now), .needsMac(reason: PhoneConnect.reason(for: .cursor)))
    }

    func testACachedMacReadingStillCoversBeforeICloudAnswers() {
        let item = ReadingCache.Item(provider: reading(.claude, checkedAt: now.addingTimeInterval(-600)), source: "Studio", origin: .mac)
        let cache = ReadingCache(savedAt: now, isSample: false, items: [item])
        let carried = cache.carriedSources(excluding: "This iPhone").map(\.source)
        XCTAssertEqual(carried.first?.envelope.producer, "cache")
        XCTAssertEqual(PhoneConnect.action(for: .claude, sources: carried.covering, now: now), .fromMac)
    }

    func testAnOldCacheLabelledIPhoneDoesNotCover() {
        let item = ReadingCache.Item(provider: reading(.claude, checkedAt: now.addingTimeInterval(-600)), source: "iPhone")
        let cache = ReadingCache(savedAt: now, isSample: false, items: [item])
        let carried = cache.carriedSources(excluding: "This iPhone").map(\.source)
        XCTAssertEqual(carried.first?.kind, .otherPhone)
        XCTAssertEqual(PhoneConnect.action(for: .claude, sources: carried.covering, now: now), .needsMac(reason: PhoneConnect.reason(for: .claude)))
        // An old cache's Mac label still reads as a Mac.
        let mac = ReadingCache(savedAt: now, isSample: false, items: [ReadingCache.Item(provider: item.provider, source: "Mac")])
        XCTAssertEqual(PhoneConnect.action(for: .claude, sources: mac.carriedSources(excluding: "This iPhone").map(\.source).covering, now: now), .fromMac)
    }

    // MARK: The connect screen

    func testTheConnectListHasNoKeyProviders() {
        let list = PhoneConnect.connectList(sources: [], now: now)
        let listed = Set(list.map(\.provider))
        XCTAssertEqual(listed, [.grok, .grokBot, .claude, .openai, .cursor, .antigravity, .devin])
        XCTAssertTrue(listed.allSatisfy { !$0.readsWithKey })
        for entry in list {
            guard case .needsMac(let reason) = entry.action else { return XCTFail("\(entry.provider)") }
            XCTAssertTrue(reason.hasPrefix("Needs Tokenroom on a Mac."), reason)
            XCTAssertFalse(reason.localizedCaseInsensitiveContains("sign in"), reason)
        }
        let covered = PhoneConnect.connectList(sources: [source(.mac, [.claude], checkedAt: now)], now: now)
        XCTAssertEqual(covered.first { $0.provider == .claude }?.action, .fromMac)
    }

    func testTheFooterNeverPromisesASignIn() {
        let needsMac = PhoneConnect.Action.needsMac(reason: "x")
        XCTAssertEqual(PhoneConnect.disconnectedFooter([needsMac]), "These need Tokenroom on a Mac.")
        XCTAssertEqual(PhoneConnect.disconnectedFooter([.fromMac]), "These need Tokenroom on a Mac.")
        XCTAssertEqual(PhoneConnect.disconnectedFooter([.addKey]), "Check these keys in Settings › API Keys.")
        XCTAssertEqual(PhoneConnect.disconnectedFooter([needsMac, .addKey]), "These need Tokenroom on a Mac, or a key in Settings › API Keys.")
    }

    func testTheOriginPhrases() {
        XCTAssertEqual(CollectorKind.thisPhone.phrase, "On this iPhone")
        XCTAssertEqual(CollectorKind.otherPhone.phrase, "From your other iPhone")
        XCTAssertEqual(CollectorKind.mac.phrase, "From your Mac")
        XCTAssertEqual(CollectorKind(recordKind: "iphone"), .otherPhone)
        XCTAssertEqual(CollectorKind(recordKind: "mac"), .mac)
    }

    func testTheMergeKeepsEachReadingsOrigin() throws {
        let mac = RelayMerge.Source(id: "mac", label: "Studio", envelope: RelayEnvelope(producer: "mac", appVersion: "1", checkedAt: now, providers: [reading(.claude, checkedAt: now)]), kind: .mac)
        let phone = RelayMerge.Source(id: "me", label: "This iPhone", envelope: RelayEnvelope(producer: "iphone", appVersion: "1", checkedAt: now, providers: [reading(.openrouter, checkedAt: now)]), kind: .thisPhone)
        let output = ReadingAssembler.assemble(sources: [mac, phone], histories: [:], now: now)
        let origins = Dictionary(uniqueKeysWithValues: output.connected.map { ($0.id, $0.origin) })
        XCTAssertEqual(origins["claude"], .mac)
        XCTAssertEqual(origins["openrouter"], .thisPhone)

        let cache = ReadingCache(savedAt: now, isSample: false, items: output.connected)
        let decoded = try RelayEnvelope.decoder.decode(ReadingCache.self, from: RelayEnvelope.encoder.encode(cache))
        XCTAssertEqual(decoded.items.map(\.origin), output.connected.map(\.origin))
        // A cache from before origins were kept still reads.
        let old = try RelayEnvelope.decoder.decode(ReadingCache.self, from: Data(String(decoding: RelayEnvelope.encoder.encode(cache), as: UTF8.self)
            .replacingOccurrences(of: #","origin":"mac""#, with: "").replacingOccurrences(of: #","origin":"thisPhone""#, with: "").utf8))
        XCTAssertEqual(old.items.map(\.origin), [nil, nil])
        XCTAssertEqual(Set(old.items.map(\.resolvedOrigin)), [.mac, .thisPhone])
    }

    // MARK: Flag

    func testTheConnectScreenIsOffByDefault() throws {
        let name = "app.tokenroom.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(PhoneConnect.isEnabled(in: defaults))
        defaults.set(true, forKey: PhoneConnect.flagKey)
        XCTAssertTrue(PhoneConnect.isEnabled(in: defaults))
    }

    // MARK: Deep links

    func testTheConnectLinkParsesAndTheOthersStillDo() {
        for host in ["news", "settings", "keys", "alerts", "connect"] {
            XCTAssertNotNil(DeepLink(URL(string: "tokenroom://\(host)")!), host)
        }
        XCTAssertEqual(DeepLink(URL(string: "tokenroom://connect")!), .connect)
        XCTAssertEqual(DeepLink.connect.url.absoluteString, "tokenroom://connect")
        XCTAssertEqual(DeepLink(URL(string: "tokenroom://provider/claude")!), .provider("claude"))
        XCTAssertNil(DeepLink(URL(string: "tokenroom://oauth/claude?code=abc")!), "Reserved for a future sign-in")
        XCTAssertNil(DeepLink(URL(string: "tokenroom://unknown")!))
    }
}
