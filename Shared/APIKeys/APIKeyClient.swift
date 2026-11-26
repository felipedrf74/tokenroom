import Foundation

struct APIKeyCredential: Sendable, Equatable {
    var key: String
    var region: String?
    var source: String?
}

struct APIKeyClient: ProviderClient {
    let provider: Provider
    var keys = APIKeyStore()
    var localCredential: (@Sendable (Provider) throws -> APIKeyCredential?)? = nil

    func fetch() async -> Result<QuotaSnapshot, ProviderError> {
        let keys = self.keys
        let provider = self.provider
        let local = localCredential
        do {
            let credential = try await BlockingIO.run { () throws -> APIKeyCredential? in
                if let key = keys.key(for: provider) {
                    return APIKeyCredential(key: key, region: keys.metadata(for: provider)?.region)
                }
                return try local?(provider)
            }
            guard let credential else {
                return .failure(.signedOut(provider.signInHint))
            }
            var snapshot = try await Self.snapshot(for: provider, key: credential.key, region: credential.region)
            snapshot.source = credential.source
            return .success(snapshot)
        } catch let error as ProviderError {
            return .failure(error)
        } catch {
            return .failure(.unreachable)
        }
    }

    static func snapshot(for provider: Provider, key: String, region: String?) async throws -> QuotaSnapshot {
        switch provider {
        case .openrouter:
            let data = try await TokenroomHTTP.get(URL(string: "https://openrouter.ai/api/v1/key")!, token: key, provider: provider)
            return try OpenRouterParser.snapshot(from: data)
        case .deepseek:
            let data = try await TokenroomHTTP.get(URL(string: "https://api.deepseek.com/user/balance")!, token: key, provider: provider)
            return try DeepSeekParser.snapshot(from: data)
        case .moonshot:
            let data = try await TokenroomHTTP.get(MoonshotEndpoint.balanceURL(region: region), token: key, provider: provider)
            return try MoonshotParser.snapshot(from: data, region: region)
        case .vercelGateway:
            let data = try await TokenroomHTTP.get(URL(string: "https://ai-gateway.vercel.sh/v1/credits")!, token: key, provider: provider)
            return try VercelGatewayParser.snapshot(from: data)
        case .openaiOrg, .anthropicOrg, .xaiOrg:
            return try await orgSnapshot(for: provider, key: key)
        case .zai:
            let data = try await TokenroomHTTP.get(CodingPlanEndpoint.zaiQuota(region: region), token: key, provider: provider)
            return try ZaiParser.snapshot(from: data)
        case .kimiCode:
            let data = try await TokenroomHTTP.get(CodingPlanEndpoint.kimiUsages(region: region), token: key, provider: provider)
            return try KimiCodeParser.snapshot(from: data)
        case .minimax:
            return try await minimaxSnapshot(key: key, region: region)
        case .copilot:
            return try await copilotSnapshot(key: key, planName: region)
        case .opencodeGo:
            let (data, response) = try await TokenroomHTTP.data(for: TokenroomHTTP.request(CodingPlanEndpoint.opencodeGoUsage, token: key))
            if let error = OpenCodeGoParser.error(status: response.statusCode, body: data) {
                throw error
            }
            try TokenroomHTTP.check(response, provider: provider)
            return try OpenCodeGoParser.snapshot(from: data)
        default:
            throw ProviderError.parse
        }
    }

    struct KeyCheck: Sendable {
        var snapshot: QuotaSnapshot
        var warning: String?
    }

    static func check(for provider: Provider, key: String, region: String?) async throws -> KeyCheck {
        let snapshot = try await snapshot(for: provider, key: key, region: region)
        var warning: String?
        if provider == .xaiOrg,
           let validation = try? await TokenroomHTTP.get(URL(string: "https://management-api.x.ai/auth/management-keys/validation")!, token: key, provider: provider),
           XAIBillingParser.canWrite(fromValidation: validation) {
            warning = "This key can also change your team's keys or billing. Tokenroom only reads with it, but a key limited to reading billing is safer."
        }
        return KeyCheck(snapshot: snapshot, warning: warning)
    }

    private static func minimaxSnapshot(key: String, region: String?) async throws -> QuotaSnapshot {
        let request = TokenroomHTTP.request(CodingPlanEndpoint.minimaxRemains(region: region, legacy: false), token: key)
        let (data, response) = try await TokenroomHTTP.data(for: request)
        if ![404, 405].contains(response.statusCode) {
            try TokenroomHTTP.check(response, provider: .minimax)
            do {
                return try MiniMaxParser.snapshot(from: data)
            } catch ProviderError.parse {
            } catch let notIncluded as ProviderError {
                guard case .notEntitled = notIncluded else { throw notIncluded }
                return try await minimaxCodingPlan(key: key, region: region, otherwise: notIncluded)
            }
        }
        return try await minimaxCodingPlan(key: key, region: region)
    }

    private static func minimaxCodingPlan(key: String, region: String?, otherwise: ProviderError? = nil) async throws -> QuotaSnapshot {
        let request = TokenroomHTTP.request(CodingPlanEndpoint.minimaxRemains(region: region, legacy: true), token: key)
        let (data, response) = try await TokenroomHTTP.data(for: request)
        if let otherwise, [404, 405].contains(response.statusCode) { throw otherwise }
        try TokenroomHTTP.check(response, provider: .minimax)
        do {
            return try MiniMaxParser.snapshot(from: data, legacy: true)
        } catch let error as ProviderError {
            guard let otherwise else { throw error }
            switch error {
            case .notEntitled, .parse: throw otherwise
            default: throw error
            }
        }
    }
}
