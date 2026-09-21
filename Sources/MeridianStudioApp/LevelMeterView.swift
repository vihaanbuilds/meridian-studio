// Sources/MeridianStudioApp/LevelMeterView.swift
import SwiftUI

/// A minimal horizontal bar meter — not a calibrated dB scale, not peak-hold,
/// just "how loud is it right now." A real meter is later polish; this exists
/// so input/output has *some* visual confirmation before waveform rendering
/// ships, the same role Phase 1's live MIDI-note highlighting served before
/// full piano-roll editing existed.
struct LevelMeterView: View {
    let label: String
    let level: Float

    private let width: CGFloat = 60
    private let height: CGFloat = 8

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.2))
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: width * CGFloat(min(max(level, 0), 1)))
            }
            .frame(width: width, height: height)
        }
    }
}
