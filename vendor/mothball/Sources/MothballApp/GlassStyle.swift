import SwiftUI

/// Liquid Glass adoption helpers (Apple design language, OS 26 generation).
/// Same idiom as Zoint's GlassStyle.swift; kept per-app because it is pure
/// UI styling with different fallback floors (this app deploys to macOS 13).
/// macOS 27 "Golden Gate" refinements arrive automatically once the glass
/// idioms are adopted, so nothing here is version-27-specific.
extension View {
    /// Card chrome: Liquid Glass on macOS 26+, quiet material below.
    @ViewBuilder
    func liquidGlassCard(cornerRadius: CGFloat = 10) -> some View {
#if compiler(>=6.2)
        // Compile-time guard: glassEffect/glass styles need the macOS 26 SDK
        // (Xcode 26 / Swift 6.2+); older toolchains build only the fallback.
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
#else
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
#endif
    }

    /// Small status chip: capsule glass on macOS 26+, thin material below.
    @ViewBuilder
    func liquidGlassChip() -> some View {
#if compiler(>=6.2)
        // Compile-time guard: glassEffect/glass styles need the macOS 26 SDK
        // (Xcode 26 / Swift 6.2+); older toolchains build only the fallback.
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: .capsule)
        } else {
            self.background(.thinMaterial, in: Capsule())
        }
#else
            self.background(.thinMaterial, in: Capsule())
#endif
    }

    /// Tinted chip for severity badges: tinted glass on macOS 26+, tinted
    /// capsule below. Tint stays translucent so the label keeps contrast.
    @ViewBuilder
    func liquidTintedChip(_ tint: Color) -> some View {
#if compiler(>=6.2)
        // Compile-time guard: glassEffect/glass styles need the macOS 26 SDK
        // (Xcode 26 / Swift 6.2+); older toolchains build only the fallback.
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(tint.opacity(0.35)), in: .capsule)
        } else {
            self.background(tint.opacity(0.18), in: Capsule())
        }
#else
            self.background(tint.opacity(0.18), in: Capsule())
#endif
    }

    /// Caution banner surface: warning-tinted glass on macOS 26+.
    @ViewBuilder
    func liquidCautionCard(cornerRadius: CGFloat = 10) -> some View {
#if compiler(>=6.2)
        // Compile-time guard: glassEffect/glass styles need the macOS 26 SDK
        // (Xcode 26 / Swift 6.2+); older toolchains build only the fallback.
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular.tint(.orange.opacity(0.35)), in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: cornerRadius))
        }
#else
            self.background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: cornerRadius))
#endif
    }

    /// Primary action: glass-prominent on macOS 26+, bordered-prominent below.
    @ViewBuilder
    func liquidProminentActionStyle() -> some View {
#if compiler(>=6.2)
        // Compile-time guard: glassEffect/glass styles need the macOS 26 SDK
        // (Xcode 26 / Swift 6.2+); older toolchains build only the fallback.
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
#else
            self.buttonStyle(.borderedProminent)
#endif
    }

    /// Secondary action: glass on macOS 26+, bordered below.
    @ViewBuilder
    func liquidSecondaryActionStyle() -> some View {
#if compiler(>=6.2)
        // Compile-time guard: glassEffect/glass styles need the macOS 26 SDK
        // (Xcode 26 / Swift 6.2+); older toolchains build only the fallback.
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
#else
            self.buttonStyle(.bordered)
#endif
    }
}
