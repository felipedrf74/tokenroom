import Foundation

struct GrokBotClient: ProviderClient {
    var provider: Provider { .grokBot }
    var readSession: @Sendable (_ allowLegacyCursor: Bool) throws -> GrokBotCredentials.Session = {
        try GrokBotCredentials.read(allowLegacyCursor: $0)
    }
    var cursorAfterRefusal: @Sendable (String) -> String? = { CredentialReaders.cursorTokenAfterRefusal(of: $0) }

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        do {
            let session = try await BlockingIO.run { try readSession(true) }
            do {
                return .success(try await usage(session))
            } catch ProviderError.expired {
                let fresh: GrokBotCredentials.Session?
                if session.isNative {
                    // Grok Bot may have renewed or switched its own active login meanwhile.
                    fresh = try await BlockingIO.run { try readSession(false) }
                } else {
                    fresh = await BlockingIO.run { cursorAfterRefusal(session.token).map {
                        GrokBotCredentials.Session(token: $0, isNative: false)
                    } }
                }
                guard let fresh, fresh.token != session.token else {
                    throw ProviderError.expired(Provider.grokBot.expiredHint)
                }
                return .success(try await usage(fresh))
            }
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    private func usage(_ session: GrokBotCredentials.Session) async throws -> QuotaSnapshot {
        let url = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
        let data: Data
        do {
            data = try await TokenroomHTTP.post(
                url,
                token: session.token,
                headers: ["Connect-Protocol-Version": "1"],
                provider: .grokBot
            )
        } catch ProviderError.expired {
            if session.isNative { GrokBotCredentials.noteRefused(session.token) }
            throw ProviderError.expired(Provider.grokBot.expiredHint)
        }
        return try GrokBotParser.snapshot(from: data)
    }
}
