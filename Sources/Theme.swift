import SwiftUI
import AppKit

// Fixed muted light palette shared by the dashboard and all detail windows.
extension Color {
    static let codecBackground = Color(red: 0.957, green: 0.961, blue: 0.953)
    static let codecInset = Color(red: 0.925, green: 0.937, blue: 0.922)
    static let cardBG = Color(red: 0.992, green: 0.996, blue: 0.988)
    static let sep = Color(red: 0.867, green: 0.890, blue: 0.871)
    static let txt = Color(red: 0.204, green: 0.263, blue: 0.239)
    static let sub = Color(red: 0.455, green: 0.506, blue: 0.475)
    static let okGreen = Color(red: 0.486, green: 0.600, blue: 0.541)
    static let warnOrange = Color(red: 0.698, green: 0.620, blue: 0.494)
    static let badRed = Color(red: 0.702, green: 0.561, blue: 0.549)
    static let codecAccent = Color.okGreen
    static let systemBlue = Color(red: 0.498, green: 0.612, blue: 0.671)
}

struct PanelStyle: ViewModifier {
    var padding: CGFloat = 14
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.cardBG))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.sep.opacity(0.7), lineWidth: 1))
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .sub
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.10)))
    }
}

struct SectionHeading: View {
    let number: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(number).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundColor(.codecAccent)
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundColor(.txt)
            Text(subtitle).font(.system(size: 11)).foregroundColor(.sub)
            Spacer(minLength: 0)
        }
    }
}
