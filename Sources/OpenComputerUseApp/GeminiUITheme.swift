import Foundation
import AppKit
import SwiftUI
import OCUCore

// MARK: - Google Gemini Design System (Desktop & Mobile Live Aesthetics)

public enum GeminiPalette {
    // Deep Obsidian & Starlight Surfaces (Gemini Web / Mobile Dark Theme)
    public static let canvasDeep = Color(red: 0.051, green: 0.059, blue: 0.082)       // #0D0F15
    public static let surfaceCard = Color(red: 0.094, green: 0.106, blue: 0.145)      // #181B25
    public static let surfaceElevated = Color(red: 0.125, green: 0.141, blue: 0.192)  // #202431
    public static let cardBorderSubtle = Color.white.opacity(0.085)

    // Signature Google Gemini Aurora Stops
    public static let skyBlue = Color(red: 0.40, green: 0.72, blue: 1.00)             // #66B8FF
    public static let blue = Color(red: 0.259, green: 0.522, blue: 0.957)             // #4285F4 (Google Gemini Blue)
    public static let indigo = Color(red: 0.455, green: 0.420, blue: 0.945)           // #746BF1
    public static let violet = Color(red: 0.608, green: 0.447, blue: 0.796)           // #9B72CB (Gemini Violet)
    public static let coral = Color(red: 0.851, green: 0.396, blue: 0.439)            // #D96570 (Gemini Coral Rose)
    public static let peach = Color(red: 0.957, green: 0.612, blue: 0.408)            // #F49C68
    public static let mint = Color(red: 0.32, green: 0.92, blue: 0.75)
    public static let mintGreen = mint

    // High-contrast readable text tokens on dark obsidian surfaces
    public static let textPrimary = Color.white
    public static let textSecondary = Color(red: 0.78, green: 0.82, blue: 0.90)
    public static let textMuted = Color(red: 0.62, green: 0.67, blue: 0.78)
    public static let textSkyBright = Color(red: 0.64, green: 0.85, blue: 1.00)
    public static let textMintBright = Color(red: 0.44, green: 0.98, blue: 0.80)
    public static let textVioletBright = Color(red: 0.80, green: 0.68, blue: 0.98)
    public static let textCoralBright = Color(red: 0.98, green: 0.56, blue: 0.60)

    /// Strips leading emoji characters so text pairs cleanly with vector SF Symbols & GeminiSparkleIcon.
    public static func cleanStatusText(_ raw: String) -> String {
        var scalars = raw.unicodeScalars[...]
        while let first = scalars.first {
            let isEmojiLike = first.properties.isEmojiPresentation
                || (first.value >= 0x2600 && first.value <= 0x27BF)
                || (first.value >= 0x1F300 && first.value <= 0x1FAFF)
                || first.value == 0xFE0F
            if isEmojiLike || CharacterSet.whitespaces.contains(first) {
                scalars = scalars.dropFirst()
            } else {
                break
            }
        }
        let cleaned = String(scalars)
        return cleaned.isEmpty ? raw : cleaned
    }

    public static var auroraGradient: LinearGradient {
        LinearGradient(
            colors: [skyBlue, blue, violet, coral],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public static var auroraHorizontalGradient: LinearGradient {
        LinearGradient(
            colors: [blue, violet, coral],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    public static var subtleBorderGradient: LinearGradient {
        LinearGradient(
            colors: [
                skyBlue.opacity(0.55),
                violet.opacity(0.45),
                coral.opacity(0.40),
                Color.white.opacity(0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Iconic 4-Point Curved Gemini Sparkle Shape (✦) & Unified "Cursor + Sparkles" Brand Icon

public struct GeminiSparkleShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let cx = rect.midX
        let cy = rect.midY
        // Control point inset towards center creates the signature concave 4-point Gemini star
        let insetX = w * 0.14
        let insetY = h * 0.14

        var path = Path()
        // Top point
        path.move(to: CGPoint(x: cx, y: rect.minY))
        // Curve to Right point
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: cy),
            control: CGPoint(x: cx + insetX, y: cy - insetY)
        )
        // Curve to Bottom point
        path.addQuadCurve(
            to: CGPoint(x: cx, y: rect.maxY),
            control: CGPoint(x: cx + insetX, y: cy + insetY)
        )
        // Curve to Left point
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: cy),
            control: CGPoint(x: cx - insetX, y: cy + insetY)
        )
        // Curve back to Top point
        path.addQuadCurve(
            to: CGPoint(x: cx, y: rect.minY),
            control: CGPoint(x: cx - insetX, y: cy - insetY)
        )
        path.closeSubpath()
        return path
    }
}

/// Slender, compact tailless aerodynamic cursor blade (2:3 aspect ratio, ~54% of icon height)
/// matching our real `VirtualCursorArrowShape` proportions, surrounded by 3 orbiting Gemini sparkles.
public struct GeminiCursorIconBladeShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        // Sharp top-left apex
        path.move(to: CGPoint(x: rect.minX + w * 0.26, y: rect.minY + h * 0.22))
        // Slender left blade edge (nearly vertical, matching VirtualCursorArrowShape)
        path.addLine(to: CGPoint(x: rect.minX + w * 0.295, y: rect.minY + h * 0.78))
        // Deep swept inner chevron notch (keeps both wings thin and sharp)
        path.addLine(to: CGPoint(x: rect.minX + w * 0.425, y: rect.minY + h * 0.575))
        // Sleek right wingtip (2:3 width-to-height ratio)
        path.addLine(to: CGPoint(x: rect.minX + w * 0.62, y: rect.minY + h * 0.515))
        path.closeSubpath()
        return path
    }
}

/// Unified "Cursor + Orbiting Sparkles (星芒围绕)" Brand Icon View:
/// Features a compact, slender tailless Cursor in the center surrounded by 3 orbiting 4-point Gemini sparkles.
public struct GeminiSparkleIcon: View {
    public var size: CGFloat = 18
    public var showHalo: Bool = true

    public init(size: CGFloat = 18, showHalo: Bool = true) {
        self.size = size
        self.showHalo = showHalo
    }

    public var body: some View {
        ZStack {
            if showHalo {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                GeminiPalette.blue.opacity(0.55),
                                GeminiPalette.violet.opacity(0.35),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.95
                        )
                    )
                    .frame(width: size * 1.9, height: size * 1.9)
                    .blur(radius: 2)
            }

            ZStack(alignment: .topLeading) {
                // 1. Central Slender Tailless Cursor Blade
                GeminiCursorIconBladeShape()
                    .fill(GeminiPalette.auroraGradient)
                    .overlay(
                        GeminiCursorIconBladeShape()
                            .stroke(Color.white.opacity(0.72), lineWidth: max(0.45, size * 0.035))
                    )

                // 2. Orbiting Sparkle #1 (Top-Right — Primary Companion Star)
                GeminiSparkleShape()
                    .fill(
                        LinearGradient(
                            colors: [GeminiPalette.skyBlue, GeminiPalette.violet, GeminiPalette.coral],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size * 0.32, height: size * 0.32)
                    .offset(x: size * 0.63, y: size * 0.06)

                // 3. Orbiting Sparkle #2 (Bottom-Right — Secondary Star below Wing)
                GeminiSparkleShape()
                    .fill(
                        LinearGradient(
                            colors: [GeminiPalette.violet, GeminiPalette.coral, GeminiPalette.skyBlue],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size * 0.24, height: size * 0.24)
                    .offset(x: size * 0.60, y: size * 0.67)

                // 4. Orbiting Sparkle #3 (Left — Accent Star flanking the Left Blade)
                GeminiSparkleShape()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: size * 0.21, height: size * 0.21)
                    .offset(x: size * 0.02, y: size * 0.34)
            }
            .frame(width: size, height: size)
            .shadow(color: GeminiPalette.blue.opacity(0.65), radius: 4, x: 0, y: 0)
        }
        .frame(width: size, height: size)
    }
}

/// Renders the unified "Slender Cursor + 3 Orbiting Sparkles" icon as a native AppKit template `NSImage` for the macOS MenuBar (`NSStatusItem`).
public enum GeminiBrandIconRenderer {
    public static func statusBarImage(pointSize: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let w = rect.width
            let h = rect.height

            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setFillColor(NSColor.black.cgColor)

            // 1. Central Slender Tailless Cursor Blade (2:3 aspect ratio, ~56% height)
            let cursorPath = CGMutablePath()
            cursorPath.move(to: CGPoint(x: w * 0.26, y: h * 0.22))
            cursorPath.addLine(to: CGPoint(x: w * 0.295, y: h * 0.78))
            cursorPath.addLine(to: CGPoint(x: w * 0.425, y: h * 0.575))
            cursorPath.addLine(to: CGPoint(x: w * 0.62, y: h * 0.515))
            cursorPath.closeSubpath()
            ctx.addPath(cursorPath)
            ctx.fillPath()

            // Helper to draw a concave 4-point Gemini sparkle star in flipped coordinates
            func addSparkle(center: CGPoint, radius: CGFloat) {
                let inset = radius * 0.23
                let p = CGMutablePath()
                p.move(to: CGPoint(x: center.x, y: center.y - radius))
                p.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + inset, y: center.y - inset))
                p.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: center.x + inset, y: center.y + inset))
                p.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - inset, y: center.y + inset))
                p.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: CGPoint(x: center.x - inset, y: center.y - inset))
                p.closeSubpath()
                ctx.addPath(p)
                ctx.fillPath()
            }

            // 2. Orbiting Sparkle #1 (Top-Right)
            addSparkle(center: CGPoint(x: w * 0.79, y: h * 0.22), radius: w * 0.16)

            // 3. Orbiting Sparkle #2 (Bottom-Right)
            addSparkle(center: CGPoint(x: w * 0.72, y: h * 0.79), radius: w * 0.12)

            // 4. Orbiting Sparkle #3 (Left)
            addSparkle(center: CGPoint(x: w * 0.125, y: h * 0.44), radius: w * 0.105)

            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Ambient Aurora Background Mesh (Gemini Desktop & Mobile Header Glow)

public struct GeminiAmbientBackdropView: View {
    public var intensity: Double = 1.0

    public init(intensity: Double = 1.0) {
        self.intensity = intensity
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                GeminiPalette.canvasDeep

                // Top-left Gemini Blue-Violet Aurora Orb
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                GeminiPalette.blue.opacity(0.24 * intensity),
                                GeminiPalette.indigo.opacity(0.12 * intensity),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: max(180, geo.size.width * 0.42)
                        )
                    )
                    .frame(width: max(280, geo.size.width * 0.65), height: max(280, geo.size.width * 0.65))
                    .position(x: geo.size.width * 0.18, y: 20)
                    .blur(radius: 45)

                // Top-right Gemini Violet-Coral Aurora Orb
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                GeminiPalette.violet.opacity(0.22 * intensity),
                                GeminiPalette.coral.opacity(0.14 * intensity),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 8,
                            endRadius: max(160, geo.size.width * 0.38)
                        )
                    )
                    .frame(width: max(260, geo.size.width * 0.58), height: max(260, geo.size.width * 0.58))
                    .position(x: geo.size.width * 0.82, y: 40)
                    .blur(radius: 50)

                // Subtle bottom-center starlight reflection
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [
                                GeminiPalette.skyBlue.opacity(0.10 * intensity),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 4,
                            endRadius: max(140, geo.size.width * 0.35)
                        )
                    )
                    .frame(width: geo.size.width * 0.7, height: 160)
                    .position(x: geo.size.width * 0.5, y: geo.size.height)
                    .blur(radius: 40)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Unified Gemini Pointer (Shared Across Desktop Virtual Cursor & Mini PiP Preview)

/// Sleek, tailless aerodynamic Gemini pointer silhouette anchored at `(0, 0)`.
public struct VirtualCursorArrowShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        // Sharp precision apex at (0, 0)
        path.move(to: CGPoint(x: 0, y: 0))
        // Left aerodynamic blade edge
        path.addLine(to: CGPoint(x: 1.4, y: 21.8))
        // Swept inner chevron notch (tailless futuristic profile)
        path.addLine(to: CGPoint(x: 7.6, y: 15.0))
        // Right high-speed wingtip
        path.addLine(to: CGPoint(x: 17.8, y: 12.6))
        path.closeSubpath()
        return path
    }
}

/// Inner crystalline energy core facet inside the Gemini pointer.
public struct VirtualCursorCoreFacetShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 2.1, y: 3.2))
        path.addLine(to: CGPoint(x: 2.9, y: 14.4))
        path.addLine(to: CGPoint(x: 6.9, y: 10.7))
        path.addLine(to: CGPoint(x: 11.6, y: 9.5))
        path.closeSubpath()
        return path
    }
}

/// Unified Google Gemini Pointer View used identically on both the Desktop Virtual Cursor Window
/// and inside the Mini PiP Live Preview Window.
/// The pointer tip is anchored at `(0, 0)` in its local coordinate space.
public struct UnifiedGeminiCursorView: View {
    public let isPressed: Bool
    public let tiltDegrees: Double
    public let scale: CGFloat

    public init(
        isPressed: Bool,
        tiltDegrees: Double = 0.0,
        scale: CGFloat = 1.0
    ) {
        self.isPressed = isPressed
        self.tiltDegrees = tiltDegrees
        self.scale = scale
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // 1. Ambient Gemini Aurora Tip Halo (Centered at tip (0, 0))
            Circle()
                .fill(
                    RadialGradient(
                        colors: isPressed
                            ? [
                                GeminiPalette.coral.opacity(0.80),
                                GeminiPalette.violet.opacity(0.55),
                                GeminiPalette.blue.opacity(0.25),
                                Color.clear
                            ]
                            : [
                                GeminiPalette.skyBlue.opacity(0.65),
                                GeminiPalette.violet.opacity(0.40),
                                Color.clear
                            ],
                        center: .center,
                        startRadius: 0,
                        endRadius: isPressed ? 16 : 12
                    )
                )
                .frame(width: isPressed ? 32 : 24, height: isPressed ? 32 : 24)
                .offset(x: isPressed ? -16 : -12, y: isPressed ? -16 : -12)

            // 2. Press Shockwave Ring (Centered at tip (0, 0))
            if isPressed {
                Circle()
                    .stroke(GeminiPalette.auroraGradient, lineWidth: 2.2)
                    .background(Circle().fill(GeminiPalette.violet.opacity(0.22)))
                    .frame(width: 26, height: 26)
                    .shadow(color: GeminiPalette.coral.opacity(0.75), radius: 6)
                    .offset(x: -13, y: -13)
            }

            // 3. Unified Gemini Aurora Cyber-Blade (Apex at (0, 0))
            ZStack(alignment: .topLeading) {
                // Outer Aurora Blade Fill
                VirtualCursorArrowShape()
                    .fill(
                        LinearGradient(
                            colors: isPressed
                                ? [GeminiPalette.peach, GeminiPalette.coral, GeminiPalette.violet, GeminiPalette.blue]
                                : [GeminiPalette.skyBlue, GeminiPalette.blue, GeminiPalette.violet, GeminiPalette.coral],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Inner Crystalline Starlight Facet
                VirtualCursorCoreFacetShape()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.95),
                                GeminiPalette.skyBlue.opacity(0.70),
                                GeminiPalette.violet.opacity(0.45)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                // Crisp Pearlescent Specular Outline (high contrast on both light & dark apps)
                VirtualCursorArrowShape()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white,
                                Color(red: 0.88, green: 0.84, blue: 1.00)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 1.45, lineCap: .round, lineJoin: .round)
                    )

                // Tiny Gemini 4-Point Sparkle Glint near the Wing
                GeminiSparkleShape()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 5.5, height: 5.5)
                    .offset(x: 4.2, y: 6.2)
            }
            .frame(width: 20, height: 24)
            // Grounding dark shadow for crisp visibility over white UI (e.g. WeChat) + Gemini Aurora bloom
            .shadow(color: Color.black.opacity(0.50), radius: 2.5, x: 0, y: 1.2)
            .shadow(color: GeminiPalette.blue.opacity(0.75), radius: 6, x: 0, y: 0)
            .shadow(color: GeminiPalette.violet.opacity(0.55), radius: 10, x: 1, y: 2)
            .scaleEffect((isPressed ? 0.84 : 1.0) * scale, anchor: .topLeading)
            .rotationEffect(.degrees(tiltDegrees), anchor: .topLeading)
        }
    }
}
