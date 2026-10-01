import XCTest
@testable import Tokenroom

final class ParserTests: XCTestCase {
    func testGrokCreditsPercentAndOnDemand() throws {
        let snapshot = try GrokParser.snapshot(from: fixture("grok-credits"))
        XCTAssertEqual(snapshot.usedPercent, 42.5, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "Weekly")
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[1].title, "Extra")
        XCTAssertEqual(snapshot.windows[1].usedPercent, 5, accuracy: 0.01)
        XCTAssertNotNil(snapshot.resetsAt)
    }

    func testGrokMissingPercentIsZeroOnWeeklyPeriod() throws {
        let snapshot = try GrokParser.snapshot(from: fixture("grok-credits-zero"))
        XCTAssertEqual(snapshot.usedPercent, 0, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "Weekly")
        XCTAssertEqual(snapshot.windows.count, 1)
    }

    func testClaudeWeeklyAndSession() throws {
        let snapshot = try ClaudeParser.snapshot(from: fixture("claude-usage"))
        XCTAssertEqual(snapshot.usedPercent, 71, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[1].kind, .session)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 18, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "Weekly")
    }

    func testOpenAIPrimaryWeeklyWhenSecondaryMissing() throws {
        let snapshot = try OpenAIParser.snapshot(from: fixture("openai-weekly-primary"))
        XCTAssertEqual(snapshot.usedPercent, 91, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "Weekly")
        XCTAssertEqual(snapshot.windows.count, 1)
    }

    func testOpenAISecondaryIsWeeklyAndPrimaryIsSession() throws {
        let snapshot = try OpenAIParser.snapshot(from: fixture("openai-secondary-weekly"))
        XCTAssertEqual(snapshot.usedPercent, 18, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows.count, 2)
        XCTAssertEqual(snapshot.windows[0].title, "Weekly")
        XCTAssertEqual(snapshot.windows[1].kind, .session)
        XCTAssertEqual(snapshot.windows[1].usedPercent, 40, accuracy: 0.01)
    }

    func testCursorUsesMaxPoolAndLabelsCycle() throws {
        let snapshot = try CursorParser.snapshot(from: fixture("cursor-usage"))
        XCTAssertEqual(snapshot.usedPercent, 55, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "This cycle")
        XCTAssertEqual(snapshot.windows.map(\.title), ["This cycle", "Cursor Models", "Other Models"])
        XCTAssertNotNil(snapshot.resetsAt)
    }

    func testGrokBotWeeklyPercent() throws {
        let snapshot = try GrokBotParser.snapshot(from: fixture("grok-bot-usage"))
        XCTAssertEqual(snapshot.usedPercent, 8.708505, accuracy: 0.01)
        XCTAssertEqual(snapshot.primaryTitle, "Weekly")
        XCTAssertEqual(snapshot.provider, .grokBot)
        XCTAssertNotNil(snapshot.resetsAt)
        XCTAssertEqual(snapshot.planLabel, "SuperGrok Heavy")
        XCTAssertEqual(snapshot.windows.map(\.id), ["weekly"])
    }

    func testGrokBotOffPlanIsNotEntitled() {
        let data = Data(#"{"hasNonZeroIncludedLimit": false, "usagePercent": 0}"#.utf8)
        XCTAssertThrowsError(try GrokBotParser.snapshot(from: data)) { error in
            XCTAssertEqual(error as? ProviderError, .notEntitled("Grok Bot isn't on this Cursor plan."))
        }
    }

    func testMeterFillLengthClipsAndDropsEmpty() {
        XCTAssertEqual(MeterLayout.fillLength(usedPercent: 0, total: 200), 0)
        XCTAssertEqual(MeterLayout.fillLength(usedPercent: 50, total: 200), 100)
        XCTAssertEqual(MeterLayout.fillLength(usedPercent: 100, total: 200), 200)
        XCTAssertEqual(MeterLayout.fillLength(usedPercent: -10, total: 200), 0)
        XCTAssertEqual(MeterLayout.fillLength(usedPercent: 140, total: 200), 200)
        XCTAssertEqual(MeterLayout.usedFraction(25), 0.25, accuracy: 0.0001)
    }

    /// The drawn fill ends where the fraction does: a sliver isn't drawn as a dot several times
    /// its size. The rounded end comes from the track's own cap.
    func testTheDrawnFillEndsAtTheFraction() {
        for height: CGFloat in [5, 6, 8, 10] {
            XCTAssertEqual(MeterLayout.drawnFillEnd(usedPercent: 0, total: 200, height: height), 0)
            XCTAssertEqual(MeterLayout.drawnFillEnd(usedPercent: 0.5, total: 200, height: height), 1, accuracy: 0.001)
            XCTAssertEqual(MeterLayout.drawnFillEnd(usedPercent: 2, total: 200, height: height), 4, accuracy: 0.001)
            XCTAssertEqual(MeterLayout.drawnFillEnd(usedPercent: 99.5, total: 200, height: height), 199, accuracy: 0.001)
            XCTAssertEqual(MeterLayout.drawnFillEnd(usedPercent: 100, total: 200, height: height), 200)
            XCTAssertEqual(MeterLayout.drawnFillEnd(usedPercent: 140, total: 200, height: height), 200)
        }
    }

    func testCursorTokenFromTempDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try makeCursorDatabase(in: folder, token: "tok-test-cursor")

        let previous = ProcessInfo.processInfo.environment["TOKENROOM_CURSOR_DB"]
        defer {
            if let previous {
                setenv("TOKENROOM_CURSOR_DB", previous, 1)
            } else {
                unsetenv("TOKENROOM_CURSOR_DB")
            }
            CredentialReaders.invalidateCaches()
        }
        setenv("TOKENROOM_CURSOR_DB", db.path, 1)
        CredentialReaders.invalidateCaches()
        // The Keychain comes first now; leave this Mac's real Cursor login out of it.
        XCTAssertEqual(try CredentialReaders.cursorAccessToken(keychain: { _ in nil }, usesCache: false), "tok-test-cursor", "TOKENROOM_CURSOR_DB points at the database")
        XCTAssertNotNil(CredentialReaders.sessionStamp(.cursor))
        XCTAssertNotNil(CredentialReaders.sessionStamp(.grokBot))
    }

    /// Cursor 3.9 and later keep the token in the Keychain; `state.vscdb` may still hold an older
    /// one that no longer works, so it's only the fallback.
    func testCursorKeychainTokenWinsOverTheDatabase() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try makeCursorDatabase(in: folder, token: "tok-test-database")

        var asked: [String] = []
        let token = try CredentialReaders.cursorAccessToken(keychain: { service in
            asked.append(service)
            return "tok-test-keychain"
        }, database: db, usesCache: false)
        XCTAssertEqual(token, "tok-test-keychain")
        XCTAssertEqual(asked, [CredentialReaders.cursorKeychainService])

        XCTAssertEqual(try CredentialReaders.cursorAccessToken(keychain: { _ in nil }, database: db, usesCache: false), "tok-test-database")
        XCTAssertEqual(try CredentialReaders.cursorAccessToken(keychain: { _ in "" }, database: db, usesCache: false), "tok-test-database", "An empty Keychain item doesn't count")
        XCTAssertThrowsError(try CredentialReaders.cursorAccessToken(keychain: { _ in nil }, database: folder.appendingPathComponent("missing.vscdb"), usesCache: false)) { error in
            XCTAssertEqual(error as? ProviderError, .signedOut(Provider.cursor.signInHint))
        }
    }

    private func makeCursorDatabase(in folder: URL, token: String) throws -> URL {
        let db = folder.appendingPathComponent("state.vscdb")
        let sqlite = Process()
        sqlite.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        sqlite.arguments = [
            db.path,
            "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)');",
        ]
        try sqlite.run()
        sqlite.waitUntilExit()
        XCTAssertEqual(sqlite.terminationStatus, 0)
        return db
    }

    func testMenuBarCollapse() {
        let four = [
            MenuMeter(provider: .grok, valueText: "42", remaining: 58, usedPercent: 42, isStale: false, isPlaceholder: false),
            MenuMeter(provider: .claude, valueText: "71", remaining: 29, usedPercent: 71, isStale: false, isPlaceholder: false),
            MenuMeter(provider: .openai, valueText: "18", remaining: 82, usedPercent: 18, isStale: false, isPlaceholder: false),
            MenuMeter(provider: .cursor, valueText: "55", remaining: 45, usedPercent: 55, isStale: false, isPlaceholder: false),
        ]
        XCTAssertEqual(MenuBarLayout.density(for: four), .compact)
        let five = four + [
            MenuMeter(provider: .grokBot, valueText: "9", remaining: 91, usedPercent: 9, isStale: false, isPlaceholder: false),
        ]
        XCTAssertEqual(MenuBarLayout.density(for: five), .compact)
        XCTAssertEqual(
            MenuBarLayout.tooltip(for: four),
            "Grok Build 42%\nClaude 71%\nOpenAI 18%\nCursor 55%"
        )
        XCTAssertEqual(MenuBarLayout.compactText(for: four), "Build 42%  Claude 71%  GPT 18%  Cursor 55%")
    }

    func testClaudeTokenJSON() throws {
        let json = """
        {"mcpOAuth":{},"claudeAiOauth":{"accessToken":"tok-123","refreshToken":"r","expiresAt":1}}
        """
        XCTAssertEqual(try CredentialReaders.parseClaudeToken(json), "tok-123")
    }

    func testClaudePartitionListReadsTheHexPlist() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Partitions</key><array><string>teamid:EXAMPLE</string><string>apple-tool:</string></array></dict></plist>
        """
        let hex = xml.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(
            CredentialReaders.partitions(inACLDescription: hex),
            ["teamid:EXAMPLE", "apple-tool:"]
        )
        XCTAssertEqual(CredentialReaders.partitions(inACLDescription: "not a plist"), [])
        XCTAssertTrue(CredentialReaders.isSecurityToolPartition("apple-tool:"))
        XCTAssertFalse(CredentialReaders.isSecurityToolPartition("teamid:EXAMPLE"))
        XCTAssertTrue(CredentialReaders.ClaudeKeyAccess(partitions: ["apple-tool:"], hasPartitionList: true).trustsSecurityTool)
        XCTAssertTrue(CredentialReaders.ClaudeKeyAccess(trustedPaths: ["/usr/bin/security"]).trustsSecurityTool)
        XCTAssertFalse(CredentialReaders.ClaudeKeyAccess(partitions: ["teamid:EXAMPLE"], hasPartitionList: true).trustsSecurityTool)
        XCTAssertFalse(
            CredentialReaders.ClaudeKeyAccess(
                partitions: ["teamid:EXAMPLE"],
                hasPartitionList: true,
                trustedPaths: ["/usr/bin/security"]
            ).trustsSecurityTool
        )
        var padded = Data("/usr/bin/security".utf8)
        padded.append(contentsOf: [0, 0])
        XCTAssertEqual(CredentialReaders.trustedApplicationPath(from: padded), "/usr/bin/security")
    }

    func testClaudeReadDoesNotUseSecItemForTheSecret() {
        var silentCalls = 0
        var securityCalls = 0
        let secret = CredentialReaders.readClaudeSecret(
            service: "Claude Code-credentials",
            account: "tester",
            access: { _ in
                CredentialReaders.ClaudeKeyAccess(
                    partitions: ["apple-tool:"],
                    hasPartitionList: true,
                    trustsThisApp: true
                )
            },
            silent: { _, _ in
                silentCalls += 1
                return " {\"ok\":true} "
            },
            security: { _, _ in
                securityCalls += 1
                return .value(" {\"ok\":true} ")
            }
        )
        XCTAssertEqual(secret, "{\"ok\":true}")
        XCTAssertEqual(silentCalls, 0)
        XCTAssertEqual(securityCalls, 1)
        XCTAssertTrue(CredentialReaders.claudeLoginCanBeRenewedInPlace())
    }

    func testClaudeUpdateKeepsTheAccessListAndStaysOffTheArgumentsWhenItFits() {
        let update = CredentialReaders.claudeSecurityUpdate(service: "Claude Code-credentials", account: "tester", json: "{\"ok\":true}")
        XCTAssertEqual(update.arguments, ["-i"])
        let line = String(data: update.stdin ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(line.hasPrefix("add-generic-password -U "))
        XCTAssertTrue(line.contains("-s \"Claude Code-credentials\""))
        XCTAssertTrue(line.contains("-X 7b226f6b223a747275657d"))
        XCTAssertFalse(line.contains("-T"))
        XCTAssertFalse(update.arguments.contains("-T"))
        XCTAssertFalse(update.arguments.contains("-X"))
    }

    func testClaudeUpdateUsesArgumentsOnlyWhenTheLineWouldBeTruncated() {
        let json = String(repeating: "a", count: 3000)
        let update = CredentialReaders.claudeSecurityUpdate(service: "svc", account: "tester", json: json)
        XCTAssertNil(update.stdin)
        XCTAssertEqual(update.arguments.prefix(6), ["add-generic-password", "-U", "-a", "tester", "-s", "svc"])
        XCTAssertEqual(update.arguments[6], "-X")
        XCTAssertEqual(update.arguments[7], Data(json.utf8).map { String(format: "%02x", $0) }.joined())
        XCTAssertFalse(update.arguments.contains("-T"))
    }

    func testClaudeWriteRoundTripsWithoutReplacingTrustedApps() throws {
        let keychain = FileManager.default.temporaryDirectory.appendingPathComponent("tokenroom-claude-write-\(UUID().uuidString).keychain-db")
        let password = UUID().uuidString
        defer {
            _ = BlockingIO.runProcess(URL(fileURLWithPath: "/usr/bin/security"), arguments: ["delete-keychain", keychain.path])
        }
        let created = BlockingIO.runProcess(
            URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["create-keychain", "-p", password, keychain.path]
        )
        XCTAssertTrue(created.succeeded)
        XCTAssertTrue(BlockingIO.runProcess(
            URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["unlock-keychain", "-p", password, keychain.path]
        ).succeeded)
        XCTAssertTrue(BlockingIO.runProcess(
            URL(fileURLWithPath: "/usr/bin/security"),
            arguments: ["set-keychain-settings", keychain.path]
        ).succeeded)
        XCTAssertTrue(BlockingIO.runProcess(
            URL(fileURLWithPath: "/usr/bin/security"),
            arguments: [
                "add-generic-password", "-a", "tester", "-s", "svc", "-w", "first",
                "-T", "/usr/bin/security", "-T", "/bin/ls", keychain.path,
            ]
        ).succeeded)
        let json = #"{"note":"keep","n":"\#(String(repeating: "a", count: 3000))"}"#
        XCTAssertTrue(CredentialReaders.writeClaudeCredential(service: "svc", account: "tester", json: json, keychain: keychain.path))
        let update = CredentialReaders.claudeSecurityUpdate(service: "svc", account: "tester", json: json, keychain: keychain.path)
        XCTAssertNil(update.stdin, "A Claude-sized login does not go through the 4096-byte stdin line")
    }

    func testClaudeReadDoesNotAskWhenNothingTrustsTheCaller() {
        var silentCalls = 0
        var securityCalls = 0
        let secret = CredentialReaders.readClaudeSecret(
            service: "Claude Code-credentials",
            account: "tester",
            access: { _ in CredentialReaders.ClaudeKeyAccess(hasPartitionList: true) },
            silent: { _, _ in
                silentCalls += 1
                return "secret"
            },
            security: { _, _ in
                securityCalls += 1
                return .value("secret")
            }
        )
        XCTAssertNil(secret)
        XCTAssertEqual(silentCalls, 0)
        XCTAssertEqual(securityCalls, 0)
    }

    func testClaudeReadCallsSecurityOnceWhenOnlyThatToolIsTrusted() {
        var silentCalls = 0
        var accounts: [String?] = []
        let secret = CredentialReaders.readClaudeSecret(
            service: "Claude Code-credentials",
            account: "tester",
            access: { _ in CredentialReaders.ClaudeKeyAccess(partitions: ["apple-tool:"], hasPartitionList: true) },
            silent: { _, _ in
                silentCalls += 1
                return "should-not-read"
            },
            security: { _, account in
                accounts.append(account)
                return .unavailable
            }
        )
        XCTAssertNil(secret)
        XCTAssertEqual(silentCalls, 0)
        XCTAssertEqual(accounts, ["tester"])
    }

    func testClaudeReadRetriesSecurityOnlyWhenTheAccountIsMissing() {
        var accounts: [String?] = []
        let secret = CredentialReaders.readClaudeSecret(
            service: "Claude Code-credentials",
            account: "tester",
            access: { _ in CredentialReaders.ClaudeKeyAccess(trustedPaths: ["/usr/bin/security"]) },
            silent: { _, _ in "no" },
            security: { _, account in
                accounts.append(account)
                return account == nil ? .value("token") : .missing
            }
        )
        XCTAssertEqual(secret, "token")
        XCTAssertEqual(accounts, ["tester", nil])
    }

    func testClaudeRefreshTokenExpiry() throws {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let live = """
        {"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":\(nowMs + 3_600_000),"refreshTokenExpiresAt":\(nowMs + 7_200_000)}}
        """
        let liveAuth = try CredentialReaders.parseClaudeAuth(live, account: "test", service: "svc")
        XCTAssertFalse(liveAuth.isExpired)
        XCTAssertTrue(liveAuth.canRefresh)

        let deadRefresh = """
        {"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1,"refreshTokenExpiresAt":1}}
        """
        let deadAuth = try CredentialReaders.parseClaudeAuth(deadRefresh, account: "test", service: "svc")
        XCTAssertTrue(deadAuth.isExpired)
        XCTAssertFalse(deadAuth.canRefresh)
    }

    func testPercentTextKeepsTenthWhenItMatters() {
        XCTAssertEqual(TokenroomFormat.percentText(42), "42")
        XCTAssertEqual(TokenroomFormat.percentText(42.04), "42")
        XCTAssertEqual(TokenroomFormat.percentText(13.649571), "14")
        XCTAssertEqual(TokenroomFormat.percentText(8.708505), "9")
        XCTAssertEqual(TokenroomFormat.percentText(55.2), "55")
    }

    func testRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = now.addingTimeInterval(3 * 86_400 + 4 * 3600)
        XCTAssertEqual(RelativeTime.resets(later, now: now), "resets in 3d 4h")
        XCTAssertEqual(RelativeTime.ago(now.addingTimeInterval(-120), now: now), "2m ago")
    }

    private func fixture(_ name: String) -> Data {
        let url = Bundle(for: ParserTests.self).url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle(for: ParserTests.self).url(forResource: name, withExtension: "json")
        if let url, let data = try? Data(contentsOf: url) {
            return data
        }
        let fallback = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try! Data(contentsOf: fallback)
    }
}
