// Sources/MeridianStudioApp/AppState+AudioImport.swift
import AppKit
import AVFoundation
import ProjectModel
import UniformTypeIdentifiers

enum AudioImportError: Error, LocalizedError {
    case projectNotSaved
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .projectNotSaved:
            return "Save this project before importing audio — imported files are copied next to your saved project."
        case .unreadableFile:
            return "This file couldn't be read as audio."
        }
    }
}

extension AppState {
    /// Always creates a new audio track for the imported file, rather than
    /// offering to add it to the currently selected track. `PlaybackEngine`
    /// schedules a track's audio on one shared `AVAudioPlayerNode`, which
    /// only plays a track's most recent audio region — a second region on
    /// the same track would render in the timeline but never be heard.
    /// Every audio track this way holds exactly one region, which keeps
    /// that existing "most recent region" behavior correct rather than
    /// silently wrong. Playing multiple regions on one track together is
    /// real, unscoped future work (it needs more than one player node),
    /// not something to half-support here.
    func importAudio() {
        guard !isRecording else { return }
        guard fileURL != nil else {
            presentError(AudioImportError.projectNotSaved)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        importAudio(from: sourceURL, creatingNewTrackNamed: sourceURL.deletingPathExtension().lastPathComponent)
    }

    private func importAudio(from sourceURL: URL, creatingNewTrackNamed name: String) {
        guard let fileURL else { return }

        let destinationFileName = "\(UUID().uuidString).\(sourceURL.pathExtension)"
        let destinationURL = fileURL.appendingPathComponent("audio").appendingPathComponent(destinationFileName)
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            presentError(error)
            return
        }

        guard let file = try? AVAudioFile(forReading: destinationURL) else {
            try? FileManager.default.removeItem(at: destinationURL)
            presentError(AudioImportError.unreadableFile)
            return
        }
        let durationSeconds = Double(file.length) / file.processingFormat.sampleRate
        guard durationSeconds > 0 else {
            try? FileManager.default.removeItem(at: destinationURL)
            presentError(AudioImportError.unreadableFile)
            return
        }

        // Only create the track once the file is validated — an invalid
        // file must not leave an empty orphan track behind.
        document.addTrack(Track(name: name, kind: .audio))
        let trackIndex = document.project.tracks.count - 1

        let lengthBeats = Tempo.beats(forSeconds: durationSeconds, tempo: document.project.tempo)
        let region = AudioRegion(startBeat: 0, lengthBeats: max(lengthBeats, 0.1), fileName: destinationFileName)
        document.addAudioRegion(region, toTrackAt: trackIndex)

        // Every other track-creating path in the app selects the new track
        // (see `AppState.addTrack(kind:)`) — mirror that here, both for
        // consistency and so the import is immediately visible rather than
        // silently added behind whatever was already selected.
        selectedTrackIndex = trackIndex
    }
}
