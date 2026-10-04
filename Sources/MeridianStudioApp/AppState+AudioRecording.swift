// Sources/MeridianStudioApp/AppState+AudioRecording.swift
import AVFoundation
import ProjectModel
import AudioEngine

enum AudioRecordingError: Error, LocalizedError {
    case projectNotSaved
    case trackAlreadyHasAudio

    var errorDescription: String? {
        switch self {
        case .projectNotSaved:
            return "Save this project before recording audio — audio takes are written to a file next to your saved project."
        case .trackAlreadyHasAudio:
            return "This track already has an audio region — a new recording would start at beat 0 and overlap it. Select a different track, or create a new one."
        }
    }
}

extension AppState {
    private static let inProgressAudioFileName = ".recording-in-progress.wav"

    func startAudioRecording() {
        guard let fileURL else {
            presentError(AudioRecordingError.projectNotSaved)
            return
        }
        // Every region on a track plays (`AppState.resolveAudioRegions`
        // resolves all of them, not just the most recent), but a new
        // recording always starts at beat 0 — there's no UI yet to record
        // into a gap elsewhere on the track — so recording onto a track
        // that already has audio would overlap, not replace, whatever was
        // there. Block it with a clear message rather than let the overlap
        // happen invisibly.
        if document.project.tracks.indices.contains(selectedTrackIndex),
           !document.project.tracks[selectedTrackIndex].audioRegions.isEmpty {
            presentError(AudioRecordingError.trackAlreadyHasAudio)
            return
        }
        let workingURL = fileURL.appendingPathComponent("audio").appendingPathComponent(Self.inProgressAudioFileName)
        do {
            try audioRecorder.start(to: workingURL)
            recordingClock.tempo = document.project.tempo
            isRecording = true
        } catch {
            presentError(error)
        }
    }

    func stopAudioRecording() {
        isRecording = false
        guard let workingURL = audioRecorder.stop(), let fileURL else { return }
        guard let file = try? AVAudioFile(forReading: workingURL) else { return }
        let durationSeconds = Double(file.length) / file.processingFormat.sampleRate
        guard durationSeconds > 0 else {
            try? FileManager.default.removeItem(at: workingURL)
            return
        }
        let lengthBeats = Tempo.beats(forSeconds: durationSeconds, tempo: recordingClock.tempo)
        let region = AudioRegion(startBeat: 0, lengthBeats: max(lengthBeats, 0.1), fileName: "\(UUID().uuidString).wav")
        let finalURL = fileURL.appendingPathComponent("audio").appendingPathComponent(region.fileName)
        do {
            try FileManager.default.moveItem(at: workingURL, to: finalURL)
            document.addAudioRegion(region, toTrackAt: selectedTrackIndex)
            _ = waveformBands(for: region)
        } catch {
            presentError(error)
        }
    }
}
