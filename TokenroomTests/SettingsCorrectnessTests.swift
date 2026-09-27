import XCTest
@testable import Tokenroom

final class SettingsCorrectnessTests: XCTestCase {
    func testKeyOrAccountChangeInvalidatesAnInFlightResult() {
        var validation = KeyValidationRevision()
        let first = APIKeyCredential(key: "first", region: "Personal")
        let attempt = validation.begin(first)
        XCTAssertTrue(validation.accepts(attempt, current: first))
        XCTAssertFalse(validation.accepts(attempt, current: .init(key: "second", region: "Personal")))
        XCTAssertFalse(validation.accepts(attempt, current: .init(key: "first", region: "Business")))
        validation.invalidate()
        XCTAssertFalse(validation.accepts(attempt, current: first), "Changing away and back still needs a new test")
        let replacement = validation.begin(first)
        XCTAssertFalse(validation.accepts(attempt, current: first), "A superseded result cannot authorize Save Anyway")
        XCTAssertTrue(validation.accepts(replacement, current: first))
    }

    func testLocalizedBudgetsRequireACompleteFinitePositiveNumber() {
        let english = Locale(identifier: "en_US")
        let portuguese = Locale(identifier: "pt_PT")
        XCTAssertEqual(BudgetInput.parse("", locale: english), .clear)
        XCTAssertEqual(BudgetInput.parse(" \n ", locale: english), .clear)
        XCTAssertEqual(BudgetInput.parse("1,234.56", locale: english), .amount(1234.56))
        XCTAssertEqual(BudgetInput.parse("1234,56", locale: portuguese), .amount(1234.56))
        XCTAssertEqual(BudgetInput.parse("1.234,56", locale: Locale(identifier: "de_DE")), .amount(1234.56))
        for input in ["0", "-5", "NaN", "Infinity", "1x", "1,2,3", "1.2.3", "1e999", ".", "12,34.56"] {
            XCTAssertEqual(BudgetInput.parse(input, locale: english), .invalid, input)
        }
    }

    func testConcurrentPreferenceWriteReReadsAndPreservesBothChanges() async throws {
        var base = AlertPreferences()
        base.updatedAt = Date(timeIntervalSince1970: 100)
        var local = base
        local.resets = false
        local.updatedAt = Date(timeIntervalSince1970: 200)
        let server = PreferencesServer(base: base, conflicts: 1)
        let result = try await AlertPreferencesSync.synchronize(base: base, local: local,
            read: { await server.read() }, write: { try await server.write($0, revision: $1) },
            isConflict: { $0 is PreferencesServer.Conflict })
        XCTAssertFalse(result.preferences.resets)
        XCTAssertFalse(result.preferences.banked, "An intervening edit is merged on retry")
        let writes = await server.writes
        XCTAssertEqual(writes, 2)
    }

    func testPreferenceConflictsAreBoundedAndLeaveLocalDeltaPending() async {
        var base = AlertPreferences()
        base.updatedAt = Date(timeIntervalSince1970: 100)
        var local = base
        local.resets = false
        local.updatedAt = Date(timeIntervalSince1970: 200)
        let server = PreferencesServer(base: base, conflicts: 9)
        do {
            _ = try await AlertPreferencesSync.synchronize(base: base, local: local,
                read: { await server.read() }, write: { try await server.write($0, revision: $1) },
                isConflict: { $0 is PreferencesServer.Conflict })
            XCTFail("Exhausted conflicts must not report a successful sync")
        } catch { XCTAssertTrue(error is PreferencesServer.Conflict) }
        let writes = await server.writes
        XCTAssertEqual(writes, 3)
        let remote = await server.read().preferences
        XCTAssertTrue(AlertPreferencesSync.resolve(base: base, local: local, remote: remote).needsPublish)
    }
}

private actor PreferencesServer {
    struct Conflict: Error {}
    var value: AlertPreferences
    var revision = 0
    var conflicts: Int
    var writes = 0
    init(base: AlertPreferences, conflicts: Int) { value = base; self.conflicts = conflicts }
    func read() -> AlertPreferencesSync.Versioned<Int> { .init(preferences: value, revision: revision) }
    func write(_ preferences: AlertPreferences, revision fetched: Int) throws {
        writes += 1
        if conflicts > 0 {
            conflicts -= 1
            value.banked = false
            revision += 1
        }
        guard fetched == revision else { throw Conflict() }
        value = preferences
        revision += 1
    }
}
