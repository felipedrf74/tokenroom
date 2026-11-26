import Foundation
import os

struct GrokClient: ProviderClient {
    var provider: Provider { .grok }

    private static let planCache = OSAllocatedUnfairLock<(label: String?, at: Date)?>(initialState: nil)
    private static let planTTL: TimeInterval = 6 * 3_600

    func credentialsChanged() {
        Self.planCache.withLock { $0 = nil }
    }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            let auth = try await LoginSession.shared.grok()
            let snapshot = try await billing(auth)
            return .success(snapshot)
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    private func billing(_ auth: CredentialReaders.GrokAuth) async throws -> QuotaSnapshot {
        let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        do {
            return try await billing(auth, url: url)
        } catch ProviderError.expired {
            let fresh = try await LoginSession.shared.grok(replacing: auth.accessToken)
            guard fresh.accessToken != auth.accessToken else {
                throw ProviderError.expired(Provider.grok.expiredHint)
            }
            return try await billing(fresh, url: url)
        }
    }

    private func billing(_ auth: CredentialReaders.GrokAuth, url: URL) async throws -> QuotaSnapshot {
        var headers: [String: String] = [:]
        if let userID = auth.userID {
            headers["x-userid"] = userID
        }
        let data = try await TokenroomHTTP.get(url, token: auth.accessToken, headers: headers, provider: .grok)
        var snapshot = try GrokParser.snapshot(from: data)
        snapshot.planLabel = await planLabel(token: auth.accessToken, headers: headers)
        return snapshot
    }

    private func planLabel(token: String, headers: [String: String]) async -> String? {
        if let cached = Self.planCache.withLock({ $0 }), Date().timeIntervalSince(cached.at) < Self.planTTL {
            return cached.label
        }
        guard let data = try? await TokenroomHTTP.get(
            URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!,
            token: token,
            headers: headers,
            provider: .grok
        ) else {
            return Self.planCache.withLock { $0?.label }
        }
        let label = GrokParser.planLabel(fromSettings: data)
        Self.planCache.withLock { $0 = (label, Date()) }
        return label
    }
}
