// Sources/MeridianCompanionApp/LevelMeterView.swift
import SwiftUI

/// A minimal horizontal bar meter — a deliberate duplicate of
/// MeridianStudioApp's LevelMeterView, not an import: MeridianCompanionApp
/// cannot depend on MeridianStudioApp (see
/// docs/superpowers/specs/2026-09-20-two-app-architecture-design.md,
/// Section 2 — this handful of duplicated lines is the accepted cost).
struct LevelMeterView: View {
    let level: Float

    private let width: CGFloat = 160
    private let height: CGFloat = 20

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.2))
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: width * CGFloat(min(max(level, 0), 1)))
        }
        .frame(width: width, height: height)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(level > 0.05 ? "Sound detected" : "Silent")
    }
}
