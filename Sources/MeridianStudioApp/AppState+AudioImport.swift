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
    func importAudio() {
        // Same hazard class `selectTrack(at:)`/`addTrack()`/`removeTrack(at:)`
        // already guard against: importing mutates `document.project.tracks`,
        // and doing that mid-take risks the armed track's index or content
        // shifting under a recording that reads `selectedTrackIndex` at Stop.
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

        if document.project.tracks.indices.contains(selectedTrackIndex),
           document.project.tracks[selectedTrackIndex].kind == .audio {
            presentImportTargetChoice(for: sourceURL)
        } else {
            importAudio(from: sourceURL, creatingNewTrackNamed: sourceURL.deletingPathExtension().lastPathComponent)
        }
    }

    private func presentImportTargetChoice(for sourceURL: URL) {
        let trackName = document.project.tracks[selectedTrackIndex].name
        let alert = NSAlert()
        alert.messageText = "Import Audio"
        alert.informativeText = "Add this file to the selected track, or create a new track for it?"
        alert.addButton(withTitle: "Add to “\(trackName)”")
        alert.addButton(withTitle: "Create New Track")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            importAudio(from: sourceURL, toTrackAt: selectedTrackIndex)
        default:
            importAudio(from: sourceURL, creatingNewTrackNamed: sourceURL.deletingPathExtension().lastPathComponent)
        }
    }

    private func importAudio(from sourceURL: URL, creatingNewTrackNamed name: String) {
        document.addTrack(Track(name: name, kind: .audio))
        importAudio(from: sourceURL, toTrackAt: document.project.tracks.count - 1)
    }

    private func importAudio(from sourceURL: URL, toTrackAt trackIndex: Int) {
        guard let fileURL else { return }
        guard document.project.tracks.indices.contains(trackIndex) else { return }

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

        let track = document.project.tracks[trackIndex]
        let startBeat = track.audioRegions.map { $0.startBeat + $0.lengthBeats }.max() ?? 0
        let lengthBeats = Tempo.beats(forSeconds: durationSeconds, tempo: document.project.tempo)
        let region = AudioRegion(startBeat: startBeat, lengthBeats: max(lengthBeats, 0.1), fileName: destinationFileName)
        document.addAudioRegion(region, toTrackAt: trackIndex)
    }
}
