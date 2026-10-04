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
    /// offering to add it to the currently selected track. A track's audio
    /// regions do all play together now (trim/split made that necessary —
    /// see `AppState.resolveAudioRegions`), but there's still no UI here for
    /// placing an imported file at a particular beat on an existing track
    /// alongside whatever's already there, so a new track — starting the
    /// import at beat 0 with nothing to collide with — is the simple,
    /// unambiguous choice. Importing onto an existing track at a chosen
    /// position is real, unscoped future work, not something to
    /// half-support here.
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
        _ = waveformBands(for: region)

        // Every other track-creating path in the app selects the new track
        // (see `AppState.addTrack(kind:)`) — mirror that here, both for
        // consistency and so the import is immediately visible rather than
        // silently added behind whatever was already selected.
        selectedTrackIndex = trackIndex
    }
}
