# Note-Level Piano Roll Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user select, move, resize, and delete individual notes in the piano roll instead of only ever re-recording a whole take.

**Architecture:** Give `NoteEvent` a stable `id` (with backward-compatible decoding and content-only equality so every existing test stays valid), add `updateNote`/`deleteNotes` to `ProjectDocument` (field-edit and structural-remove, matching the project's existing undo-registration split), wire single-note selection into `AppState`, then add tap/drag/delete interaction to `PianoRollView`.

**Tech Stack:** Swift 6, SwiftUI, XCTest (runs for real — Xcode is installed).

**Spec:** `docs/superpowers/specs/2026-09-18-note-editing-design.md`

## Global Constraints

- Deployment target: macOS 14.0+, zero third-party dependencies (unchanged).
- `swift test` runs for real on this machine — every task with tests must show real RED/GREEN evidence.
- `NoteEvent` equality must ignore `id` — comparing by musical content only, so every pre-existing test (`MIDIRecorderTests`, `RecordAndPersistIntegrationTests`, `CodableRoundTripTests`) keeps passing unmodified.
- `NoteEvent` decoding must tolerate a missing `id` key (old project files predate this field) by synthesizing a fresh `UUID()`.
- Undo registration rule (established in Phase 1/2, continued here): structural add/remove is undo-registered; in-place field edits are not. `deleteNotes` (removal) is undo-registered; `updateNote` (in-place edit) is not.
- Any new `registerUndo` closure must use the `MainActor.assumeIsolated { ... }` bridge already established in `ProjectDocument.swift` — annotating the closure itself `@MainActor` does NOT work (CI's pinned toolchain rejects it with "loses global actor 'MainActor'"; this was discovered and fixed the hard way earlier in this project).
- All notes are edited within a track's *current* region (`regions.last`), matching the existing convention used everywhere else (`PianoRollView`, `AppState.play()`).

---

## Task 1: `NoteEvent` Gains a Stable Identity

**Files:**
- Modify: `Sources/ProjectModel/NoteEvent.swift`
- Create: `Tests/ProjectModelTests/NoteEventTests.swift`

**Interfaces:**
- Produces: `NoteEvent.id: UUID` (public var), `NoteEvent.init(id: UUID = UUID(), pitch:velocity:startBeat:lengthBeats:)`, custom `Equatable` (ignores `id`), custom `Decodable` (tolerates missing `id`), `Identifiable` conformance. Used by `ProjectDocument` (Task 2), `AppState` (Task 3), `PianoRollView` (Task 4).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/ProjectModelTests/NoteEventTests.swift
import XCTest
@testable import ProjectModel

final class NoteEventTests: XCTestCase {
    func testEqualityIgnoresID() {
        let a = NoteEvent(id: UUID(), pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let b = NoteEvent(id: UUID(), pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertEqual(a, b)
    }

    func testDecodingWithoutIDSynthesizesOne() throws {
        let json = """
        {"pitch": 60, "velocity": 100, "startBeat": 0, "lengthBeats": 1}
        """
        let note = try JSONDecoder().decode(NoteEvent.self, from: Data(json.utf8))
        XCTAssertEqual(note.pitch, 60)
    }

    func testDecodingWithIDRoundTripsThatID() throws {
        let originalID = UUID()
        let json = """
        {"id": "\(originalID.uuidString)", "pitch": 60, "velocity": 100, "startBeat": 0, "lengthBeats": 1}
        """
        let note = try JSONDecoder().decode(NoteEvent.self, from: Data(json.utf8))
        XCTAssertEqual(note.id, originalID)
    }

    func testEncodeDecodeRoundTripsID() throws {
        let original = NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 2)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NoteEvent.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter NoteEventTests`
Expected: FAIL — `NoteEvent` has no `id` yet, so `testEqualityIgnoresID`/`testEncodeDecodeRoundTripsID` won't compile as written, and the JSON in the other two tests won't matter yet.

- [ ] **Step 3: Write the implementation**

Replace the full contents of `Sources/ProjectModel/NoteEvent.swift`:

```swift
import Foundation

public struct NoteEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var pitch: UInt8
    public var velocity: UInt8
    public var startBeat: Double
    public var lengthBeats: Double

    public init(id: UUID = UUID(), pitch: UInt8, velocity: UInt8, startBeat: Double, lengthBeats: Double) {
        self.id = id
        self.pitch = pitch
        self.velocity = velocity
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
    }

    // Equality intentionally ignores `id` — existing code (recording, persistence,
    // tests) compares NoteEvents by musical content, not instance identity. `id`
    // exists only so the piano roll can address a specific note for editing/deletion.
    public static func == (lhs: NoteEvent, rhs: NoteEvent) -> Bool {
        lhs.pitch == rhs.pitch && lhs.velocity == rhs.velocity
            && lhs.startBeat == rhs.startBeat && lhs.lengthBeats == rhs.lengthBeats
    }

    private enum CodingKeys: String, CodingKey {
        case id, pitch, velocity, startBeat, lengthBeats
    }

    // Custom decode so a project file saved before this field existed still opens:
    // `id` is synthesized fresh when absent rather than failing to decode.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pitch = try container.decode(UInt8.self, forKey: .pitch)
        velocity = try container.decode(UInt8.self, forKey: .velocity)
        startBeat = try container.decode(Double.self, forKey: .startBeat)
        lengthBeats = try container.decode(Double.self, forKey: .lengthBeats)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter NoteEventTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run: `swift test`
Expected: all existing tests still pass (47 pre-existing + 4 new = 51). This is the step that proves the ignore-`id` equality choice was correct — if any pre-existing test in `MIDIRecorderTests`, `RecordAndPersistIntegrationTests`, or `CodableRoundTripTests` now fails, STOP and report BLOCKED rather than changing those tests; that would mean the equality design needs to be revisited, not the tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectModel/NoteEvent.swift Tests/ProjectModelTests/NoteEventTests.swift
git commit -m "Give NoteEvent a stable id with backward-compatible decoding"
```

---

## Task 2: `ProjectDocument` — Note Mutation

**Files:**
- Modify: `Sources/ProjectModel/ProjectDocument.swift`
- Modify: `Tests/ProjectModelTests/ProjectDocumentTests.swift`

**Interfaces:**
- Consumes: `NoteEvent` (Task 1).
- Produces: `ProjectDocument.updateNote(_ note: NoteEvent, inTrackAt trackIndex: Int)`, `ProjectDocument.deleteNotes(ids: Set<UUID>, inTrackAt trackIndex: Int)`. Used by `AppState` (Task 3).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ProjectModelTests/ProjectDocumentTests.swift` (inside the existing `@MainActor final class ProjectDocumentTests: XCTestCase { ... }`):

```swift
    func testUpdateNoteReplacesMatchingNote() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        var updated = note
        updated.pitch = 64
        doc.updateNote(updated, inTrackAt: 0)

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].pitch, 64)
        XCTAssertEqual(doc.project.tracks[0].regions[0].notes.count, 1)
    }

    func testUpdateNoteIsNotUndoRegistered() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        var updated = note
        updated.pitch = 64
        doc.updateNote(updated, inTrackAt: 0)

        XCTAssertFalse(doc.undoManager.canUndo)
    }

    func testDeleteNotesRemovesMatchingNotes() {
        let noteA = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let noteB = NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [noteA, noteB])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.deleteNotes(ids: [noteA.id], inTrackAt: 0)

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes.count, 1)
        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].id, noteB.id)
    }

    func testUndoRestoresDeletedNotes() {
        let noteA = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let noteB = NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [noteA, noteB])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.deleteNotes(ids: [noteA.id], inTrackAt: 0)
        doc.undoManager.undo()

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes.count, 2)
        XCTAssertTrue(doc.project.tracks[0].regions[0].notes.contains(where: { $0.id == noteA.id }))
    }

    func testRedoRemovesNotesAgain() {
        let noteA = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [noteA])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.deleteNotes(ids: [noteA.id], inTrackAt: 0)
        doc.undoManager.undo()
        doc.undoManager.redo()

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes.count, 0)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectDocumentTests`
Expected: FAIL — `updateNote`/`deleteNotes` do not exist yet.

- [ ] **Step 3: Write the implementation**

In `Sources/ProjectModel/ProjectDocument.swift`, insert the following between the end of `insertTrack(_:at:)` and the start of `setTempo(_:)`:

```swift
    public func updateNote(_ note: NoteEvent, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        guard let noteIndex = project.tracks[trackIndex].regions[regionIndex].notes.firstIndex(where: { $0.id == note.id }) else { return }
        project.tracks[trackIndex].regions[regionIndex].notes[noteIndex] = note
    }

    public func deleteNotes(ids: Set<UUID>, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        let removedNotes = project.tracks[trackIndex].regions[regionIndex].notes.filter { ids.contains($0.id) }
        guard !removedNotes.isEmpty else { return }
        project.tracks[trackIndex].regions[regionIndex].notes.removeAll { ids.contains($0.id) }
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.restoreNotes(removedNotes, inTrackAt: trackIndex)
            }
        }
    }

    private func restoreNotes(_ notes: [NoteEvent], inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        project.tracks[trackIndex].regions[regionIndex].notes.append(contentsOf: notes)
        let ids = Set(notes.map(\.id))
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.deleteNotes(ids: ids, inTrackAt: trackIndex)
            }
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectDocumentTests`
Expected: PASS (16 tests: the 11 pre-existing plus the 5 new ones).

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all tests pass, no regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectModel/ProjectDocument.swift Tests/ProjectModelTests/ProjectDocumentTests.swift
git commit -m "Add note update/delete to ProjectDocument"
```

---

## Task 3: `AppState` — Note Selection

**Files:**
- Modify: `Sources/MeridianStudioApp/AppState.swift`

**Interfaces:**
- Consumes: `ProjectDocument.updateNote`/`deleteNotes` (Task 2), `NoteEvent` (Task 1).
- Produces: `AppState.selectedNoteID: UUID?` (published), `AppState.selectNote(id: UUID?)`, `AppState.moveOrResizeSelectedNote(to: NoteEvent)`, `AppState.deleteSelectedNote()`. Used by `PianoRollView` (Task 4).

No automated tests for this task — matches the project's established precedent for `AppState` (no test target for the app layer).

- [ ] **Step 1: Add the published property**

In `Sources/MeridianStudioApp/AppState.swift`, replace:

```swift
    /// The track armed for recording and shown in the piano roll. Clamped into
    /// range whenever tracks are added or removed, and reset to 0 by
    /// `bindDocument()` whenever `document` is replaced wholesale.
    @Published var selectedTrackIndex: Int = 0
```

with:

```swift
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
```

- [ ] **Step 2: Add the note-editing methods**

Add these methods at the end of the `AppState` class, after `toggleSolo(at:)` and before the closing brace:

```swift

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
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/MeridianStudioApp/AppState.swift
git commit -m "Add note selection and edit methods to AppState"
```

---

## Task 4: `PianoRollView` — Select, Move, Resize, Delete

**Files:**
- Modify: `Sources/MeridianStudioApp/PianoRollView.swift`

**Interfaces:**
- Consumes: `AppState.selectedNoteID`, `.selectNote(id:)`, `.moveOrResizeSelectedNote(to:)`, `.deleteSelectedNote()` (Task 3).

No automated tests for this task — matches the project's established precedent for SwiftUI gesture handling (no UI testing harness). Verified by build and the manual smoke test.

If you hit a genuine compiler error in the code below that isn't a trivial, faithful-to-intent fix, STOP and report BLOCKED with root-cause analysis rather than guessing — this has happened several times already in this project's history with SwiftUI/Swift-6-specific code, so it's a real possibility, not a formality.

- [ ] **Step 1: Replace `PianoRollView.swift`**

```swift
// Sources/MeridianStudioApp/PianoRollView.swift
import SwiftUI
import ProjectModel

struct PianoRollView: View {
    @EnvironmentObject var appState: AppState
    @State private var dragStartNote: NoteEvent?

    private let pixelsPerBeat: CGFloat = 40
    private let pixelsPerSemitone: CGFloat = 6
    private let lowestPitch: UInt8 = 36
    private let highestPitch: UInt8 = 96
    private let liveIndicatorWidth: CGFloat = 24
    private let resizeHandleWidth: CGFloat = 6
    private let minimumNoteLengthBeats: Double = 0.0625

    private var notes: [NoteEvent] {
        guard appState.document.project.tracks.indices.contains(appState.selectedTrackIndex) else { return [] }
        return appState.document.project.tracks[appState.selectedTrackIndex].regions.last?.notes ?? []
    }

    /// Pitches currently held on the MIDI keyboard, sorted so the view has a stable
    /// `ForEach` identity. These are not part of the project yet — they are the
    /// immediate "this key is down right now" feedback.
    private var heldPitches: [UInt8] {
        appState.liveNotes.keys.sorted()
    }

    private func yOffset(forPitch pitch: UInt8) -> CGFloat {
        CGFloat(Int(highestPitch) - Int(pitch)) * pixelsPerSemitone
    }

    private func clampPitch(_ pitch: Int) -> UInt8 {
        UInt8(min(max(pitch, 0), 127))
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .frame(
                        width: 800,
                        height: CGFloat(highestPitch - lowestPitch) * pixelsPerSemitone
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.selectNote(id: nil)
                    }

                ForEach(notes) { note in
                    noteRectangle(for: note)
                }

                // Live input: one highlighted bar pinned to the left edge per held
                // pitch, so pressing a key is visible immediately whether or not a
                // take is running.
                ForEach(heldPitches, id: \.self) { pitch in
                    Rectangle()
                        .fill(Color.orange.opacity(0.9))
                        .frame(width: liveIndicatorWidth, height: pixelsPerSemitone)
                        .offset(x: 0, y: yOffset(forPitch: pitch))
                }
            }
            .frame(
                width: 800,
                height: CGFloat(highestPitch - lowestPitch) * pixelsPerSemitone,
                alignment: .topLeading
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onDeleteCommand {
            appState.deleteSelectedNote()
        }
    }

    private func noteRectangle(for note: NoteEvent) -> some View {
        let isSelected = appState.selectedNoteID == note.id
        let width = max(CGFloat(note.lengthBeats) * pixelsPerBeat, 4)

        return Rectangle()
            .fill(isSelected ? Color.accentColor : Color.green.opacity(0.8))
            .overlay {
                if isSelected {
                    Rectangle().stroke(Color.white, lineWidth: 1)
                }
            }
            .frame(width: width, height: pixelsPerSemitone)
            .offset(x: CGFloat(note.startBeat) * pixelsPerBeat, y: yOffset(forPitch: note.pitch))
            .contentShape(Rectangle())
            .onTapGesture {
                appState.selectNote(id: note.id)
            }
            .gesture(moveGesture(for: note))
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: resizeHandleWidth, height: pixelsPerSemitone)
                    .gesture(resizeGesture(for: note))
            }
    }

    private func moveGesture(for note: NoteEvent) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStartNote ?? note
                if dragStartNote == nil { dragStartNote = note }
                let deltaBeats = Double(value.translation.width / pixelsPerBeat)
                let deltaPitch = -Int((value.translation.height / pixelsPerSemitone).rounded())
                var updated = start
                updated.startBeat = max(start.startBeat + deltaBeats, 0)
                updated.pitch = clampPitch(Int(start.pitch) + deltaPitch)
                appState.selectNote(id: note.id)
                appState.moveOrResizeSelectedNote(to: updated)
            }
            .onEnded { _ in
                dragStartNote = nil
            }
    }

    private func resizeGesture(for note: NoteEvent) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let start = dragStartNote ?? note
                if dragStartNote == nil { dragStartNote = note }
                let deltaBeats = Double(value.translation.width / pixelsPerBeat)
                var updated = start
                updated.lengthBeats = max(start.lengthBeats + deltaBeats, minimumNoteLengthBeats)
                appState.selectNote(id: note.id)
                appState.moveOrResizeSelectedNote(to: updated)
            }
            .onEnded { _ in
                dragStartNote = nil
            }
    }
}
```

Note on the resize handle: it is positioned via `.overlay(alignment: .trailing)` on the already-offset note rectangle, so it must NOT have its own `.offset(...)` call — `alignment: .trailing` already places it at the note's right edge in the note's own (already-positioned) coordinate space. Adding a second offset would double-apply the position.

- [ ] **Step 2: Build**

Run: `rm -rf .build && swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: all tests still pass (this task adds no new tests, but must not break anything).

- [ ] **Step 4: Manual smoke test**

Run: `swift run MeridianStudioApp`

Check (in addition to everything from prior milestones' smoke-test checklists):
- Record a short take, then click on one of the resulting note rectangles in the piano roll — it should visibly highlight (different fill + white outline).
- Click empty space in the piano roll — the highlight should clear.
- Drag a selected note left/right — its horizontal position (timing) should change live.
- Drag a selected note up/down — its vertical position (pitch) should change live.
- Drag the very right edge of a selected note — only its length should change, not its position.
- Select a note and press Delete/Backspace — it should disappear from the piano roll and from the timeline's region.
- Confirm dragging a note doesn't accidentally also trigger the empty-space tap-to-deselect (i.e., the note stays selected and highlighted while you're actively dragging it).

- [ ] **Step 5: Commit**

```bash
git add Sources/MeridianStudioApp/PianoRollView.swift
git commit -m "Add note select/move/resize/delete to PianoRollView"
```

---

## Task 5: Documentation

**Files:**
- Modify: `docs/architecture.md`

**Interfaces:** None — documentation only, reflecting what Tasks 1–4 built.

- [ ] **Step 1: Add a note-editing paragraph**

In `docs/architecture.md`, replace:

```markdown
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

with:

```markdown
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

Note-level editing (Phase 2): `NoteEvent` carries a stable `id` (added
after Phase 1 shipped, with a custom decoder that synthesizes one for
project files saved before this field existed, and an `==` that
ignores `id` so every pre-existing content-based test kept working
unmodified). `ProjectDocument.updateNote` is a field edit (no undo,
matching `setTempo`); `deleteNotes` is a structural removal
(undo-registered, matching `removeRegion`/`removeTrack` — including the
same `MainActor.assumeIsolated` bridge in its undo closure).
`AppState.selectedNoteID` tracks a single selected note; the piano roll
turns drag gestures into `updateNote` calls (move changes
`startBeat`/`pitch`, resize changes only `lengthBeats`) and `Delete`/
`Backspace` into a `deleteNotes` call.
```

- [ ] **Step 2: Commit**

```bash
git add docs/architecture.md
git commit -m "Document note-level editing in architecture.md"
```

- [ ] **Step 3: Push**

```bash
git push origin main
```
