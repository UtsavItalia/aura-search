import SwiftUI

/// A Space groups tabs, like Zen's workspaces. Local-only in phase 1.
struct Space: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var color: SpaceColor
    let createdAt: Date

    init(id: UUID = UUID(), name: String, color: SpaceColor, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
    }
}

enum SpaceColor: String, Codable, CaseIterable, Identifiable {
    case violet, blue, teal, green, orange, pink, gray

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .violet: return .purple
        case .blue: return .blue
        case .teal: return .teal
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .gray: return .gray
        }
    }
}
