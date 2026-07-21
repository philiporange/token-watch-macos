import SwiftUI

enum AppTheme {
    /// A warm orange accent for Claude
    static let claudeAccent: Color = Color(red: 0.95, green: 0.45, blue: 0.10)

    /// A medium blue accent for Codex
    static let codexAccent: Color = Color(red: 0.10, green: 0.50, blue: 0.95)

    /// A green accent for Gemini
    static let geminiAccent: Color = Color(red: 0.20, green: 0.66, blue: 0.33)

    /// A purple accent for Z.ai
    static let zaiAccent: Color = Color(red: 0.56, green: 0.24, blue: 0.86)

    /// Returns the accent color for the given provider.
    /// - Parameter provider: The provider kind to get the accent for
    /// - Returns: The accent color associated with the provider
    static func accent(for provider: ProviderKind) -> Color {
        switch provider {
        case .claude:
            return claudeAccent
        case .codex:
            return codexAccent
        case .gemini:
            return geminiAccent
        case .zai:
            return zaiAccent
        }
    }
}
