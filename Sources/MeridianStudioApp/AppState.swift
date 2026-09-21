// Sources/MeridianStudioApp/AppState.swift
import Combine
import Foundation
import ProjectModel
import AudioEngine

@MainActor
final class AppState: ObservableObject {
    @Published var document: ProjectDocument {
        didSet { bindDocument() }
    }
    @Published var isPlaying = false
    @Published var isRecording = false
    @Published var fileURL: URL?
    /// The track armed for recording and shown in the piano roll. Clamped into
    /// range whenever tracks are added or removed, and reset to 0 by
    /// `bindDocument()` whenever `document` is replaced wholesale.
    @Published var selectedTrackIndex: Int = 0
    /// The single selected note in the piano roll, if any. Not reset when the
    /// selected track changes or a document is swapped — `PianoRollView` only ever
    /// shows the current track's notes, so a stale id simply matches nothing,
    /// which is visually equivalent to no selection without duplicating the reset
    /// logic `bindDocument()` already owns for `selectedTrackIndex`.
    @Published var selectedNoteID: UUID?
    /// Grid spacing in beats for `applyQuantization()` — 0.25 (a sixteenth-note
    /// grid) by default.
    @Published var quantizeGridBeats: Double = 0.25
    /// 0...1, how strongly `applyQuantization()` snaps notes toward the grid —
    /// 1.0 (a hard snap) by default.
    @Published var quantizeStrength: Double = 1.0
    /// Live microphone input level (0...1-ish peak, not calibrated dB) while an
    /// audio track is armed and recording. Polled the same way `liveNotes`
    /// tracks MIDI input — a visual cue only, maintained via the same timer
    /// that drains the MIDI queue.
    @Published private(set) var inputLevel: Float = 0

    /// Pitches currently held on the MIDI keyboard, mapped to the wall-clock
    /// `Date` they were pressed. This is a *live visual cue only* — deliberately
    /// independent of `MIDIRecorder`, which owns the beat-accurate recorded data.
    /// It is maintained whether or not recording is active, so playing a key is
    /// visible in the piano roll immediately rather than only after Stop.
    @Published private(set) var liveNotes: [UInt8: Date] = [:]

    let midiInput = CoreMIDIInput()
    let playbackEngine = PlaybackEngine()
    let audioRecorder: AudioRecorder
    private let recorder: MIDIRecorder
    let recordingClock = RecordingClock()
    /// Drains `midiInput.queue` continuously, recording or not. Runs for the whole
    /// app lifetime: if it only ran while recording, the queue would silently fill
    /// and drop events, and live input would be invisible outside a take.
    private var pollTimer: Timer?
    private var playbackCompletionTask: Task<Void, Never>?
    private var documentCancellable: AnyCancellable?

    private static let queuePollInterval: TimeInterval = 0.01

    init() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        self.document = doc
        self.recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { [recordingClock] in
            recordingClock.beatsElapsed()
        }))
        // `playbackEngine`'s own inline initializer has already run by this point
        // in a class's init, so `playbackEngine.engine` is safe to read here —
        // sharing the one running AVAudioEngine is required for simultaneous
        // record + playback (two independent AVAudioEngine instances would each
        // try to own the system's audio hardware).
        self.audioRecorder = AudioRecorder(engine: playbackEngine.engine)
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

        startQueuePolling()
    }

    private func bindDocument() {
        recordingClock.tempo = document.project.tempo
        // Every document swap (`newProject()`, `openProject()`) lands here via
        // `document`'s `didSet`. The selection must reset, not carry over: a stale
        // index past the new project's track count leaves `PianoRollView` blank
        // (its bounds guard returns `[]`) and makes `addRegion` silently drop a
        // recorded take (its bounds guard returns without adding, with no error
        // surfaced). 0 is the only index valid for every project the app can
        // produce, since `newProject()` and `removeTrack(at:)` both keep at least
        // one track; the existing bounds guards still cover a hand-authored
        // zero-track file loaded from disk.
        selectedTrackIndex = 0
        documentCancellable = document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // A `@MainActor` class cannot touch isolated stored properties from its
    // nonisolated `deinit`, so the timer tears itself down instead: it holds `self`
    // weakly and invalidates once the state object is gone.
    private func startQueuePolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.queuePollInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor in
                self.drainMIDIQueue()
                self.inputLevel = self.audioRecorder.level
            }
        }
    }

    var armedTrackKind: TrackKind {
        guard document.project.tracks.indices.contains(selectedTrackIndex) else { return .midi }
        return document.project.tracks[selectedTrackIndex].kind
    }

    func toggleRecording() {
        if isRecording {
            armedTrackKind == .audio ? stopAudioRecording() : stopRecording()
        } else {
            armedTrackKind == .audio ? startAudioRecording() : startRecording()
        }
    }

    private func startRecording() {
        // Clear anything already queued from before the take started: those messages
        // would otherwise be timestamped against the new clock and folded into this
        // take at the wrong beat positions. `isRecording` is still false here, so
        // this drain feeds nothing to the recorder — it only keeps the live-note
        // highlight in sync, which a bare `queue.drain()` discard would desync by
        // swallowing a note-off.
        drainMIDIQueue()
        recordingClock.tempo = document.project.tempo
        recorder.reset()
        recordingClock.startDate = Date()
        isRecording = true
    }

    private func stopRecording() {
        // Drain first, while `isRecording` is still true and `startDate` is still
        // set. Two orderings matter here:
        //  - `isRecording` must stay true or `drainMIDIQueue()` would route the
        //    tail of the take to the live-note display only, never the recorder.
        //  - `startDate` must stay set because `RecordingClock.beatsElapsed()`
        //    returns 0 once it is nil, which would stamp every queued note-off at
        //    beat 0 and yield bogus zero-or-negative-length notes.
        drainMIDIQueue()
        let finalBeat = recordingClock.beatsElapsed()
        isRecording = false
        // Keys still held at Stop have no note-off; close them out at the stop beat.
        recorder.finalize(atBeat: finalBeat)
        recordingClock.startDate = nil

        guard !recorder.recordedNotes.isEmpty else { return }
        let regionLength = ceil(recorder.recordedNotes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0)
        let region = MIDIRegion(startBeat: 0, lengthBeats: max(regionLength, 1), notes: recorder.recordedNotes)
        document.addRegion(region, toTrackAt: selectedTrackIndex)
    }

    private func drainMIDIQueue() {
        for message in midiInput.queue.drain() {
            let event = MIDIMessageParser.parse(message)
            updateLiveNotes(with: event)
            // The recorder only sees events during an actual take; the live-note
            // state above is maintained regardless.
            if isRecording {
                recorder.handle(event)
            }
        }
    }

    private func updateLiveNotes(with event: ParsedMIDIEvent) {
        switch event {
        case .noteOn(let pitch, _, _):
            liveNotes[pitch] = Date()
        case .noteOff(let pitch, _):
            liveNotes.removeValue(forKey: pitch)
        case .other:
            break
        }
    }

    func play() {
        let audibleTracks = TrackAudibility.audibleTracks(in: document.project.tracks)
        let regions = audibleTracks.compactMap(\.regions.last)
        guard !regions.isEmpty else { return }
        let tempo = document.project.tempo
        playbackCompletionTask?.cancel()
        isPlaying = true
        playbackEngine.play(regions: regions, tempo: tempo)

        // `PlaybackEngine` has no completion callback, so mirror the run length here
        // to clear `isPlaying` when a play-through ends on its own. Duration is the
        // longest of every region being played, not just one.
        let endBeat = regions.map { region in
            max(region.notes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0, region.lengthBeats)
        }.max() ?? 0
        let durationSeconds = Tempo.seconds(forBeats: max(endBeat, 0), tempo: tempo)
        playbackCompletionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(durationSeconds, 0) * 1_000_000_000))
            } catch {
                return  // Superseded by another play() or by stopPlayback().
            }
            self?.isPlaying = false
        }
    }

    func stopPlayback() {
        playbackCompletionTask?.cancel()
        playbackCompletionTask = nil
        // Cancels the in-flight scheduled note tasks and silences the sampler —
        // without this, Stop only flipped a flag while notes kept firing.
        playbackEngine.stopAllNotes()
        isPlaying = false
    }

    func selectTrack(at index: Int) {
        // `stopRecording()` reads `selectedTrackIndex` at Stop time, not at Start,
        // so letting the selection move mid-take would file the finished take on
        // whichever track happened to be selected when Stop was pressed.
        guard !isRecording else { return }
        guard document.project.tracks.indices.contains(index) else { return }
        selectedTrackIndex = index
    }

    func addTrack() {
        let name = "Track \(document.project.tracks.count + 1)"
        document.addTrack(Track(name: name))
        // Same hazard `selectTrack(at:)` guards against: `stopRecording()` reads
        // `selectedTrackIndex` at Stop time, so moving the selection mid-take would
        // file the finished take on this new empty track instead of the armed one.
        // The track is still added — only the selection move is deferred.
        guard !isRecording else { return }
        selectedTrackIndex = document.project.tracks.count - 1
    }

    func removeTrack(at index: Int) {
        guard document.project.tracks.indices.contains(index) else { return }
        guard document.project.tracks.count > 1 else { return }
        let id = document.project.tracks[index].id
        document.removeTrack(id: id)
        // Removing a track *before* the selected one shifts it down by one; without
        // this the selection would silently jump to whatever track slid into the
        // index. Deliberately `<` and not `<=`: when the selected track is itself
        // removed, the clamp below is what moves the selection, landing on whatever
        // now occupies that index (or the new last track, if it was at the end).
        if index < selectedTrackIndex {
            selectedTrackIndex -= 1
        }
        selectedTrackIndex = min(selectedTrackIndex, document.project.tracks.count - 1)
    }

    func toggleMute(at index: Int) {
        guard document.project.tracks.indices.contains(index) else { return }
        document.setTrackMuted(!document.project.tracks[index].muted, forTrackAt: index)
    }

    func toggleSolo(at index: Int) {
        guard document.project.tracks.indices.contains(index) else { return }
        document.setTrackSolo(!document.project.tracks[index].solo, forTrackAt: index)
    }

    func selectNote(id: UUID?) {
        selectedNoteID = id
    }

    func moveOrResizeSelectedNote(to updated: NoteEvent) {
        guard selectedNoteID == updated.id else { return }
        document.updateNote(updated, inTrackAt: selectedTrackIndex)
    }

    func deleteSelectedNote() {
        guard let selectedNoteID else { return }
        document.deleteNotes(ids: [selectedNoteID], inTrackAt: selectedTrackIndex)
        self.selectedNoteID = nil
    }

    func applyQuantization() {
        // The same bound `PianoRollView.moveGesture` clamps drags to (its canvas is
        // 800pt at 40 points-per-beat = 20 beats), taken from that view rather than
        // restated here so the two cannot drift apart. Without it, quantizing a note
        // near the canvas edge could push it out of the reachable/scrollable area the
        // exact way an unclamped drag could — invisible, unreachable by scrolling, and
        // unrecoverable, since neither updateNote nor quantizeNotes is undo-registered.
        document.quantizeNotes(gridBeats: quantizeGridBeats, strength: quantizeStrength, maxStartBeat: PianoRollView.canvasBeats, inTrackAt: selectedTrackIndex)
    }
}
