# Undo/Redo in the App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Cmd-Z / Cmd-Shift-Z actually undo and redo project edits in the running Meridian Studio app.

**Architecture:** `ProjectDocument`'s undo closures switch from capturing a track index to capturing a track id (resolved at undo time), and `quantizeNotes` gains one undo step. `AppState` exposes `undo()`/`redo()`/`canUndo`/`canRedo`, routes to the tempo field's own undo while it's being edited, keeps the selection valid after undo, and republishes on `UndoManager` notifications so the menu stays current. `MeridianStudioApp` replaces the system Undo/Redo menu group with commands bound to `AppState`.

**Tech Stack:** Swift 6, SwiftUI (`CommandGroup(replacing: .undoRedo)`), AppKit (`NSApp.keyWindow`, `NSTextView.isFieldEditor`), Foundation (`UndoManager` and its notifications), Combine.

**Spec:** `docs/superpowers/specs/2026-10-04-undo-in-app-design.md`

## Global Constraints

- Public `ProjectDocument` method signatures do not change — callers keep passing track indices. Only what the undo closures *capture* changes (track id, resolved to an index when the closure runs; a missing track makes the closure a silent no-op).
- `removeTrack`/`insertTrack` keep capturing the list *position* to reinsert at — that is the correct meaning there.
- `quantizeNotes` registers exactly one undo step per call that changes notes, and none when quantizing changes nothing.
- Undo/Redo are disabled while recording, and when there is nothing to undo/redo.
- While a text field is being edited (key window's first responder is an `NSTextView` with `isFieldEditor == true`), Undo/Redo act on that field editor's own undo manager, never the project's.
- After any project undo/redo, `selectedTrackIndex` is clamped into `0...(tracks.count - 1)`.
- Menu items are plain "Undo"/"Redo" — no action names.
- Any test that makes two top-level undo-registering calls back to back must set `doc.undoManager.groupsByEvent = false` on that test's own document and wrap each top-level call in `beginUndoGrouping()`/`endUndoGrouping()` (test-only; see `testSequentialTrimThenSplitEachUndoIndependently`). Never change `groupsByEvent` in production code.
- Whole-package verification: `swift build` (zero warnings) and `swift test` across all targets, not one target.
- No automated tests for `AppState` or menu wiring (no app test target — project precedent).

## Review Focus

- **Undo after the track an edit belonged to was removed and then restored** must target that track, not whatever track now sits at the old index. → Task 1 `testUndoTargetsTrackByIDAfterAnEarlierTrackIsRemovedAndRestored`.
- **Quantizing notes that are already on the grid** must not leave a do-nothing entry on the undo stack (one Cmd-Z press would silently do nothing). → Task 1 `testQuantizeNotesRegistersNoUndoWhenNothingChanges`.
- **Undoing "add track" while that new track is selected** must leave a valid selection, not an index past the end (blank piano roll, dropped recordings). → Task 2 `reconcileSelectionAfterUndo()`; manual smoke test.
- **Pressing Cmd-Z while recording** must do nothing — undoing a track removal mid-take would file the take on the wrong track. → Task 2 `canUndo`/`canRedo` include `!isRecording`; manual smoke test.
- **Menu enabled-state going stale** (Undo greyed out though there's something to undo, or vice versa) — `UndoManager`'s stack can change without a `@Published` model change (group closing). → Task 2's notification subscription; manual smoke test.

---

### Task 1: `ProjectDocument` — track-id capture and quantize undo

**Files:**
- Modify: `Sources/ProjectModel/ProjectDocument.swift` (full rewrite below)
- Test: `Tests/ProjectModelTests/ProjectDocumentTests.swift`

**Interfaces:**
- Produces: `ProjectDocument.trackIndex(forID: UUID) -> Int?` (internal). No public signature changes. `quantizeNotes` now registers undo. Consumed by nothing new in Task 2 (Task 2 only calls `document.undoManager`).

- [ ] **Step 1: Write the failing tests**

In `Tests/ProjectModelTests/ProjectDocumentTests.swift`, find:

```swift
    func testQuantizeNotesIsNotUndoRegistered() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 0)

        XCTAssertFalse(doc.undoManager.canUndo)
    }
```

Replace with:

```swift
    func testQuantizeNotesRegistersOneUndoStepThatRestoresOriginalTiming() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 0)
        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].startBeat, 0.25, accuracy: 0.0001)

        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].startBeat, 0.3, accuracy: 0.0001)

        doc.undoManager.redo()
        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].startBeat, 0.25, accuracy: 0.0001)
    }

    func testQuantizeNotesRegistersNoUndoWhenNothingChanges() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.5, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 0)

        XCTAssertFalse(doc.undoManager.canUndo)
    }
```

Then, just before the file's final closing `}`, add:

```swift
    // Review Focus: undo closures capture the track's id, not its index.
    // Two top-level undo-registering calls back to back, so this uses the
    // test-only grouping accommodation (see
    // testSequentialTrimThenSplitEachUndoIndependently for why).
    func testUndoTargetsTrackByIDAfterAnEarlierTrackIsRemovedAndRestored() {
        let trackA = Track(name: "A")
        let trackB = Track(name: "B")
        let doc = ProjectDocument(project: Project(tracks: [trackA, trackB]))
        doc.undoManager.groupsByEvent = false

        doc.undoManager.beginUndoGrouping()
        doc.addRegion(MIDIRegion(startBeat: 0, lengthBeats: 4, notes: []), toTrackAt: 1)
        doc.undoManager.endUndoGrouping()

        doc.undoManager.beginUndoGrouping()
        doc.removeTrack(id: trackA.id)
        doc.undoManager.endUndoGrouping()
        XCTAssertEqual(doc.project.tracks.map(\.name), ["B"])

        doc.undoManager.undo()  // restores A at index 0
        XCTAssertEqual(doc.project.tracks.map(\.name), ["A", "B"])

        doc.undoManager.undo()  // removes the region from B, by id
        XCTAssertTrue(doc.project.tracks[1].regions.isEmpty)
        XCTAssertEqual(doc.project.tracks[1].name, "B")

        doc.undoManager.redo()  // re-adds the region to B, by id
        XCTAssertEqual(doc.project.tracks[1].regions.count, 1)
        XCTAssertTrue(doc.project.tracks[0].regions.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectDocumentTests`
Expected: `testQuantizeNotesRegistersOneUndoStepThatRestoresOriginalTiming` FAILS (undo does nothing — quantize isn't undo-registered yet). The other two new tests may pass already; that's fine — the id test documents and guards intended behavior, and the no-op test guards against Step 3 over-registering.

- [ ] **Step 3: Implement**

Replace the full contents of `Sources/ProjectModel/ProjectDocument.swift` with the following. Before replacing, diff it against the current file: the only intended differences are (a) the new `trackIndex(forID:)` helper, (b) every undo closure capturing `trackID` and resolving it, (c) `quantizeNotes` + new `replaceNotes`. If the current file contains anything else not reproduced here, stop and report it rather than dropping it.

```swift
// Sources/ProjectModel/ProjectDocument.swift
import Foundation

@MainActor
public final class ProjectDocument: ObservableObject {
    @Published public private(set) var project: Project
    public let undoManager = UndoManager()

    public init(project: Project = Project()) {
        self.project = project
    }

    /// Undo closures capture a track's `id`, never its index, and resolve it
    /// here when they run: a track's index can shift (a track before it was
    /// removed) between when an action is registered and when it's undone or
    /// redone. A track that no longer exists makes the closure a no-op.
    func trackIndex(forID id: UUID) -> Int? {
        project.tracks.firstIndex(where: { $0.id == id })
    }

    public func addRegion(_ region: MIDIRegion, toTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        let trackID = project.tracks[trackIndex].id
        project.tracks[trackIndex].regions.append(region)
        undoManager.registerUndo(withTarget: self) { doc in
            // UndoManager's handler type predates Swift concurrency and isn't itself
            // @MainActor, but registerUndo/undo/redo are only ever called from
            // MainActor-isolated code in this app, so this is genuinely safe — the
            // standard bridge for a legacy Foundation callback API like this one.
            MainActor.assumeIsolated {
                guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
                doc.removeRegion(id: region.id, fromTrackAt: trackIndex)
            }
        }
    }

    public func removeRegion(id: UUID, fromTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].regions.firstIndex(where: { $0.id == id }) else { return }
        let trackID = project.tracks[trackIndex].id
        let removed = project.tracks[trackIndex].regions.remove(at: index)
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
                doc.addRegion(removed, toTrackAt: trackIndex)
            }
        }
    }

    public func addAudioRegion(_ region: AudioRegion, toTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        let trackID = project.tracks[trackIndex].id
        project.tracks[trackIndex].audioRegions.append(region)
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
                doc.removeAudioRegion(id: region.id, fromTrackAt: trackIndex)
            }
        }
    }

    public func removeAudioRegion(id: UUID, fromTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == id }) else { return }
        let trackID = project.tracks[trackIndex].id
        let removed = project.tracks[trackIndex].audioRegions.remove(at: index)
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
                doc.addAudioRegion(removed, toTrackAt: trackIndex)
            }
        }
    }

    /// Splits the region with `id` into two at `splitBeat`. A no-op if
    /// `splitBeat` doesn't fall strictly inside the region (e.g. a
    /// double-click landed exactly on or past an edge) — never produces a
    /// degenerate zero-length half. Both halves reference the same
    /// `fileName`; no audio file is read, copied, or written. Registered as
    /// a single undo step via `mergeAudioRegions`'s mutual re-registration
    /// (the same idiom `addAudioRegion`/`removeAudioRegion` already use for
    /// their own undo/redo symmetry) — not composed from three chained
    /// `removeAudioRegion`/`addAudioRegion` calls, which would register
    /// three separate undo steps instead of one.
    public func splitAudioRegion(id: UUID, atBeat splitBeat: Double, tempo: Double, inTrackAt trackIndex: Int) {
        splitAudioRegion(id: id, atBeat: splitBeat, tempo: tempo, inTrackAt: trackIndex, firstID: UUID(), secondID: UUID())
    }

    /// The actual implementation behind the public `splitAudioRegion`, taking
    /// the two halves' ids as parameters instead of minting fresh ones every
    /// call. This is what lets `mergeAudioRegions`'s undo closure re-run a
    /// split as a *redo* and land on the exact same halves (same ids) it
    /// undid — minting new UUIDs on every call would mean a later undo/redo
    /// of some *other* operation that still refers to those halves by id
    /// (e.g. a subsequent split of one half, or a trim) would silently no-op
    /// against ids that no longer exist in the model.
    private func splitAudioRegion(id: UUID, atBeat splitBeat: Double, tempo: Double, inTrackAt trackIndex: Int, firstID: UUID, secondID: UUID) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == id }) else { return }
        let original = project.tracks[trackIndex].audioRegions[index]
        guard splitBeat > original.startBeat, splitBeat < original.startBeat + original.lengthBeats else { return }
        let trackID = project.tracks[trackIndex].id

        let firstLengthBeats = splitBeat - original.startBeat
        let elapsedSeconds = Tempo.seconds(forBeats: firstLengthBeats, tempo: tempo)
        let first = AudioRegion(
            id: firstID, startBeat: original.startBeat, lengthBeats: firstLengthBeats,
            fileName: original.fileName, sourceOffsetSeconds: original.sourceOffsetSeconds
        )
        let second = AudioRegion(
            id: secondID, startBeat: splitBeat, lengthBeats: original.lengthBeats - firstLengthBeats,
            fileName: original.fileName, sourceOffsetSeconds: original.sourceOffsetSeconds + elapsedSeconds
        )

        project.tracks[trackIndex].audioRegions.remove(at: index)
        project.tracks[trackIndex].audioRegions.append(first)
        project.tracks[trackIndex].audioRegions.append(second)

        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
                doc.mergeAudioRegions(first.id, second.id, into: original, splitBeat: splitBeat, tempo: tempo, inTrackAt: trackIndex)
            }
        }
    }

    /// The inverse of `splitAudioRegion` — removes both halves, restores
    /// `original`, and registers undo for *this* operation as a call back
    /// into `splitAudioRegion` at the same point, so redo re-splits.
    private func mergeAudioRegions(_ firstID: UUID, _ secondID: UUID, into original: AudioRegion, splitBeat: Double, tempo: Double, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        let trackID = project.tracks[trackIndex].id
        project.tracks[trackIndex].audioRegions.removeAll { $0.id == firstID || $0.id == secondID }
        project.tracks[trackIndex].audioRegions.append(original)

        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
                doc.splitAudioRegion(id: original.id, atBeat: splitBeat, tempo: tempo, inTrackAt: trackIndex, firstID: firstID, secondID: secondID)
            }
        }
    }

    /// Live setter for the drag in progress — no undo registration, same
    /// reasoning as `updateNote`. Called on every `onChanged` frame.
    public func updateAudioRegion(_ region: AudioRegion, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == region.id }) else { return }
        project.tracks[trackIndex].audioRegions[index] = region
    }

    /// Called once, at drag-end, with the region's value captured when the
    /// drag started. Registers one undo step for the whole gesture, mirroring
    /// `commitNoteEdit`. A no-op (no undo registered) when nothing changed.
    public func commitAudioRegionEdit(from original: AudioRegion, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == original.id }) else { return }
        let current = project.tracks[trackIndex].audioRegions[index]
        guard current != original else { return }
        let trackID = project.tracks[trackIndex].id
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
                doc.updateAudioRegion(original, inTrackAt: trackIndex)
                doc.commitAudioRegionEdit(from: current, inTrackAt: trackIndex)
            }
        }
    }

    public func addTrack(_ track: Track) {
        project.tracks.append(track)
        let insertedID = track.id
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.removeTrack(id: insertedID)
            }
        }
    }

    public func removeTrack(id: UUID) {
        guard let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        let removed = project.tracks.remove(at: index)
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.insertTrack(removed, at: index)
            }
        }
    }

    private func insertTrack(_ track: Track, at index: Int) {
        let clampedIndex = min(index, project.tracks.count)
        project.tracks.insert(track, at: clampedIndex)
        let insertedID = track.id
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.removeTrack(id: insertedID)
            }
        }
    }

    public func updateNote(_ note: NoteEvent, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        guard let noteIndex = project.tracks[trackIndex].regions[regionIndex].notes.firstIndex(where: { $0.id == note.id }) else { return }
        project.tracks[trackIndex].regions[regionIndex].notes[noteIndex] = note
    }

    /// Called once, at drag-end, with the note's value captured when the
    /// drag started. Registers one undo step for the whole gesture —
    /// restoring `original` via the same mutual-re-registration idiom
    /// `addRegion`/`removeRegion` already use, so redo works symmetrically.
    /// A no-op (no undo registered) when nothing changed. `updateNote` itself
    /// stays undo-free on purpose: it's called on every `onChanged` frame
    /// during a drag, and registering undo there would turn one drag gesture
    /// into dozens of undo steps.
    public func commitNoteEdit(from original: NoteEvent, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        guard let noteIndex = project.tracks[trackIndex].regions[regionIndex].notes.firstIndex(where: { $0.id == original.id }) else { return }
        let current = project.tracks[trackIndex].regions[regionIndex].notes[noteIndex]
        guard current != original else { return }
        let trackID = project.tracks[trackIndex].id
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
                doc.updateNote(original, inTrackAt: trackIndex)
                doc.commitNoteEdit(from: current, inTrackAt: trackIndex)
            }
        }
    }

    public func deleteNotes(ids: Set<UUID>, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        let removedNotes = project.tracks[trackIndex].regions[regionIndex].notes.filter { ids.contains($0.id) }
        guard !removedNotes.isEmpty else { return }
        let trackID = project.tracks[trackIndex].id
        project.tracks[trackIndex].regions[regionIndex].notes.removeAll { ids.contains($0.id) }
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
                doc.restoreNotes(removedNotes, inTrackAt: trackIndex)
            }
        }
    }

    private func restoreNotes(_ notes: [NoteEvent], inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        let trackID = project.tracks[trackIndex].id
        project.tracks[trackIndex].regions[regionIndex].notes.append(contentsOf: notes)
        let ids = Set(notes.map(\.id))
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
                doc.deleteNotes(ids: ids, inTrackAt: trackIndex)
            }
        }
    }

    /// `maxStartBeat` is passed straight through to `Quantizer.quantize`: an
    /// optional upper bound on where a quantized note may end, supplied by the
    /// UI that has to keep the note reachable. `nil` (the default) means no
    /// bound. Registers one undo step restoring the pre-quantize notes (one
    /// click can rewrite a whole take's timing); registers nothing if
    /// quantizing changes nothing.
    public func quantizeNotes(gridBeats: Double, strength: Double, maxStartBeat: Double? = nil, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        let notes = project.tracks[trackIndex].regions[regionIndex].notes
        let quantized = Quantizer.quantize(notes, gridBeats: gridBeats, strength: strength, maxStartBeat: maxStartBeat)
        guard quantized != notes else { return }
        replaceNotes(quantized, inTrackAt: trackIndex)
    }

    /// Replaces the last region's notes wholesale and registers its own
    /// inverse (the notes it replaced) — the mutual re-registration idiom, so
    /// undo restores the old notes and redo re-applies the new ones.
    private func replaceNotes(_ notes: [NoteEvent], inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        let trackID = project.tracks[trackIndex].id
        let previous = project.tracks[trackIndex].regions[regionIndex].notes
        project.tracks[trackIndex].regions[regionIndex].notes = notes
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                guard let trackIndex = doc.trackIndex(forID: trackID) else { return }
                doc.replaceNotes(previous, inTrackAt: trackIndex)
            }
        }
    }

    public func setTempo(_ tempo: Double) {
        // Clamp to a small positive floor: `Tempo.seconds(forBeats:tempo:)` divides by
        // tempo, so a zero or non-finite value here produces NaN/Infinity downstream
        // (e.g. in PlaybackEngine.play's UInt64(seconds * 1e9) conversion, which traps).
        // 1 BPM is non-musical but always finite and positive. Note: Swift's global
        // `max` does NOT clamp NaN (max(.nan, 1) == .nan, since NaN comparisons are
        // always false), so NaN needs its own explicit check here.
        project.tempo = tempo.isFinite ? max(tempo, 1) : 1
    }

    public func setTrackMuted(_ muted: Bool, forTrackAt index: Int) {
        guard project.tracks.indices.contains(index) else { return }
        project.tracks[index].muted = muted
    }

    public func setTrackSolo(_ solo: Bool, forTrackAt index: Int) {
        guard project.tracks.indices.contains(index) else { return }
        project.tracks[index].solo = solo
    }

    public func replaceProject(_ newProject: Project) {
        project = newProject
        undoManager.removeAllActions()
    }
}
```

Note on `quantized != notes`: `NoteEvent`'s `==` deliberately ignores `id` and compares musical content, which is exactly what "did quantizing change anything" means here.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectDocumentTests`
Expected: all pass, including the 3 new tests and every pre-existing undo test (split, trim, notes, tracks).

- [ ] **Step 5: Run the whole package**

Run: `swift build` (zero warnings) then `swift test`.
Expected: all targets green.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectModel/ProjectDocument.swift Tests/ProjectModelTests/ProjectDocumentTests.swift
git commit -m "Capture track ids in undo closures and make quantize undoable"
```

---

### Task 2: Wire Undo/Redo into the app

**Files:**
- Create: `Sources/MeridianStudioApp/AppState+Undo.swift`
- Modify: `Sources/MeridianStudioApp/AppState.swift` (`bindDocument()` subscription; `applyQuantization` comment)
- Modify: `Sources/MeridianStudioApp/MeridianStudioApp.swift` (Edit menu commands)
- Modify: `Sources/MeridianStudioApp/PianoRollView.swift` (two stale comments)
- Modify: `docs/architecture.md`, `docs/project-overview.md`

**Interfaces:**
- Consumes: `document.undoManager` (pre-existing), Task 1's undo-registering `quantizeNotes`.
- Produces: `AppState.canUndo: Bool`, `AppState.canRedo: Bool`, `AppState.undo()`, `AppState.redo()` — consumed by `MeridianStudioApp.swift` in this task.

No automated tests (no app test target — project precedent). Verified by build, the full suite (regression), and the manual smoke test.

- [ ] **Step 1: Create `AppState+Undo.swift`**

```swift
// Sources/MeridianStudioApp/AppState+Undo.swift
import AppKit
import ProjectModel

extension AppState {
    /// Disabled while recording: `stopRecording()`/`stopAudioRecording()` read
    /// `selectedTrackIndex` at Stop time, and undoing a track change mid-take
    /// would file the take on the wrong track — the same hazard
    /// `selectTrack(at:)`/`removeTrack(at:)` already guard against.
    var canUndo: Bool { !isRecording && document.undoManager.canUndo }
    var canRedo: Bool { !isRecording && document.undoManager.canRedo }

    func undo() {
        if let fieldEditor = activeFieldEditor {
            fieldEditor.undoManager?.undo()
            return
        }
        guard canUndo else { return }
        document.undoManager.undo()
        reconcileSelectionAfterUndo()
    }

    func redo() {
        if let fieldEditor = activeFieldEditor {
            fieldEditor.undoManager?.redo()
            return
        }
        guard canRedo else { return }
        document.undoManager.redo()
        reconcileSelectionAfterUndo()
    }

    /// The text view currently editing a text field (e.g. the tempo field),
    /// if any. While one is active, Undo/Redo belong to the text being typed,
    /// not to the project.
    private var activeFieldEditor: NSTextView? {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isFieldEditor else { return nil }
        return textView
    }

    /// Undoing "add track" can remove the selected track; keep the selection
    /// pointing at a real track. `selectedNoteID` is left alone — a stale id
    /// matches nothing, which already reads as "no selection".
    private func reconcileSelectionAfterUndo() {
        let lastIndex = max(document.project.tracks.count - 1, 0)
        selectedTrackIndex = min(max(selectedTrackIndex, 0), lastIndex)
    }
}
```

`selectedTrackIndex` and `isRecording` are non-private `@Published` vars on `AppState` already, so the extension can read/write them. Confirm this against the current `AppState.swift` before relying on it.

- [ ] **Step 2: Republish on undo-stack changes**

In `Sources/MeridianStudioApp/AppState.swift`, find:

```swift
    private var documentCancellable: AnyCancellable?
```

Replace with:

```swift
    private var documentCancellable: AnyCancellable?
    /// Republishes when the current document's undo stack changes, so the
    /// Edit menu's Undo/Redo enabled-state stays current. Not every
    /// undo-stack change coincides with a `@Published` model change — a
    /// group closing at the end of an event doesn't.
    private var undoStackCancellable: AnyCancellable?
```

Then find:

```swift
        documentCancellable = document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
```

Replace with:

```swift
        documentCancellable = document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        let undoManager = document.undoManager
        let center = NotificationCenter.default
        undoStackCancellable = Publishers.MergeMany(
            center.publisher(for: .NSUndoManagerDidCloseUndoGroup, object: undoManager),
            center.publisher(for: .NSUndoManagerDidUndoChange, object: undoManager),
            center.publisher(for: .NSUndoManagerDidRedoChange, object: undoManager)
        )
        .sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
```

`bindDocument()` already re-runs on every document swap (`document`'s `didSet`), so this resubscribes to each new document's own `UndoManager`.

- [ ] **Step 3: Update the stale quantize comment**

In `Sources/MeridianStudioApp/AppState.swift`, find:

```swift
        // unrecoverable, since neither updateNote nor quantizeNotes is undo-registered.
```

Replace with:

```swift
        // effectively lost: undo can restore it, but until then it can't be seen or edited.
```

Read the surrounding comment after editing and make sure the sentence still reads correctly; adjust only that sentence's wording if needed.

- [ ] **Step 4: Update `PianoRollView`'s two stale comments**

In `Sources/MeridianStudioApp/PianoRollView.swift`, find:

```swift
    // isn't undo-registered.
```

and read the full comment it ends (around line 57-60). Replace the clause that says the note is unrecoverable because `updateNote` isn't undo-registered with: "and only undo can bring it back." Then find:

```swift
                // fixed), and unrecoverable since updateNote isn't undo-registered.
```

Replace with:

```swift
                // fixed), and only undo can bring it back.
```

Comment-only edits; no code changes in this file.

- [ ] **Step 5: Add the Edit menu commands**

In `Sources/MeridianStudioApp/MeridianStudioApp.swift`, find:

```swift
        .commands {
            CommandGroup(replacing: .newItem) {
```

Replace with:

```swift
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { appState.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!appState.canUndo)
                Button("Redo") { appState.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!appState.canRedo)
            }
            CommandGroup(replacing: .newItem) {
```

- [ ] **Step 6: Update docs**

In `docs/architecture.md`, replace the three paragraphs starting at "Undo/redo is model-level only:" and ending with "covering the whole quantize pass." with:

```markdown
Undo/redo: `ProjectDocument` owns an `UndoManager`, and two tiers of
operation register with it. The first tier —
`addRegion`/`removeRegion`/`addTrack`/`removeTrack`/`addAudioRegion`/
`removeAudioRegion`/`deleteNotes`, plus `splitAudioRegion` and
`quantizeNotes` — registers one undo step on the call that mutates. The
second tier covers edits that happen gradually across a drag: a cheap
`update…` setter (`updateNote`/`updateAudioRegion`) with *no* undo
registration runs on every `onChanged` frame, and a single
`commit…Edit` call (`commitNoteEdit`/`commitAudioRegionEdit`) at
gesture-end registers the one undo step that restores the pre-gesture
value. Every undo closure captures the affected track's `id` and
resolves it to an index when it runs, so a track whose index shifted in
between (an earlier track was removed) is still the one targeted.

The Edit menu's Undo (Cmd-Z) and Redo (Cmd-Shift-Z) drive this
`UndoManager` through `AppState.undo()`/`redo()`
(`AppState+Undo.swift`). Both are disabled while recording. While a
text field is being edited, they act on that field's text instead.
After a project undo/redo, `selectedTrackIndex` is clamped back into
range. `AppState` republishes on `UndoManager` notifications so the
menu's enabled-state stays current. Mute, solo, and tempo are not
undoable. Undoing a recording removes the region but not its audio file.
```

In `docs/project-overview.md`, find:

```markdown
| 3, milestone 4 | Trim/split audio regions, sliced waveform rendering | Done (undo is model-level only — not yet wired to the Edit menu) |
```

Replace with:

```markdown
| 3, milestone 4 | Trim/split audio regions, sliced waveform rendering | Done |
| 3, milestone 5 | Undo/redo in the Edit menu (Cmd-Z / Cmd-Shift-Z) | Done |
```

Check the table row immediately after it (fade/normalize) still reads correctly.

- [ ] **Step 7: Build and test the whole package**

Run: `swift build` (zero errors, zero warnings), then `swift test`.
Expected: all targets green.

- [ ] **Step 8: Manual smoke test**

If you cannot launch and interact with the macOS app, say so — do not fabricate results.

- Record a MIDI take, Cmd-Z: the take disappears; Cmd-Shift-Z: it returns.
- Drag a note, Cmd-Z: it snaps back in one press. Delete a note, Cmd-Z: it returns.
- Quantize, Cmd-Z: original timing returns.
- Trim an audio region, Cmd-Z; split one, Cmd-Z, then Cmd-Shift-Z.
- Add a track (it becomes selected), Cmd-Z: the track is gone and the piano roll/selection still shows a valid track.
- Edit > Undo is greyed out on a fresh project and while recording.
- Click into the tempo field, type, Cmd-Z: the typing is undone, not a project edit.

- [ ] **Step 9: Commit**

```bash
git add Sources/MeridianStudioApp/AppState+Undo.swift Sources/MeridianStudioApp/AppState.swift Sources/MeridianStudioApp/MeridianStudioApp.swift Sources/MeridianStudioApp/PianoRollView.swift docs/architecture.md docs/project-overview.md
git commit -m "Wire Undo/Redo into the Edit menu"
```

---

## Self-Review Notes (completed during plan authoring)

- **Spec coverage:** §1.1 + §2 (id capture) → Task 1. §1.2 + §3 (quantize undo) → Task 1. §1.3–1.6 + §4 (menu, state, selection, tempo field, notifications) → Task 2. §5 tests → Task 1 tests + Task 2 smoke test. §6 non-goals → nothing in either task exceeds them.
- **Decomposition:** Two tasks rather than three. Id capture and quantize undo both rewrite `ProjectDocument.swift`; splitting them would mean two full-file rewrites of the same file with an anchor-drift risk between them. Task 1 leaves the build green on its own (no public signature changes). Task 2 depends only on pre-existing APIs plus Task 1's behavior.
- **Anchors verified** against the current files at plan time: `testQuantizeNotesIsNotUndoRegistered` (ProjectDocumentTests.swift:214), `documentCancellable` declaration and the `bindDocument()` sink block (AppState.swift:78, 122-124), the quantize comment (AppState.swift:355), PianoRollView comments (lines 60, 149), `.commands { CommandGroup(replacing: .newItem) {` (MeridianStudioApp.swift), the architecture.md undo paragraphs, the project-overview row. Task 1's full-file replacement reproduces the current `ProjectDocument.swift` (post trim/split fix wave, including the private split overload) with only the intended changes.
- **Placeholder scan:** none. Step 4 of Task 2 has one judgment instruction (fit a clause into an existing multi-line comment) — comment-only, low risk.
- **Type consistency:** `trackIndex(forID:)` is used identically in every closure. `canUndo`/`canRedo`/`undo()`/`redo()` match between `AppState+Undo.swift` and `MeridianStudioApp.swift`.
- **Undo-grouping lesson applied:** the one new test with two top-level undo-registering calls (`testUndoTargetsTrackByIDAfterAnEarlierTrackIsRemovedAndRestored`) uses the test-only `groupsByEvent = false` + explicit grouping pattern. The quantize tests make a single top-level call each.
- **Review Focus:** 5 items, each mapped to a test or a smoke-test step.
