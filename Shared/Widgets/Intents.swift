import AppIntents
import WidgetKit

enum WidgetStyleOption: String, AppEnum {
    case recommended
    case list
    case tiles

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [WidgetStyleOption: DisplayRepresentation] = [
        .recommended: DisplayRepresentation(title: "Recommended", subtitle: "A list, with a second limit on Small"),
        .list: DisplayRepresentation(title: "List", subtitle: "One row per provider"),
        .tiles: DisplayRepresentation(title: "Tiles", subtitle: "A tile per provider, with a second limit"),
    ]

    func usesTiles(isSmall: Bool) -> Bool {
        switch self {
        case .recommended: isSmall
        case .list: false
        case .tiles: true
        }
    }
}

enum ProviderOption: String, AppEnum {
    case automatic
    case claude, openai, grok, grokBot, cursor, copilot, antigravity, devin
    case zai, kimiCode, minimax, opencodeGo
    case openrouter, deepseek, moonshot, vercelGateway
    case openaiOrg, anthropicOrg, xaiOrg

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let caseDisplayRepresentations: [ProviderOption: DisplayRepresentation] = [
        .automatic: "Use Widget Settings",
        .claude: "Claude",
        .openai: "OpenAI (Codex)",
        .grok: "Grok Build",
        .grokBot: "Grok Bot",
        .cursor: "Cursor",
        .copilot: "GitHub Copilot",
        .antigravity: "Antigravity",
        .devin: "Devin",
        .zai: "Z.ai",
        .kimiCode: "Kimi Code",
        .minimax: "MiniMax",
        .opencodeGo: "OpenCode Go",
        .openrouter: "OpenRouter",
        .deepseek: "DeepSeek",
        .moonshot: "Moonshot",
        .vercelGateway: "Vercel AI Gateway",
        .openaiOrg: "OpenAI API",
        .anthropicOrg: "Anthropic API",
        .xaiOrg: "xAI API",
    ]

    var providerID: String? {
        self == .automatic ? nil : rawValue
    }
}

struct SelectProviderIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Choose Provider"
    static let description = IntentDescription("The provider this widget shows first, and how it lays out its readings.")

    @Parameter(title: "Provider", default: .automatic)
    var provider: ProviderOption

    @Parameter(title: "Style", default: .recommended)
    var style: WidgetStyleOption

    static var parameterSummary: some ParameterSummary {
        When(widgetFamily: .oneOf, [.systemSmall, .systemMedium, .systemLarge]) {
            Summary {
                \.$provider
                \.$style
            }
        } otherwise: {
            Summary {
                \.$provider
            }
        }
    }

    init() {}

    init(provider: ProviderOption, style: WidgetStyleOption = .recommended) {
        self.provider = provider
        self.style = style
    }
}

struct RefreshReadingsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Usage"
    static let description = IntentDescription("Checks your usage again.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        _ = await WidgetRefresher.cache(force: true)
        return .result()
    }
}
