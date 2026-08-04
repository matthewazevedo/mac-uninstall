import AppKit
import MacUninstallCore
import SwiftUI

/// The design system, transcribed from `Mac Uninstall Design System.dc.html`.
///
/// Every value here comes from that document rather than from SwiftUI's semantic
/// defaults. The system is deliberately near-neutral: cool greys carry the whole
/// interface, and saturation is reserved for exactly three meanings — confidence,
/// permission, and outcome.
enum DS {}

// MARK: - Colour

extension Color {
    /// Resolves per appearance, so light and dark are both first-class rather than
    /// one being derived from the other.
    init(light: String, dark: String) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(hex: dark)
                : NSColor(hex: light)
        })
    }
}

extension NSColor {
    convenience init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex)
            .scanHexInt64(&value)
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension DS {
    enum Palette {
        // Surfaces
        static let surface = Color(light: "#FFFFFF", dark: "#1D2025")
        static let canvas = Color(light: "#F7F8FA", dark: "#16181C")
        static let bar = Color(light: "#EDEFF3", dark: "#121417")
        static let hairline = Color(light: "#E2E5EA", dark: "#2A2E35")
        static let ruleStrong = Color(light: "#D3D7DE", dark: "#363B44")

        // Text
        static let textPrimary = Color(light: "#1B1E24", dark: "#E9ECF1")
        static let textSecondary = Color(light: "#5C636E", dark: "#9AA2AE")
        static let textTertiary = Color(light: "#878E9A", dark: "#6E7681")

        /// Chrome only: default button, focus ring, selection. Nothing else.
        static let accent = Color(light: "#3F6DB5", dark: "#6E9BE0")
        /// Text placed on top of the accent fill.
        static let onAccent = Color(light: "#FFFFFF", dark: "#0E1116")
        static let accentBorder = Color(light: "#365F9F", dark: "#6E9BE0")

        // Controls
        static let controlFill = Color(light: "#FFFFFF", dark: "#2A2E35")
        static let controlBorder = Color(light: "#C9CED6", dark: "#3A404A")
        static let controlDisabledFill = Color(light: "#A7B4C6", dark: "#232830")
        static let controlDisabledText = Color(light: "#FFFFFF", dark: "#6E7681")
        static let checkboxBorder = Color(light: "#B7BEC8", dark: "#4A505B")
        static let quarantineFill = Color(light: "#F0F1F4", dark: "#232830")

        // Meaning. These three are the only saturated colours in the app.
        static let certain = Color(light: "#1F8A5B", dark: "#4FB98A")
        static let likely = Color(light: "#4C7BC4", dark: "#7DA8E4")
        static let needsReview = Color(light: "#B5761F", dark: "#DCA34A")

        /// Badge label colours. On light these are darkened so every badge clears
        /// 4.5:1 against its own 13–15% tint.
        static let certainLabel = Color(light: "#1F8A5B", dark: "#4FB98A")
        static let likelyLabel = Color(light: "#3F6DB5", dark: "#7DA8E4")
        static let needsReviewLabel = Color(light: "#96620F", dark: "#DCA34A")
    }
}

// MARK: - Type

extension DS {
    /// SF Pro for everything a person reads; SF Mono for everything the filesystem
    /// wrote — paths, identifiers, sizes. Evidence should look like evidence.
    enum TypeScale {
        static let summaryTitle = Font.system(size: 28, weight: .semibold)
        static let screenTitle = Font.system(size: 20, weight: .semibold)
        static let categoryHeader = Font.system(size: 15, weight: .semibold)
        static let rowTitle = Font.system(size: 14)
        static let bodyEmphasis = Font.system(size: 14, weight: .medium)
        static let control = Font.system(size: 13)
        static let controlEmphasis = Font.system(size: 13, weight: .medium)
        static let bannerTitle = Font.system(size: 13, weight: .semibold)
        static let secondary = Font.system(size: 12)
        static let smallControl = Font.system(size: 12)
        static let badge = Font.system(size: 10, weight: .semibold)

        /// Paths, bundle identifiers, byte counts.
        static let mono = Font.system(size: 12, design: .monospaced)
        static let monoSmall = Font.system(size: 11, design: .monospaced)
    }

    /// Tracking values from the spec, converted from em to points.
    enum Tracking {
        static let summaryTitle: CGFloat = 28 * -0.02
        static let screenTitle: CGFloat = 20 * -0.012
        static let badge: CGFloat = 10 * 0.06
    }
}

// MARK: - Metrics

extension DS {
    /// A 4pt base.
    enum Space {
        static let iconToLabel: CGFloat = 4
        static let insideRow: CGFloat = 8
        static let control: CGFloat = 12
        static let pane: CGFloat = 16
        static let group: CGFloat = 24
        static let emptyState: CGFloat = 40
    }

    enum Radius {
        static let control: CGFloat = 4
        static let inlineContainer: CGFloat = 6
        static let card: CGFloat = 10
        static let pill: CGFloat = 999
    }

    enum Metric {
        /// Rows breathe: 14pt vertical padding, not 7.
        static let rowVerticalPadding: CGFloat = 14
        /// Row dividers are inset to clear the checkbox.
        static let dividerInset: CGFloat = 44
        static let categoryHeaderVerticalPadding: CGFloat = 9
        static let checkbox: CGFloat = 14
        static let sidebarIcon: CGFloat = 26
        /// Shadow is used exactly once, on the drop overlay.
        static let overlayShadowRadius: CGFloat = 28
        static let overlayShadowY: CGFloat = 8
    }
}

// MARK: - Shared components

extension Confidence {
    var tint: Color {
        switch self {
        case .certain: DS.Palette.certain
        case .likely: DS.Palette.likely
        case .possible: DS.Palette.needsReview
        }
    }

    var labelColor: Color {
        switch self {
        case .certain: DS.Palette.certainLabel
        case .likely: DS.Palette.likelyLabel
        case .possible: DS.Palette.needsReviewLabel
        }
    }

    /// 13–15% on light, 16% on dark. Kept as one value; the label colour carries the
    /// contrast difference between modes.
    var tintOpacity: Double { 0.15 }
}

/// One badge shape, three levels, fixed order. It always sits immediately after the
/// filename — never at the end of the row.
struct ConfidenceBadge: View {
    let confidence: Confidence

    var body: some View {
        Text(confidence.label.uppercased())
            .font(DS.TypeScale.badge)
            .tracking(DS.Tracking.badge)
            .foregroundStyle(confidence.labelColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(confidence.tint.opacity(confidence.tintOpacity), in: Capsule())
    }
}

/// The app's only button styles: a filled default, and a bordered everything-else.
/// Deliberately no destructive variant — nothing here is erased, and a red button
/// would claim otherwise.
struct AccentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.TypeScale.controlEmphasis)
            .foregroundStyle(isEnabled ? DS.Palette.onAccent : DS.Palette.controlDisabledText)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isEnabled ? DS.Palette.accent : DS.Palette.controlDisabledFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isEnabled ? DS.Palette.accentBorder : DS.Palette.controlDisabledFill)
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(.rect)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? DS.TypeScale.smallControl : DS.TypeScale.control)
            .foregroundStyle(DS.Palette.textPrimary)
            .padding(.horizontal, small ? 10 : 14)
            .padding(.vertical, small ? 3 : 5)
            .background(
                RoundedRectangle(cornerRadius: small ? DS.Radius.control : 5)
                    .fill(DS.Palette.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: small ? DS.Radius.control : 5)
                    .stroke(DS.Palette.controlBorder)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.rect)
    }
}

/// Structure is drawn with hairlines, not shadows.
struct Hairline: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(DS.Palette.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// The checkbox is drawn rather than using the system control, so its 14pt size and
/// radius match the row metrics in the spec.
struct DSCheckbox: View {
    let isOn: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(isOn ? DS.Palette.accent : DS.Palette.controlFill)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isOn ? DS.Palette.accentBorder : DS.Palette.checkboxBorder)
            )
            .overlay {
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.Palette.onAccent)
                }
            }
            .frame(width: DS.Metric.checkbox, height: DS.Metric.checkbox)
    }
}

/// Tinted notice with a dot, not an icon. Used for permission and completeness
/// warnings, where the tint carries the meaning.
struct NoticeBanner<Actions: View>: View {
    let tint: Color
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: DS.Space.control) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DS.TypeScale.bannerTitle)
                    .foregroundStyle(DS.Palette.textPrimary)
                Text(detail)
                    .font(DS.TypeScale.secondary)
                    .foregroundStyle(DS.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Space.insideRow)
            actions
        }
        .padding(.horizontal, DS.Space.pane)
        .padding(.vertical, DS.Space.control)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(0.28))
        )
    }
}
