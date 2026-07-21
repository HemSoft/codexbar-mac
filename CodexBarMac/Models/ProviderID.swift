import Foundation

public enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case copilot
    case claude
    case openRouter
    case openCodeZen
    case moonshot
    case cursor
    case gemini

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .codex:
            "ChatGPT / Codex"
        case .copilot:
            "GitHub Copilot"
        case .claude:
            "Claude"
        case .openRouter:
            "OpenRouter"
        case .openCodeZen:
            "OpenCode ZEN"
        case .moonshot:
            "Moonshot (Kimi)"
        case .cursor:
            "Cursor"
        case .gemini:
            "Gemini"
        }
    }
}
