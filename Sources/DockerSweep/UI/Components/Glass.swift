import AppKit
import SwiftUI

/// Shared glass design: translucent surfaces that blur what is behind them,
/// with a bright specular edge, a 1px rim and one soft shadow.
/// All tokens live here. Brand colour is Docker blue (the product's domain colour).
enum Glass {
  // Radius scale
  static let panelRadius: CGFloat = 20
  static let insetRadius: CGFloat = 16
  static let dialogRadius: CGFloat = 24
  static let controlRadius: CGFloat = 10

  /// Inner radius = outer radius minus padding, never below 4.
  static func innerRadius(outer: CGFloat, padding: CGFloat) -> CGFloat { max(outer - padding, 4) }

  // Brand (Docker blue) and derived colours
  static let brand = Color(red: 0x24 / 255, green: 0x96 / 255, blue: 0xED / 255)
  static let brandLight1 = Color(red: 0x7F / 255, green: 0xC0 / 255, blue: 0xF7 / 255)
  static let brandLight2 = Color(red: 0xA9 / 255, green: 0xD3 / 255, blue: 0xFA / 255)
  static let brandLight3 = Color(red: 0x4F / 255, green: 0xA8 / 255, blue: 0xEF / 255)
  static let brandDark1 = Color(red: 0x0B / 255, green: 0x3D / 255, blue: 0x91 / 255)
  static let brandDark2 = Color(red: 0x0A / 255, green: 0x2A / 255, blue: 0x63 / 255)
  static let brandDark3 = Color(red: 0x14 / 255, green: 0x5A / 255, blue: 0xB8 / 255)

  private static func dynamic(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light })
  }
  private static func white(_ a: CGFloat) -> NSColor { NSColor(white: 1, alpha: a) }

  // Translucent fills
  static let fill = dynamic(light: NSColor(srgbRed: 0.957, green: 0.973, blue: 0.996, alpha: 0.52), dark: white(0.07))
  static let insetFill = dynamic(light: NSColor(srgbRed: 0.957, green: 0.973, blue: 0.996, alpha: 0.38), dark: white(0.05))
  // Solid fallbacks (reduced transparency, increased contrast)
  static let solid = dynamic(light: NSColor(srgbRed: 0.957, green: 0.973, blue: 0.996, alpha: 1), dark: NSColor(srgbRed: 0.094, green: 0.114, blue: 0.149, alpha: 1))
  static let insetSolid = dynamic(light: NSColor(srgbRed: 0.918, green: 0.945, blue: 0.984, alpha: 1), dark: NSColor(srgbRed: 0.075, green: 0.09, blue: 0.121, alpha: 1))
  static let solidBorder = dynamic(light: NSColor(srgbRed: 0.69, green: 0.77, blue: 0.87, alpha: 1), dark: NSColor(srgbRed: 0.27, green: 0.33, blue: 0.42, alpha: 1))
  // Edge, rim, shadow
  static let edge = dynamic(light: white(0.9), dark: white(0.22))
  static let rim = dynamic(light: white(0.5), dark: white(0.08))
  static let shadow = dynamic(
    light: NSColor(srgbRed: 0x0B / 255, green: 0x3D / 255, blue: 0x91 / 255, alpha: 0.10),
    dark: NSColor(white: 0, alpha: 0.35))
  // Window base behind the colour field
  static let base = dynamic(light: NSColor(srgbRed: 0.949, green: 0.969, blue: 0.992, alpha: 1), dark: NSColor(srgbRed: 0.055, green: 0.07, blue: 0.098, alpha: 1))
}

private struct GlassSurface: ViewModifier {
  enum Level { case panel, inset, dialog, control }
  let level: Level
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  private var radius: CGFloat {
    switch level {
    case .panel: Glass.panelRadius
    case .inset: Glass.insetRadius
    case .dialog: Glass.dialogRadius
    case .control: Glass.controlRadius
    }
  }
  private var isSolid: Bool { reduceTransparency || contrast == .increased }

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    content
      .background { surface(shape) }
      .overlay { edges(shape) }
      .shadow(color: level == .inset || isSolid ? .clear : Glass.shadow, radius: 16, x: 0, y: 8)
  }

  @ViewBuilder
  private func surface(_ shape: RoundedRectangle) -> some View {
    if isSolid {
      shape.fill(level == .inset ? Glass.insetSolid : Glass.solid)
    } else {
      #if compiler(>=6.2)
      if #available(macOS 26.0, *), level != .inset {
        Color.clear.glassEffect(.regular, in: shape)
      } else {
        blurred(shape)
      }
      #else
      blurred(shape)
      #endif
    }
  }

  private func blurred(_ shape: RoundedRectangle) -> some View {
    ZStack {
      shape.fill(.ultraThinMaterial)
      shape.fill(level == .inset ? Glass.insetFill : Glass.fill)
    }
  }

  @ViewBuilder
  private func edges(_ shape: RoundedRectangle) -> some View {
    if isSolid {
      shape.strokeBorder(Glass.solidBorder, lineWidth: contrast == .increased ? 1 : 0.5)
    } else {
      ZStack {
        shape.strokeBorder(Glass.rim, lineWidth: 1)
        shape.inset(by: 1).strokeBorder(
          LinearGradient(colors: [Glass.edge, Glass.edge.opacity(0)], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)),
          lineWidth: 1)
      }
      .allowsHitTesting(false)
    }
  }
}

extension View {
  /// Panels, cards, menus: 20pt radius.
  func glassPanel() -> some View { modifier(GlassSurface(level: .panel)) }
  /// Nested insets: 16pt radius, lighter fill, no shadow.
  func glassInset() -> some View { modifier(GlassSurface(level: .inset)) }
  /// Dialogs and sheets: 24pt radius.
  func glassDialog() -> some View { modifier(GlassSurface(level: .dialog)) }
  /// Small controls: 10pt radius.
  func glassControl() -> some View { modifier(GlassSurface(level: .control)) }
  /// Chrome (toolbars): one translucent strip with the specular edge at the bottom hairline.
  func glassChrome() -> some View { modifier(GlassChrome()) }
  /// Soft brand colour field behind content, over a behind-window blur.
  func glassBackdrop() -> some View { background { GlassBackdrop() } }
}

private struct GlassChrome: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let solid = reduceTransparency || contrast == .increased
    content
      .background {
        if solid {
          Glass.solid
        } else {
          ZStack { Rectangle().fill(.ultraThinMaterial); Glass.fill }
        }
      }
      .overlay(alignment: .bottom) {
        Rectangle().fill(solid ? Glass.solidBorder : Glass.rim).frame(height: 1)
      }
  }
}

/// Behind-window blur used for the window background.
struct VisualEffectBackground: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.blendingMode = .behindWindow
    view.material = .underWindowBackground
    view.state = .followsWindowActiveState
    return view
  }
  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// 2 to 3 large radial blobs of the brand colour. Fixed, no animation, no pattern.
struct GlassBackdrop: View {
  @Environment(\.colorScheme) private var scheme
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    if reduceTransparency || contrast == .increased {
      Glass.base
    } else {
      GeometryReader { proxy in
        let dark = scheme == .dark
        let w = proxy.size.width, h = proxy.size.height
        ZStack {
          Glass.base
          blob(dark ? Glass.brandDark1 : Glass.brandLight1, opacity: dark ? 0.42 : 0.38, at: CGPoint(x: w * 0.12, y: h * 0.08), radius: max(w, h) * 0.7)
          blob(dark ? Glass.brandDark2 : Glass.brandLight2, opacity: dark ? 0.46 : 0.45, at: CGPoint(x: w * 0.92, y: h * 0.3), radius: max(w, h) * 0.65)
          blob(dark ? Glass.brandDark3 : Glass.brandLight3, opacity: dark ? 0.26 : 0.28, at: CGPoint(x: w * 0.3, y: h * 0.95), radius: max(w, h) * 0.7)
        }
      }
      .ignoresSafeArea()
    }
  }

  private func blob(_ color: Color, opacity: Double, at center: CGPoint, radius: CGFloat) -> some View {
    RadialGradient(colors: [color.opacity(opacity), color.opacity(0)], center: .center, startRadius: 0, endRadius: radius)
      .frame(width: radius * 2, height: radius * 2)
      .position(center)
  }
}
