import CryptoKit
import Foundation

/// Updated collectors coordinate through one stable private record per alert key. The reset
/// bucket remains a legacy Event name, not the cross-device lock. A winning reset anchor never
/// moves: repeated jitter cannot walk ownership into a genuinely new window.
enum AlertDeliveryCoordinator {
    enum Mode: String, Codable, Sendable { case pushed, shown }
    struct Receipt: Equatable, Sendable {
        var eventID: String
        var mode: Mode
        var created: Bool
    }
    struct Versioned<Revision: Sendable>: Sendable {
        var data: Data?
        var revision: Revision
    }
    struct LegacyEvent: Sendable {
        var id: String
        var provider: String
        var kind: String
        var level: Int
        var key: String
        var resetsAt: Date?
    }
    enum Failure: Error { case damaged, unsupportedVersion, capacity }
    struct Scope: Sendable {
        var recordName: String
        var reset: Date
        var kind: String?
    }
    private struct Entry: Codable {
        var reset: Date
        var kind: String?
        var eventID: String
        var mode: Mode
        var expiresAt: Date
    }
    private struct Document: Codable {
        var version = 1
        var entries: [Entry] = []
    }

    static func scope(for alert: UsageAlert) -> Scope? {
        guard [.threshold, .runsOut, .reset, .lowBalance].contains(alert.kind), let window = alert.window else { return nil }
        // A queued reset from an old build has only its rounded ended-reset instance. Never
        // use its displayed resetsAt, which describes the new window.
        let reset: Date?
        if alert.kind == .reset {
            reset = alert.identityResetAt ?? legacyReset(alert.instanceName, kind: alert.windowKind)
        } else {
            reset = alert.identityResetAt ?? alert.resetsAt
        }
        guard let reset, reset.timeIntervalSince1970.isFinite else { return nil }
        let parts = [alert.provider, window, alert.key].map { "\($0.utf8.count):\($0)" }.joined()
        let digest = SHA256.hash(data: Data(parts.utf8)).map { String(format: "%02x", $0) }.joined()
        return Scope(recordName: "alert-coordination-\(digest)", reset: reset, kind: alert.windowKind)
    }

    /// `write` must atomically compare the revision and create the Event (if non-nil). An
    /// adopted legacy Event is left untouched, so older unfiltered subscriptions see no alias.
    static func deliver<Revision: Sendable>(
        _ alert: UsageAlert, scope: Scope, mode: Mode, now: Date = .now,
        read: @Sendable () async throws -> Versioned<Revision>,
        legacy: @Sendable ([String]) async throws -> [LegacyEvent],
        write: @Sendable (Data, Revision, Receipt?) async throws -> Void,
        isConflict: @Sendable (Error) -> Bool
    ) async throws -> Receipt {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let fetched = try await read()
            try Task.checkCancellation()
            var document = try decoded(fetched.data)
            document.entries.removeAll { $0.expiresAt < now }
            if let owned = document.entries.first(where: { matches($0, scope) }) {
                return Receipt(eventID: owned.eventID, mode: owned.mode, created: false)
            }
            let old = try await legacy(legacyIDs(for: alert))
            try Task.checkCancellation()
            let adopted = old.first { matchesLegacy($0, alert: alert, scope: scope) }
            let receipt = Receipt(eventID: adopted?.id ?? alert.id,
                                  mode: adopted.map { $0.key.hasPrefix("shown:") ? .shown : .pushed } ?? mode,
                                  created: adopted == nil)
            // Bound the payload without discarding still-owned future/monthly windows.
            guard document.entries.count < 256 else { throw Failure.capacity }
            let expiry = max(now.addingTimeInterval(AlertLedger.memory), scope.reset.addingTimeInterval(AlertLedger.pendingLifetime))
            document.entries.append(Entry(reset: scope.reset, kind: scope.kind, eventID: receipt.eventID,
                                          mode: receipt.mode, expiresAt: expiry))
            do {
                try Task.checkCancellation()
                try await write(RelayEnvelope.encoder.encode(document), fetched.revision, adopted == nil ? receipt : nil)
                try Task.checkCancellation()
                return receipt
            } catch {
                guard isConflict(error), attempt < 2 else { throw error }
            }
        }
        preconditionFailure("Bounded delivery attempts always return or throw")
    }

    private static func decoded(_ data: Data?) throws -> Document {
        guard let data else { return Document() }
        let document: Document
        do { document = try RelayEnvelope.decoder.decode(Document.self, from: data) }
        catch { throw Failure.damaged }
        guard document.version == 1 else { throw Failure.unsupportedVersion }
        guard document.entries.count <= 256, document.entries.allSatisfy({
            $0.reset.timeIntervalSince1970.isFinite && $0.expiresAt.timeIntervalSince1970.isFinite && !$0.eventID.isEmpty
        }) else { throw Failure.damaged }
        return document
    }
    private static func matches(_ entry: Entry, _ scope: Scope) -> Bool {
        (entry.kind == nil || scope.kind == nil || entry.kind == scope.kind)
            && abs(entry.reset.timeIntervalSince(scope.reset)) < AlertRules.resetJitter
    }

    static func legacyIDs(for alert: UsageAlert) -> [String] {
        guard let value = Double(alert.instanceName), value.isFinite,
              alert.id.hasSuffix("-" + alert.instanceName) else { return [alert.id] }
        // Legacy IDs always count 600-second units, even when rounded to an hour (multiples
        // of six). Enumerating those units also handles a provider's custom period length.
        let radius = 7 // 30-minute jitter plus at most 30-minute rounding error, and an edge.
        let prefix = String(alert.id.dropLast(alert.instanceName.count))
        // Exact first, then a finite neighborhood; never query every historical Event.
        return [alert.id] + (-radius...radius).filter { $0 != 0 }.map { prefix + String(format: "%.0f", value + Double($0)) }
    }
    private static func matchesLegacy(_ event: LegacyEvent, alert: UsageAlert, scope: Scope) -> Bool {
        guard event.provider == alert.provider, event.kind == alert.kind.rawValue, event.level == alert.level,
              event.key == alert.key || event.key == alert.shownKey else { return false }
        let reset = alert.kind == .reset
            ? legacyReset(event.id.components(separatedBy: "-").last ?? "", kind: alert.windowKind)
            : event.resetsAt
        guard let reset else { return false }
        // Old reset events store only the rounded ended reset. Allow the rounding error;
        // all new ownership uses the exact immutable identityResetAt.
        let bucket = (alert.identityPeriodSec ?? AlertRules.typicalLength(kind: alert.windowKind ?? "")) >= 86_400 ? 3600.0 : 600.0
        let tolerance = AlertRules.resetJitter + (alert.kind == .reset ? bucket / 2 : 0)
        return abs(reset.timeIntervalSince(scope.reset)) < tolerance
    }
    private static func legacyReset(_ instance: String, kind: String?) -> Date? {
        guard let number = Double(instance), number.isFinite else { return nil }
        return Date(timeIntervalSince1970: number * 600)
    }
}
