// Sources/MeridianStudioApp/AppState+Waveforms.swift
import AudioEngine
import Foundation
import ProjectModel

extension AppState {
    /// Returns cached peaks for `region` if already loaded, and kicks off a
    /// background load (a cached `.peaks` file, or a fresh analysis) if
    /// not. Callers simply re-invoke on every render; the `@Published`
    /// cache write on completion triggers the redraw that shows the
    /// result. Also the single call site used to generate peaks right
    /// after a recording or import finishes — same function, whether this
    /// is a brand-new region or an older one seen for the first time.
    func waveformPeaks(for region: AudioRegion) -> WaveformPeaks? {
        if let cached = waveformCache[region.fileName] { return cached }
        guard waveformLoadsInFlight.insert(region.fileName).inserted, let fileURL else { return nil }
        let audioDirectory = fileURL.appendingPathComponent("audio")
        let audioFileURL = audioDirectory.appendingPathComponent(region.fileName)
        let peaksFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("peaks")
        Task.detached(priority: .utility) {
            let peaks = (try? WaveformPeaks.read(from: peaksFileURL)).flatMap { $0.magnitudes.isEmpty ? nil : $0 }
                ?? (try? WaveformPeaks.analyze(fileURL: audioFileURL))
            guard let peaks else { return }
            try? peaks.write(to: peaksFileURL)
            await MainActor.run { self.waveformCache[region.fileName] = peaks }
        }
        return nil
    }
}
