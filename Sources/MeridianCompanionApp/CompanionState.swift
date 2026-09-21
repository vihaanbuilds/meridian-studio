// Sources/MeridianCompanionApp/CompanionState.swift
import AVFoundation
import Combine
import CoreMIDI
import Foundation
import ProjectModel
import AudioEngine

@MainActor
final class CompanionState: ObservableObject {
    @Published private(set) var isRecording = false
    /// nil while idle; set to the detected modality for the duration of a
    /// session. Drives which of `level`/`isNoteSounding` the UI should show
    /// (Task 3).
    @Published private(set) var activeTrackKind: TrackKind?
    /// Meaningful only while `activeTrackKind == .audio`; 0 otherwise.
    @Published private(set) var level: Float = 0
    /// A live visual cue maintained continuously, recording or not — same
    /// role `MeridianStudioApp.AppState.liveNotes` plays, simplified here to
    /// "is anything currently held" since this app has no piano roll to show
    /// individual pitches in.
    @Published private(set) var isNoteSounding = false
    @Published private(set) var sessions: [SessionSummary] = []
    @Published var lastError: String?

    private let midiInput = CoreMIDIInput()
    private let playbackEngine = PlaybackEngine()
    private let audioRecorder: AudioRecorder
    private let midiRecorder: MIDIRecorder
    private let recordingClock = RecordingClock()
    /// The modality actually in use for the in-progress session — set
    /// alongside `activeTrackKind` at Start, read internally at Stop.
    /// `activeTrackKind` is nil-when-idle for the UI; this is always a
    /// concrete `TrackKind` so `stopSession()`'s switch doesn't need to
    /// unwrap an optional it knows is never nil while `isRecording` is true.
    private var currentTrackKind: TrackKind = .midi
    private var currentProject: Project?
    private var currentBundleURL: URL?
    private var heldPitches: Set<UInt8> = []
    private var pollTimer: Timer?

    private static let queuePollInterval: TimeInterval = 0.01
    private static let audioFileName = "take.wav"

    init() {
        audioRecorder = AudioRecorder(engine: playbackEngine.engine)
        midiRecorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { [recordingClock] in
            recordingClock.beatsElapsed()
        }))
        do {
            try midiInput.start()
        } catch {
            print("MIDI input unavailable: \(error)")
        }
        do {
            try playbackEngine.start()
        } catch {
            print("Playback engine unavailable: \(error)")
        }
        startQueuePolling()
        refreshSessionHistory()
    }

    // A `@MainActor` class cannot touch isolated stored properties from its
    // nonisolated `deinit`, so the timer tears itself down instead — same
    // pattern `MeridianStudioApp.AppState.startQueuePolling()` uses.
    private func startQueuePolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.queuePollInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        drainMIDIQueue()
        if isRecording, activeTrackKind == .audio {
            level = audioRecorder.level
        }
    }

    private func drainMIDIQueue() {
        for message in midiInput.queue.drain() {
            let event = MIDIMessageParser.parse(message)
            updateHeldPitches(with: event)
            if isRecording, activeTrackKind == .midi {
                midiRecorder.handle(event)
            }
        }
        isNoteSounding = !heldPitches.isEmpty
    }

    private func updateHeldPitches(with event: ParsedMIDIEvent) {
        switch event {
        case .noteOn(let pitch, _, _):
            heldPitches.insert(pitch)
        case .noteOff(let pitch, _):
            heldPitches.remove(pitch)
        case .other:
            break
        }
    }

    var hasMIDIDevice: Bool {
        MIDIGetNumberOfSources() > 0
    }

    func startSession() {
        guard !isRecording else { return }
        let kind: TrackKind = hasMIDIDevice ? .midi : .audio
        let sessionsDirectory = SessionLibrary.sessionsDirectory()
        let bundleURL = SessionLibrary.bundleURL(for: Date(), in: sessionsDirectory)
        let project = Project(tracks: [Track(name: "Session", kind: kind)])
        do {
            try ProjectStore.save(project, to: bundleURL)
        } catch {
            lastError = error.localizedDescription
            return
        }
        currentProject = project
        currentBundleURL = bundleURL
        currentTrackKind = kind

        switch kind {
        case .midi:
            midiRecorder.reset()
            recordingClock.tempo = project.tempo
            recordingClock.startDate = Date()
        case .audio:
            let workingURL = bundleURL.appendingPathComponent("audio").appendingPathComponent(Self.audioFileName)
            do {
                try audioRecorder.start(to: workingURL)
            } catch {
                lastError = error.localizedDescription
                try? FileManager.default.removeItem(at: bundleURL)
                currentProject = nil
                currentBundleURL = nil
                return
            }
        }
        activeTrackKind = kind
        isRecording = true
    }

    func stopSession() {
        guard isRecording, var project = currentProject, let bundleURL = currentBundleURL else { return }

        switch currentTrackKind {
        case .midi:
            // Drain first, while `isRecording` is still true and `startDate`
            // is still set — mirrors `MeridianStudioApp.AppState.stopRecording()`'s
            // exact ordering: draining after flipping `isRecording` would
            // route the take's tail to `isNoteSounding` only, never the
            // recorder, and `RecordingClock.beatsElapsed()` returns 0 once
            // `startDate` is nil.
            drainMIDIQueue()
            let finalBeat = recordingClock.beatsElapsed()
            isRecording = false
            midiRecorder.finalize(atBeat: finalBeat)
            recordingClock.startDate = nil
            let notes = midiRecorder.recordedNotes
            guard !notes.isEmpty else {
                try? FileManager.default.removeItem(at: bundleURL)
                resetSessionState()
                refreshSessionHistory()
                return
            }
            let lengthBeats = ceil(notes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0)
            project.tracks[0].regions = [MIDIRegion(startBeat: 0, lengthBeats: max(lengthBeats, 1), notes: notes)]
        case .audio:
            isRecording = false
            guard let workingURL = audioRecorder.stop(),
                  let file = try? AVAudioFile(forReading: workingURL) else {
                try? FileManager.default.removeItem(at: bundleURL)
                resetSessionState()
                refreshSessionHistory()
                return
            }
            let durationSeconds = Double(file.length) / file.processingFormat.sampleRate
            guard durationSeconds > 0 else {
                try? FileManager.default.removeItem(at: bundleURL)
                resetSessionState()
                refreshSessionHistory()
                return
            }
            let lengthBeats = Tempo.beats(forSeconds: durationSeconds, tempo: project.tempo)
            project.tracks[0].audioRegions = [
                AudioRegion(startBeat: 0, lengthBeats: max(lengthBeats, 0.1), fileName: Self.audioFileName)
            ]
        }

        do {
            try ProjectStore.save(project, to: bundleURL)
        } catch {
            lastError = error.localizedDescription
        }
        resetSessionState()
        refreshSessionHistory()
    }

    private func resetSessionState() {
        currentProject = nil
        currentBundleURL = nil
        activeTrackKind = nil
        level = 0
    }

    func playLastSession() {
        guard let last = sessions.last else { return }
        do {
            let project = try ProjectStore.load(from: last.id)
            guard let track = project.tracks.first else { return }
            switch track.kind {
            case .midi:
                playbackEngine.play(regions: track.regions, audioRegions: [], tempo: project.tempo)
            case .audio:
                guard let region = track.audioRegions.first else { return }
                let url = last.id.appendingPathComponent("audio").appendingPathComponent(region.fileName)
                playbackEngine.play(regions: [], audioRegions: [(url: url, startBeat: region.startBeat)], tempo: project.tempo)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshSessionHistory() {
        do {
            sessions = try SessionLibrary.loadHistory(from: SessionLibrary.sessionsDirectory())
        } catch {
            lastError = error.localizedDescription
        }
    }
}
