// Sources/MeridianStudioApp/AppState+Waveforms.swift
import AudioEngine
import AVFoundation
import Foundation
import ProjectModel

extension AppState {
    /// Returns cached bands for `region` if already loaded, and kicks off
    /// a background load (a cached `.bandpeaks` file, or a fresh FFT
    /// analysis) if not. Callers simply re-invoke on every render; the
    /// `@Published` cache write on completion triggers the redraw that
    /// shows the result. Also the single call site used to generate bands
    /// right after a recording or import finishes — same function,
    /// whether this is a brand-new region or an older one seen for the
    /// first time (including one from before this milestone, whose
    /// `.peaks` file this never reads).
    func waveformBands(for region: AudioRegion) -> WaveformBands? {
        if let cached = bandCache[region.fileName] { return cached }
        guard let fileURL, bandLoadsInFlight.insert(region.fileName).inserted else { return nil }
        let audioDirectory = fileURL.appendingPathComponent("audio")
        let audioFileURL = audioDirectory.appendingPathComponent(region.fileName)
        let bandsFileURL = audioFileURL.deletingPathExtension().appendingPathExtension("bandpeaks")
        Task.detached(priority: .utility) {
            let bands = (try? WaveformBands.read(from: bandsFileURL)).flatMap { $0.low.isEmpty ? nil : $0 }
                ?? (try? WaveformBands.analyze(fileURL: audioFileURL))
            guard let bands else { return }
            try? bands.write(to: bandsFileURL)
            // One extra cheap AVAudioFile header read (not a full re-analysis),
            // whether `bands` came from the cache or a fresh analyze — needed
            // for waveform slicing and the trim-handle clamp, neither of which
            // the `.bandpeaks` cache file itself stores.
            let file = try? AVAudioFile(forReading: audioFileURL)
            let sampleRate = file?.processingFormat.sampleRate
            let durationSeconds = file.map { Double($0.length) / $0.processingFormat.sampleRate }
            await MainActor.run {
                self.bandCache[region.fileName] = bands
                if let sampleRate { self.sampleRateCache[region.fileName] = sampleRate }
                if let durationSeconds { self.fileDurationSecondsCache[region.fileName] = durationSeconds }
            }
        }
        return nil
    }
}
