// Sources/MeridianStudioApp/AppState.swift
import Combine
import Foundation
import ProjectModel
import MIDIEngine

@MainActor
final class AppState: ObservableObject {
    @Published var document: ProjectDocument {
        didSet { bindDocument() }
    }
    @Published var isPlaying = false
    @Published var isRecording = false
    @Published var fileURL: URL?

    let midiInput = CoreMIDIInput()
    let playbackEngine = PlaybackEngine()
    private let recorder: MIDIRecorder
    private let recordingClock = RecordingClock()
    private var pollTimer: Timer?
    private var documentCancellable: AnyCancellable?

    init() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        self.document = doc
        self.recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { [recordingClock] in
            recordingClock.beatsElapsed()
        }))
        bindDocument()

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
    }

    private func bindDocument() {
        recordingClock.tempo = document.project.tempo
        documentCancellable = document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recordingClock.tempo = document.project.tempo
        recorder.reset()
        recordingClock.startDate = Date()
        isRecording = true
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainMIDIQueue() }
        }
    }

    private func stopRecording() {
        isRecording = false
        pollTimer?.invalidate()
        pollTimer = nil
        recordingClock.startDate = nil
        drainMIDIQueue()

        guard !recorder.recordedNotes.isEmpty else { return }
        let regionLength = ceil(recorder.recordedNotes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0)
        let region = MIDIRegion(startBeat: 0, lengthBeats: max(regionLength, 1), notes: recorder.recordedNotes)
        document.addRegion(region, toTrackAt: 0)
    }

    private func drainMIDIQueue() {
        for message in midiInput.queue.drain() {
            recorder.handle(MIDIMessageParser.parse(message))
        }
    }

    func play() {
        guard let region = document.project.tracks.first?.regions.last else { return }
        isPlaying = true
        playbackEngine.play(region: region, tempo: document.project.tempo)
    }

    func stopPlayback() {
        isPlaying = false
    }
}
