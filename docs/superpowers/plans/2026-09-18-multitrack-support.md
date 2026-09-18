# Multi-Track Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Meridian Studio's already-multi-track-capable data model actually work end to end: add/remove tracks, select which track is armed for recording and shown in the piano roll, per-track timeline lanes, and functional mute/solo affecting playback.

**Architecture:** Extend `ProjectDocument` with structural (undo-registered) track add/remove and field (non-undo) mute/solo mutations, add a pure `TrackAudibility` helper in `ProjectModel`, change `PlaybackEngine.play` to accept multiple regions in one call so playing several tracks doesn't cancel itself, then wire `AppState` and the three SwiftUI views (`TrackListView`, `TimelineView`, `PianoRollView`) to the selected-track/audibility concepts.

**Tech Stack:** Swift 6, SwiftUI, XCTest (now runs for real — Xcode is installed on this machine as of this plan).

**Spec:** `docs/superpowers/specs/2026-09-18-multitrack-design.md`

## Global Constraints

- Deployment target: macOS 14.0+ (unchanged, `Package.swift` already sets it).
- Zero third-party dependencies (unchanged).
- `swift test` now runs for real on this machine (Xcode is installed) — every task with tests must actually pass `swift test`, not just compile-and-hand-trace as Phase 1 required.
- Undo registration rule (established in Phase 1, continued here): `ProjectDocument` registers undo only for *structural* add/remove operations (`addRegion`/`removeRegion`, and this plan's `addTrack`/`removeTrack`). Field mutations (`setTempo`, and this plan's `setTrackMuted`/`setTrackSolo`) are direct, non-undo-registered writes.
- `PlaybackEngine.stopAllNotes()` must be called exactly once per `play` invocation, never per-region — calling it once per region would cancel the previous region's just-scheduled tasks.
- Track audibility rule: if any track is soloed, only soloed tracks are audible (solo overrides mute on the same track); otherwise every non-muted track is audible.

---

## Task 1: ProjectDocument Track Operations

**Files:**
- Modify: `Sources/ProjectModel/ProjectDocument.swift`
- Modify: `Tests/ProjectModelTests/ProjectDocumentTests.swift`

**Interfaces:**
- Consumes: `Project`, `Track` (existing).
- Produces: `ProjectDocument.addTrack(_ track: Track)`, `ProjectDocument.removeTrack(id: UUID)`, `ProjectDocument.setTrackMuted(_ muted: Bool, forTrackAt index: Int)`, `ProjectDocument.setTrackSolo(_ solo: Bool, forTrackAt index: Int)`. Used by `AppState` (Task 4).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ProjectModelTests/ProjectDocumentTests.swift` (inside the existing `@MainActor final class ProjectDocumentTests: XCTestCase { ... }`, alongside the existing tests):

```swift
    func testAddTrackAppendsTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.addTrack(Track(name: "Bass"))
        XCTAssertEqual(doc.project.tracks.count, 2)
        XCTAssertEqual(doc.project.tracks[1].name, "Bass")
    }

    func testUndoRemovesAddedTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.addTrack(Track(name: "Bass"))
        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks.count, 1)
        XCTAssertEqual(doc.project.tracks[0].name, "Piano")
    }

    func testRedoReAddsTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.addTrack(Track(name: "Bass"))
        doc.undoManager.undo()
        doc.undoManager.redo()
        XCTAssertEqual(doc.project.tracks.count, 2)
        XCTAssertEqual(doc.project.tracks[1].name, "Bass")
    }

    func testRemoveTrackRemovesByID() {
        let bass = Track(name: "Bass")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano"), bass]))
        doc.removeTrack(id: bass.id)
        XCTAssertEqual(doc.project.tracks.count, 1)
        XCTAssertEqual(doc.project.tracks[0].name, "Piano")
    }

    func testUndoReInsertsRemovedTrackAtOriginalIndex() {
        let bass = Track(name: "Bass")
        let drums = Track(name: "Drums")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano"), bass, drums]))
        doc.removeTrack(id: bass.id)
        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks.map(\.name), ["Piano", "Bass", "Drums"])
    }

    func testSetTrackMutedUpdatesTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.setTrackMuted(true, forTrackAt: 0)
        XCTAssertTrue(doc.project.tracks[0].muted)
    }

    func testSetTrackSoloUpdatesTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.setTrackSolo(true, forTrackAt: 0)
        XCTAssertTrue(doc.project.tracks[0].solo)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectDocumentTests`
Expected: FAIL — `addTrack`/`removeTrack`/`setTrackMuted`/`setTrackSolo` do not exist yet.

- [ ] **Step 3: Write the implementation**

Add to `Sources/ProjectModel/ProjectDocument.swift`, after the existing `removeRegion(id:fromTrackAt:)` method and before `setTempo(_:)`:

```swift
    public func addTrack(_ track: Track) {
        project.tracks.append(track)
        let insertedID = track.id
        undoManager.registerUndo(withTarget: self) { doc in
            doc.removeTrack(id: insertedID)
        }
    }

    public func removeTrack(id: UUID) {
        guard let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        let removed = project.tracks.remove(at: index)
        undoManager.registerUndo(withTarget: self) { doc in
            doc.insertTrack(removed, at: index)
        }
    }

    private func insertTrack(_ track: Track, at index: Int) {
        let clampedIndex = min(index, project.tracks.count)
        project.tracks.insert(track, at: clampedIndex)
        let insertedID = track.id
        undoManager.registerUndo(withTarget: self) { doc in
            doc.removeTrack(id: insertedID)
        }
    }
```

Add after `setTempo(_:)` and before `replaceProject(_:)`:

```swift
    public func setTrackMuted(_ muted: Bool, forTrackAt index: Int) {
        guard project.tracks.indices.contains(index) else { return }
        project.tracks[index].muted = muted
    }

    public func setTrackSolo(_ solo: Bool, forTrackAt index: Int) {
        guard project.tracks.indices.contains(index) else { return }
        project.tracks[index].solo = solo
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectDocumentTests`
Expected: PASS (11 tests: the 4 pre-existing plus the 7 new ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectModel/ProjectDocument.swift Tests/ProjectModelTests/ProjectDocumentTests.swift
git commit -m "Add track add/remove/mute/solo to ProjectDocument"
```

---

## Task 2: TrackAudibility Helper

**Files:**
- Create: `Sources/ProjectModel/TrackAudibility.swift`
- Create: `Tests/ProjectModelTests/TrackAudibilityTests.swift`

**Interfaces:**
- Consumes: `Track` (existing).
- Produces: `TrackAudibility.audibleTracks(in tracks: [Track]) -> [Track]`. Used by `AppState.play()` (Task 4).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ProjectModelTests/TrackAudibilityTests.swift
import XCTest
@testable import ProjectModel

final class TrackAudibilityTests: XCTestCase {
    func testNoSoloReturnsAllUnmutedTracks() {
        let tracks = [
            Track(name: "Piano"),
            Track(name: "Bass", muted: true),
            Track(name: "Drums")
        ]
        XCTAssertEqual(TrackAudibility.audibleTracks(in: tracks).map(\.name), ["Piano", "Drums"])
    }

    func testOneSoloedTrackReturnsOnlyIt() {
        let tracks = [
            Track(name: "Piano"),
            Track(name: "Bass", solo: true),
            Track(name: "Drums")
        ]
        XCTAssertEqual(TrackAudibility.audibleTracks(in: tracks).map(\.name), ["Bass"])
    }

    func testMultipleSoloedTracksReturnAllOfThem() {
        let tracks = [
            Track(name: "Piano", solo: true),
            Track(name: "Bass"),
            Track(name: "Drums", solo: true)
        ]
        XCTAssertEqual(TrackAudibility.audibleTracks(in: tracks).map(\.name), ["Piano", "Drums"])
    }

    func testSoloOverridesMuteOnTheSameTrack() {
        let tracks = [
            Track(name: "Piano", muted: true, solo: true),
            Track(name: "Bass")
        ]
        XCTAssertEqual(TrackAudibility.audibleTracks(in: tracks).map(\.name), ["Piano"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TrackAudibilityTests`
Expected: FAIL — `TrackAudibility` does not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/ProjectModel/TrackAudibility.swift
public enum TrackAudibility {
    public static func audibleTracks(in tracks: [Track]) -> [Track] {
        let soloed = tracks.filter { $0.solo }
        if !soloed.isEmpty { return soloed }
        return tracks.filter { !$0.muted }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TrackAudibilityTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectModel/TrackAudibility.swift Tests/ProjectModelTests/TrackAudibilityTests.swift
git commit -m "Add TrackAudibility mute/solo resolution helper"
```

---

## Task 3: PlaybackEngine Plays Multiple Regions

**Files:**
- Modify: `Sources/MIDIEngine/PlaybackEngine.swift`

**Interfaces:**
- Consumes: `MIDIRegion`, `PlaybackScheduler` (existing).
- Produces: `PlaybackEngine.play(regions: [MIDIRegion], tempo: Double)` — replaces the existing `play(region: MIDIRegion, tempo: Double)`. Used by `AppState.play()` (Task 4).

No automated tests for this task — matches Phase 1's precedent for `PlaybackEngine` (an AVFoundation hardware adapter, verified by build + manual smoke test).

- [ ] **Step 1: Modify the implementation**

In `Sources/MIDIEngine/PlaybackEngine.swift`, replace:

```swift
    /// Every in-flight `Task` spawned by `play(region:tempo:)`. Without this, Stop
    /// could not reach the sleeping tasks and they kept firing note-on/note-off
    /// after the transport had supposedly stopped.
    private var scheduledTasks: [Task<Void, Never>] = []
```

with:

```swift
    /// Every in-flight `Task` spawned by `play(regions:tempo:)`. Without this, Stop
    /// could not reach the sleeping tasks and they kept firing note-on/note-off
    /// after the transport had supposedly stopped.
    private var scheduledTasks: [Task<Void, Never>] = []
```

Then replace the whole `play(region:tempo:)` method:

```swift
    /// Wall-clock scheduling via `Task.sleep`, not sample-accurate `AVAudioTime`
    /// scheduling — acceptable for Phase 1's "audible and roughly in sync" bar.
    /// See docs/midi.md for the sample-accurate-scheduling follow-up note.
    public func play(region: MIDIRegion, tempo: Double) {
        // A second Play press must not stack on top of an unstopped previous one.
        stopAllNotes()
        for scheduled in PlaybackScheduler.schedule(region: region, tempo: tempo) {
            let task = Task { @MainActor [sampler] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(scheduled.startSeconds, 0) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    sampler.startNote(scheduled.pitch, withVelocity: scheduled.velocity, onChannel: 0)
                    try await Task.sleep(nanoseconds: UInt64(max(scheduled.lengthSeconds, 0) * 1_000_000_000))
                } catch {
                    // Cancelled. `stopAllNotes()` is the only canceller and it has
                    // already sent note-off for every pitch, so this task must not
                    // send its own trailing note-off — a late one could silence a
                    // note the *next* play() just started on the same pitch.
                    return
                }
                sampler.stopNote(scheduled.pitch, onChannel: 0)
            }
            scheduledTasks.append(task)
        }
    }
```

with:

```swift
    /// Wall-clock scheduling via `Task.sleep`, not sample-accurate `AVAudioTime`
    /// scheduling — acceptable for Phase 1's "audible and roughly in sync" bar.
    /// See docs/midi.md for the sample-accurate-scheduling follow-up note.
    public func play(regions: [MIDIRegion], tempo: Double) {
        // A second Play press must not stack on top of an unstopped previous one.
        // Called once here, not once per region — calling it per region would
        // cancel the previous region's just-scheduled tasks before they run.
        stopAllNotes()
        for region in regions {
            for scheduled in PlaybackScheduler.schedule(region: region, tempo: tempo) {
                let task = Task { @MainActor [sampler] in
                    do {
                        try await Task.sleep(nanoseconds: UInt64(max(scheduled.startSeconds, 0) * 1_000_000_000))
                        guard !Task.isCancelled else { return }
                        sampler.startNote(scheduled.pitch, withVelocity: scheduled.velocity, onChannel: 0)
                        try await Task.sleep(nanoseconds: UInt64(max(scheduled.lengthSeconds, 0) * 1_000_000_000))
                    } catch {
                        // Cancelled. `stopAllNotes()` is the only canceller and it has
                        // already sent note-off for every pitch, so this task must not
                        // send its own trailing note-off — a late one could silence a
                        // note the *next* play() just started on the same pitch.
                        return
                    }
                    sampler.stopNote(scheduled.pitch, onChannel: 0)
                }
                scheduledTasks.append(task)
            }
        }
    }
```

- [ ] **Step 2: Verify the target builds**

Run: `swift build --target MIDIEngine`
Expected: builds with no errors. This target-scoped build only compiles `MIDIEngine` and its `ProjectModel` dependency — it does not touch `MeridianStudioApp`, so `AppState.swift`'s not-yet-updated call to the old `play(region:tempo:)` signature (fixed in Task 4) has no effect here.

- [ ] **Step 3: Commit**

```bash
git add Sources/MIDIEngine/PlaybackEngine.swift
git commit -m "PlaybackEngine.play accepts multiple regions in one call"
```

---

## Task 4: AppState — Selected Track, Multi-Track Recording/Playback

**Files:**
- Modify: `Sources/MeridianStudioApp/AppState.swift`

**Interfaces:**
- Consumes: `ProjectDocument.addTrack`/`removeTrack`/`setTrackMuted`/`setTrackSolo` (Task 1), `TrackAudibility.audibleTracks(in:)` (Task 2), `PlaybackEngine.play(regions:tempo:)` (Task 3), `Track` (existing).
- Produces: `AppState.selectedTrackIndex: Int` (published), `AppState.selectTrack(at:)`, `AppState.addTrack()`, `AppState.removeTrack(at:)`, `AppState.toggleMute(at:)`, `AppState.toggleSolo(at:)`. Used by the views (Task 5).

No automated tests for this task — matches Phase 1's precedent for `AppState` (no test target for the app layer; verified by build + manual smoke test).

- [ ] **Step 1: Add the published property**

In `Sources/MeridianStudioApp/AppState.swift`, replace:

```swift
    @Published var isPlaying = false
    @Published var isRecording = false
    @Published var fileURL: URL?
```

with:

```swift
    @Published var isPlaying = false
    @Published var isRecording = false
    @Published var fileURL: URL?
    /// The track armed for recording and shown in the piano roll. Clamped into
    /// range whenever tracks are added or removed.
    @Published var selectedTrackIndex: Int = 0
```

- [ ] **Step 2: Record to the selected track**

Replace:

```swift
        guard !recorder.recordedNotes.isEmpty else { return }
        let regionLength = ceil(recorder.recordedNotes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0)
        let region = MIDIRegion(startBeat: 0, lengthBeats: max(regionLength, 1), notes: recorder.recordedNotes)
        document.addRegion(region, toTrackAt: 0)
    }
```

with:

```swift
        guard !recorder.recordedNotes.isEmpty else { return }
        let regionLength = ceil(recorder.recordedNotes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0)
        let region = MIDIRegion(startBeat: 0, lengthBeats: max(regionLength, 1), notes: recorder.recordedNotes)
        document.addRegion(region, toTrackAt: selectedTrackIndex)
    }
```

- [ ] **Step 3: Play every audible track's most recent region together**

Replace the whole `play()` method:

```swift
    func play() {
        guard let region = document.project.tracks.first?.regions.last else { return }
        let tempo = document.project.tempo
        playbackCompletionTask?.cancel()
        isPlaying = true
        playbackEngine.play(region: region, tempo: tempo)

        // `PlaybackEngine` has no completion callback, so mirror the run length here
        // to clear `isPlaying` when a play-through ends on its own.
        let endBeat = max(region.notes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0, region.lengthBeats)
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
```

with:

```swift
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
```

- [ ] **Step 4: Add track management methods**

Add these methods at the end of the `AppState` class, after `stopPlayback()` and before the closing brace:

```swift

    func selectTrack(at index: Int) {
        guard document.project.tracks.indices.contains(index) else { return }
        selectedTrackIndex = index
    }

    func addTrack() {
        let name = "Track \(document.project.tracks.count + 1)"
        document.addTrack(Track(name: name))
        selectedTrackIndex = document.project.tracks.count - 1
    }

    func removeTrack(at index: Int) {
        guard document.project.tracks.indices.contains(index) else { return }
        guard document.project.tracks.count > 1 else { return }
        let id = document.project.tracks[index].id
        document.removeTrack(id: id)
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
```

- [ ] **Step 5: Build**

Run: `swift build`
Expected: builds with no errors. This also resolves the caller-side error left over from Task 3.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeridianStudioApp/AppState.swift
git commit -m "Wire AppState to multi-track: selected track, audible playback"
```

---

## Task 5: UI — Track List, Timeline Lanes, Track-Scoped Piano Roll

**Files:**
- Modify: `Sources/MeridianStudioApp/TrackListView.swift`
- Modify: `Sources/MeridianStudioApp/TimelineView.swift`
- Modify: `Sources/MeridianStudioApp/PianoRollView.swift`

**Interfaces:**
- Consumes: `AppState.selectedTrackIndex`, `.selectTrack(at:)`, `.addTrack()`, `.removeTrack(at:)`, `.toggleMute(at:)`, `.toggleSolo(at:)` (Task 4).

No automated tests for this task — matches Phase 1's precedent for SwiftUI views (no UI testing harness; verified by build + the manual smoke test).

- [ ] **Step 1: Replace `TrackListView`**

```swift
// Sources/MeridianStudioApp/TrackListView.swift
import SwiftUI

struct TrackListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Tracks").font(.headline)
                Spacer()
                Button(action: { appState.addTrack() }) {
                    Image(systemName: "plus")
                }
            }
            .padding(8)

            List {
                ForEach(Array(appState.document.project.tracks.enumerated()), id: \.element.id) { index, track in
                    HStack {
                        Text(track.name)
                        Spacer()
                        Text("\(track.regions.count) region(s)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button(action: { appState.toggleMute(at: index) }) {
                            Text("M")
                                .foregroundColor(track.muted ? .red : .secondary)
                        }
                        .buttonStyle(.borderless)
                        Button(action: { appState.toggleSolo(at: index) }) {
                            Text("S")
                                .foregroundColor(track.solo ? .yellow : .secondary)
                        }
                        .buttonStyle(.borderless)
                        Button(action: { appState.removeTrack(at: index) }) {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(appState.document.project.tracks.count <= 1)
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .background(index == appState.selectedTrackIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                    .onTapGesture {
                        appState.selectTrack(at: index)
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Replace `TimelineView`**

```swift
// Sources/MeridianStudioApp/TimelineView.swift
import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var appState: AppState
    private let pixelsPerBeat: CGFloat = 40
    private let laneHeight: CGFloat = 60

    private var totalHeight: CGFloat {
        CGFloat(appState.document.project.tracks.count) * laneHeight
    }

    var body: some View {
        ScrollView(.horizontal) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(appState.document.project.tracks.enumerated()), id: \.element.id) { index, track in
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(index == appState.selectedTrackIndex ? Color.accentColor.opacity(0.1) : Color.clear)
                        ForEach(track.regions) { region in
                            Rectangle()
                                .fill(Color.accentColor.opacity(0.6))
                                .frame(width: CGFloat(region.lengthBeats) * pixelsPerBeat, height: laneHeight)
                                .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
                                .overlay(alignment: .topLeading) {
                                    Text("Region").font(.caption2).padding(2)
                                }
                        }
                    }
                    .frame(minWidth: 800, height: laneHeight, alignment: .topLeading)
                    Divider()
                }
            }
        }
        .frame(height: max(80, totalHeight))
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
```

- [ ] **Step 3: Scope `PianoRollView` to the selected track**

In `Sources/MeridianStudioApp/PianoRollView.swift`, replace:

```swift
    private var notes: [NoteEvent] {
        appState.document.project.tracks.first?.regions.last?.notes ?? []
    }
```

with:

```swift
    private var notes: [NoteEvent] {
        guard appState.document.project.tracks.indices.contains(appState.selectedTrackIndex) else { return [] }
        return appState.document.project.tracks[appState.selectedTrackIndex].regions.last?.notes ?? []
    }
```

- [ ] **Step 4: Build**

Run: `rm -rf .build && swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all tests pass (Tasks 1–2's new tests plus every pre-existing test).

- [ ] **Step 6: Manual smoke test**

Run: `swift run MeridianStudioApp`

Check:
- The track list shows "Piano" with a "+" button above it; clicking "+" adds "Track 2", which becomes selected (highlighted).
- Clicking a track row selects it (highlight moves); the piano roll and future recordings follow the selected track.
- M/S buttons toggle color (red/yellow) when clicked; the trash button is disabled when only one track remains.
- The timeline shows one lane per track, stacked vertically.
- Record onto one track, then select a different track and record again — each track's region appears in its own timeline lane and only the selected track's notes show in the piano roll.
- Press Play with multiple tracks having recorded regions — all of them should be audible together (not just one).
- Mute one track and Play again — the muted track should be silent; the rest should still play.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeridianStudioApp/TrackListView.swift Sources/MeridianStudioApp/TimelineView.swift Sources/MeridianStudioApp/PianoRollView.swift
git commit -m "Add multi-track UI: track list controls, per-track timeline lanes, scoped piano roll"
```

---

## Task 6: Documentation

**Files:**
- Modify: `docs/architecture.md`

**Interfaces:** None — documentation only, reflecting what Tasks 1–5 built.

- [ ] **Step 1: Update the undo paragraph and add a multi-track paragraph**

In `docs/architecture.md`, replace:

```markdown
Undo/redo is model-level scaffolding only in Phase 1: `ProjectDocument`
owns an `UndoManager` that `addRegion`/`removeRegion` register with, and
unit tests exercise undo and redo directly — but it is not wired into the
app's Edit menu or responder chain, so Cmd-Z does nothing in the running
app. Surfacing it in the UI is Phase 2 work.
```

with:

```markdown
Undo/redo is model-level scaffolding only: `ProjectDocument` owns an
`UndoManager` that `addRegion`/`removeRegion`/`addTrack`/`removeTrack`
register with, and unit tests exercise undo and redo directly — but it
is not wired into the app's Edit menu or responder chain, so Cmd-Z does
nothing in the running app. Surfacing it in the UI remains deferred.

Multi-track support (Phase 2): `addTrack`/`removeTrack` are
undo-registered structural operations, matching `addRegion`/
`removeRegion`; `setTrackMuted`/`setTrackSolo` are direct field
mutations with no undo registration, matching `setTempo` — undo is
reserved for structural add/remove throughout `ProjectDocument`, never
for field edits. `TrackAudibility.audibleTracks(in:)` implements the
standard DAW convention: if any track is soloed, only soloed tracks are
audible (solo overrides mute on the same track); otherwise every
non-muted track is audible. `AppState.selectedTrackIndex` is the track
armed for recording and shown in the piano roll — playback plays every
audible track's most recent region simultaneously, not just the
selected one.
```

- [ ] **Step 2: Commit**

```bash
git add docs/architecture.md
git commit -m "Document multi-track model in architecture.md"
```

- [ ] **Step 3: Push**

```bash
git push origin main
```
