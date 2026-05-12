import Foundation
import SwiftUI

enum ServiceType: String, Codable, CaseIterable, Identifiable {
    case claude = "Claude"
    case claudeCode = "Claude Code"
    case openai = "OpenAI"
    case codexCli = "Codex CLI"
    case cursor = "Cursor"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude API"
        case .claudeCode: return "Claude Code"
        case .openai: return "OpenAI"
        case .codexCli: return "OpenAI Codex"
        case .cursor: return "Cursor"
        }
    }

    var iconName: String {
        switch self {
        case .claude: return "sparkles"
        case .claudeCode: return "terminal"
        case .openai: return "brain"
        case .codexCli: return "terminal.fill"
        case .cursor: return "cursorarrow.click"
        }
    }

    var brandColor: Color {
        switch self {
        case .claude, .claudeCode: return Color(red: 224/255, green: 128/255, blue: 0/255)   // #E08000
        case .openai, .codexCli:   return Color(red: 144/255, green: 112/255, blue: 240/255) // #9070F0
        case .cursor:              return Color(red:  16/255, green: 192/255, blue: 224/255) // #10C0E0
        }
    }
}
