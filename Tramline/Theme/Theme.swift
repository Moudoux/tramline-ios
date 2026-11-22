import SwiftUI
import UIKit

/// Tramline's colours from `shared/theme.css`, with darker shades in light mode so they
/// still read on white. The accent orange is the asset catalog's AccentColor.
enum Theme {
    static let accent = Color.accentColor
    static let good = Color(light: 0x2E8B4F, dark: 0x57C47A)
    static let bad = Color(light: 0xD13A30, dark: 0xF2645A)
    /// The 3D view's background, which is dark in both modes, from `view.js`.
    static let viewBackground = Color(red: 0x15 / 255, green: 0x18 / 255, blue: 0x1C / 255)

    static func color(_ tone: Tone) -> Color {
        switch tone {
        case .plain: .secondary
        case .active: accent
        case .good: good
        case .bad: bad
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let v = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                           blue: CGFloat(v & 0xff) / 255, alpha: 1)
        })
    }
}

/// The GUI's badge and chip: a word in a tinted capsule.
struct ToneChip: View {
    let text: String
    let tone: Tone
    var prominent = false

    var body: some View {
        Text(text)
            .font(prominent ? .subheadline.weight(.semibold) : .caption.weight(.medium))
            .padding(.horizontal, prominent ? 12 : 8)
            .padding(.vertical, prominent ? 5 : 3)
            .foregroundStyle(tone == .plain ? Color.secondary : Theme.color(tone))
            .background(Theme.color(tone).opacity(tone == .plain ? 0.12 : 0.18), in: .capsule)
            .contentTransition(.opacity)
    }
}
