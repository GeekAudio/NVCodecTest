import SwiftUI
import AppKit

/// Native semantic colors remain dynamic: appearance, accent and accessibility belong to macOS.
struct DesignTokens {
    enum Text {
        // Aqua / Dark Aqua, controlBackground: label 14.94 / 12.23:1;
        // secondaryLabel 3.95 / 5.89:1. Measured 2026-10-29; see docs for context.
        static var primary: Color { Color(.labelColor) }
        static var secondary: Color { Color(.secondaryLabelColor) }
        static var tertiary: Color { Color(.tertiaryLabelColor) }
        static var placeholder: Color { Color(.placeholderTextColor) }
    }
    enum Surface {
        static var window: Color { Color(.windowBackgroundColor) }
        static var content: Color { Color(.controlBackgroundColor) }
        static var control: Color { Color(.controlBackgroundColor) }
        static var inset: Color { Color(.underPageBackgroundColor) }
    }
    enum Stroke {
        static var separator: Color { Color(.separatorColor) }
    }
    enum Interaction {
        static var accent: Color { Color(.controlAccentColor) }
        static var link: Color { Color(.linkColor) }
        static func selection(active: Bool) -> Color {
            Color(active ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
        }
        static let hoverOpacity = 0.03
        static let restingInsetOpacity = 0.08
        static let pressedOpacity = 0.04
        static let disabledOpacity = 0.45
        static let duration = 0.14
    }
    enum Status {
        static var error: Color { Color(.systemRed) }
        static var warning: Color { Color(.systemOrange) }
        static var success: Color { Color(.systemGreen) }
        static var info: Color { Color(.systemBlue) }
        static let backgroundOpacity = 0.12
        // Native green/orange on Aqua controlBackground measure only 2.22 / 2.31:1.
        // Essential status words and symbols therefore use labelColor; tint is redundant.
    }
    enum Font {
        static let small = SwiftUI.Font.system(size: 11)
        static let body = SwiftUI.Font.system(size: 13)
        static let title3 = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let title2 = SwiftUI.Font.system(size: 17, weight: .semibold)
        static let title1 = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let largeTitle = SwiftUI.Font.system(size: 28, weight: .medium)
    }
    static let corner: CGFloat = 8
    static let controlCorner: CGFloat = 6
    static func hairline(scale: CGFloat) -> CGFloat { 1 / max(1, scale) }
}

/// Narrow AppKit bridge needed for the macOS 11 sidebar material and blending mode.
struct NativeMaterial: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
    }
}

struct Hairline: View {
    var axis: Axis = .horizontal
    @Environment(\.displayScale) private var scale
    var body: some View {
        Rectangle().fill(DesignTokens.Stroke.separator)
            .frame(width: axis == .vertical ? DesignTokens.hairline(scale: scale) : nil,
                   height: axis == .horizontal ? DesignTokens.hairline(scale: scale) : nil)
            .accessibilityHidden(true)
    }
}

/// Keep macOS's bezel, focus ring, pressed/hover behavior and keyboard activation.
struct NativeButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if #available(macOS 12, *) {
            if prominent {
                Button(configuration).buttonStyle(.borderedProminent).controlSize(.regular).frame(minHeight: 28)
                    .opacity(enabled ? 1 : DesignTokens.Interaction.disabledOpacity)
            } else {
                Button(configuration).buttonStyle(.bordered).controlSize(.regular).frame(minHeight: 28)
                    .opacity(enabled ? 1 : DesignTokens.Interaction.disabledOpacity)
            }
        } else {
            Button(configuration).buttonStyle(DefaultButtonStyle()).controlSize(.regular).frame(minHeight: 28)
                .opacity(enabled ? 1 : DesignTokens.Interaction.disabledOpacity)
        }
    }
}

// Existing view vocabulary maps to centralized semantic roles, never to RGB constants.
extension Color {
    static var codecBackground: Color { DesignTokens.Surface.window }
    static var codecInset: Color { DesignTokens.Surface.inset.opacity(0.12) }
    static var cardBG: Color { DesignTokens.Surface.content }
    static var sep: Color { DesignTokens.Stroke.separator }
    static var txt: Color { DesignTokens.Text.primary }
    static var sub: Color { DesignTokens.Text.secondary }
    static var codecAccent: Color { DesignTokens.Interaction.accent }
    static var statusSuccess: Color { DesignTokens.Status.success }
    static var statusWarning: Color { DesignTokens.Status.warning }
    static var statusError: Color { DesignTokens.Status.error }
    static var statusInfo: Color { DesignTokens.Status.info }
}

struct PanelStyle: ViewModifier {
    var padding: CGFloat = 12
    @Environment(\.displayScale) private var scale
    func body(content: Content) -> some View {
        content.padding(padding)
            .background(RoundedRectangle(cornerRadius: DesignTokens.corner).fill(DesignTokens.Surface.content))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.corner)
                .strokeBorder(DesignTokens.Stroke.separator, lineWidth: DesignTokens.hairline(scale: scale)))
    }
}

struct StatusPill: View {
    let text: String
    var color: Color = .sub
    var body: some View {
        Text(text).font(DesignTokens.Font.small)
            .foregroundColor(DesignTokens.Text.primary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: DesignTokens.controlCorner)
                .fill(color.opacity(DesignTokens.Status.backgroundOpacity)))
    }
}

struct SectionHeading: View {
    let number: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if !number.isEmpty { SwiftUI.Text(number).font(DesignTokens.Font.small.monospacedDigit()).foregroundColor(.sub) }
            SwiftUI.Text(title).font(DesignTokens.Font.title3).foregroundColor(.txt)
            SwiftUI.Text(subtitle).font(DesignTokens.Font.small).foregroundColor(.sub)
            Spacer(minLength: 0)
        }
    }
}
