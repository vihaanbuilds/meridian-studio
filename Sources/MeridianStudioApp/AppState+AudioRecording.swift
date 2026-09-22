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
            return "This track already has an audio region — recording onto it would silently replace what plays back, since only a track's most recent audio region is ever heard. Select a different track, or create a new one."
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
        // `PlaybackEngine` only ever plays a track's most recent audio
        // region (`AppState.resolveAudioRegions`), so recording onto a
        // track that already has one wouldn't fail — it would silently
        // drop whatever was there, whether that region came from an
        // earlier take or an import. Block it with a clear message rather
        // than let it happen invisibly.
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
        } catch {
            presentError(error)
        }
    }
}
