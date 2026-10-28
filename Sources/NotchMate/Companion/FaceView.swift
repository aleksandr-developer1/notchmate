import SwiftUI

enum FacePalette: String, CaseIterable, Identifiable {
    case oled, mint, white, pink, amber
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .oled: return Color(red: 0.84, green: 0.96, blue: 1.0)
        case .mint: return Color(red: 0.55, green: 1.0, blue: 0.86)
        case .white: return Color(white: 0.97)
        case .pink: return Color(red: 1.0, green: 0.66, blue: 0.84)
        case .amber: return Color(red: 1.0, green: 0.8, blue: 0.35)
        }
    }
    var title: String {
        switch self {
        case .oled: return "OLED"
        case .mint: return String(localized: "Мятный")
        case .white: return String(localized: "Белый")
        case .pink: return String(localized: "Розовый")
        case .amber: return String(localized: "Янтарный")
        }
    }
}

/// The face is drawn in a 96 × 60 unit box; `scale` turns units into points (0.5 → 48 × 30 pt under the notch).
enum FaceGeometry {
    static let size = CGSize(width: 96, height: 60)
}
