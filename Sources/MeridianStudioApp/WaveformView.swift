// Sources/MeridianStudioApp/WaveformView.swift
import AudioEngine
import SwiftUI

/// Renders `bands` as three overlaid, translucent mirrored-bar traces —
/// low (bass), mid (vocals/harmony), high (cymbals/air) — stretched to
/// fill the view's width. Not a spectrogram: no vertical frequency axis,
/// just three pre-summed energy traces layered on the same timeline.
struct WaveformView: View {
    let bands: WaveformBands

    private static let lowColor = Color(red: 1.0, green: 0.37, blue: 0.34)
    private static let midColor = Color(red: 1.0, green: 0.85, blue: 0.24)
    private static let highColor = Color(red: 0.44, green: 0.89, blue: 1.0)

    var body: some View {
        Canvas { context, size in
            draw(bands.low, color: Self.lowColor, in: context, size: size)
            draw(bands.mid, color: Self.midColor, in: context, size: size)
            draw(bands.high, color: Self.highColor, in: context, size: size)
        }
    }

    private func draw(_ magnitudes: [Float], color: Color, in context: GraphicsContext, size: CGSize) {
        guard !magnitudes.isEmpty else { return }
        let midY = size.height / 2
        let barWidth = size.width / CGFloat(magnitudes.count)
        var path = Path()
        for (index, magnitude) in magnitudes.enumerated() {
            let x = CGFloat(index) * barWidth
            let barHeight = CGFloat(min(magnitude, 1)) * midY
            path.addRect(CGRect(x: x, y: midY - barHeight, width: max(barWidth, 0.5), height: barHeight * 2))
        }
        context.fill(path, with: .color(color.opacity(0.6)))
    }
}
