// Sources/MeridianStudioApp/WaveformView.swift
import AudioEngine
import SwiftUI

/// Renders `peaks` as a mirrored bar per bucket, stretched to fill the
/// view's width — one combined magnitude per bucket, not per-channel.
struct WaveformView: View {
    let peaks: WaveformPeaks

    var body: some View {
        Canvas { context, size in
            guard !peaks.magnitudes.isEmpty else { return }
            let midY = size.height / 2
            let barWidth = size.width / CGFloat(peaks.magnitudes.count)
            var path = Path()
            for (index, magnitude) in peaks.magnitudes.enumerated() {
                let x = CGFloat(index) * barWidth
                let barHeight = CGFloat(min(magnitude, 1)) * midY
                path.addRect(CGRect(x: x, y: midY - barHeight, width: max(barWidth, 0.5), height: barHeight * 2))
            }
            context.fill(path, with: .color(.white.opacity(0.85)))
        }
    }
}
