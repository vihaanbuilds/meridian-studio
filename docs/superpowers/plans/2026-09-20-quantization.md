# Quantization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user snap the notes in the currently selected track's region toward a rhythmic grid, with an adjustable strength (100% = hard snap, 0% = no change) — the last piece of Phase 2's "Full MIDI editing" milestone.

**Architecture:** A pure `Quantizer.quantize(_:gridBeats:strength:)` function in `ProjectModel`, a `ProjectDocument.quantizeNotes` method that applies it to a track's current region (not undo-registered, matching `updateNote`'s field-edit precedent), `AppState` state for the two controls plus one method to apply them, and a new small `QuantizeControlView` toolbar placed between the timeline and the piano roll.

**Tech Stack:** Swift 6, SwiftUI, XCTest (runs for real — Xcode is installed).

**Spec:** `docs/superpowers/specs/2026-09-20-quantization-design.md`

## Global Constraints

- Deployment target: macOS 14.0+, zero third-party dependencies (unchanged).
- `swift test` runs for real on this machine — every task with tests must show real RED/GREEN evidence.
- `quantizeNotes` is a field edit (like `updateNote`/`setTempo`), NOT undo-registered — undo is reserved for structural add/remove throughout `ProjectDocument`, never for batch or single field edits.
- Quantization operates on a track's *current* region (`regions.last`), matching every other note/region operation in this app.
- Only `startBeat` changes under quantization; `pitch`, `velocity`, `lengthBeats`, and `id` are untouched.
- `gridBeats <= 0` must not crash (defends against a stray 0 reaching `Quantizer` from a UI control) — return the input unchanged.

---

## Task 1: `Quantizer` Pure Logic

**Files:**
- Create: `Sources/ProjectModel/Quantizer.swift`
- Create: `Tests/ProjectModelTests/QuantizerTests.swift`

**Interfaces:**
- Consumes: `NoteEvent` (existing).
- Produces: `Quantizer.quantize(_ notes: [NoteEvent], gridBeats: Double, strength: Double) -> [NoteEvent]`. Used by `ProjectDocument.quantizeNotes` (Task 2).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/ProjectModelTests/QuantizerTests.swift
import XCTest
@testable import ProjectModel

final class QuantizerTests: XCTestCase {
    func testZeroStrengthLeavesNotesUnchanged() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 0)
        XCTAssertEqual(result[0].startBeat, 0.3, accuracy: 0.0001)
    }

    func testFullStrengthSnapsToNearestGridLineBelow() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.30, lengthBeats: 1)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 1)
        XCTAssertEqual(result[0].startBeat, 0.25, accuracy: 0.0001)
    }

    func testFullStrengthSnapsToNearestGridLineAbove() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.45, lengthBeats: 1)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 1)
        XCTAssertEqual(result[0].startBeat, 0.5, accuracy: 0.0001)
    }

    func testNoteAlreadyOnGridIsUnchangedAtFullStrength() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.5, lengthBeats: 1)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 1)
        XCTAssertEqual(result[0].startBeat, 0.5, accuracy: 0.0001)
    }

    func testHalfStrengthMovesHalfwayToGrid() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.30, lengthBeats: 1)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 0.5)
        // Nearest grid line to 0.30 at 0.25 spacing is 0.25; halfway from 0.30 is 0.275.
        XCTAssertEqual(result[0].startBeat, 0.275, accuracy: 0.0001)
    }

    func testDifferentGridResolutionsProduceDifferentAnswers() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.6, lengthBeats: 1)
        let quarterGrid = Quantizer.quantize([note], gridBeats: 1.0, strength: 1)
        let eighthGrid = Quantizer.quantize([note], gridBeats: 0.5, strength: 1)
        XCTAssertEqual(quarterGrid[0].startBeat, 1.0, accuracy: 0.0001)
        XCTAssertEqual(eighthGrid[0].startBeat, 0.5, accuracy: 0.0001)
    }

    func testOtherFieldsAreUnchanged() {
        let note = NoteEvent(pitch: 67, velocity: 88, startBeat: 0.3, lengthBeats: 1.5)
        let result = Quantizer.quantize([note], gridBeats: 0.25, strength: 1)
        XCTAssertEqual(result[0].id, note.id)
        XCTAssertEqual(result[0].pitch, 67)
        XCTAssertEqual(result[0].velocity, 88)
        XCTAssertEqual(result[0].lengthBeats, 1.5, accuracy: 0.0001)
    }

    func testZeroOrNegativeGridReturnsNotesUnchanged() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let resultZero = Quantizer.quantize([note], gridBeats: 0, strength: 1)
        let resultNegative = Quantizer.quantize([note], gridBeats: -0.25, strength: 1)
        XCTAssertEqual(resultZero[0].startBeat, 0.3, accuracy: 0.0001)
        XCTAssertEqual(resultNegative[0].startBeat, 0.3, accuracy: 0.0001)
    }

    func testStrengthIsClampedOutsideZeroToOne() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.30, lengthBeats: 1)
        let overOne = Quantizer.quantize([note], gridBeats: 0.25, strength: 2.0)
        let underZero = Quantizer.quantize([note], gridBeats: 0.25, strength: -1.0)
        XCTAssertEqual(overOne[0].startBeat, 0.25, accuracy: 0.0001)   // same as strength 1
        XCTAssertEqual(underZero[0].startBeat, 0.3, accuracy: 0.0001) // same as strength 0
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter QuantizerTests`
Expected: FAIL — `Quantizer` does not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/ProjectModel/Quantizer.swift
public enum Quantizer {
    /// `gridBeats` is the grid spacing in beats (1.0 = quarter-note grid, 0.5 =
    /// eighth, 0.25 = sixteenth, matching this app's existing beats-as-the-
    /// fundamental-unit convention). `strength` is 0...1 (0 = no change, 1 = hard
    /// snap to the nearest grid line), clamped. Only `startBeat` changes.
    public static func quantize(_ notes: [NoteEvent], gridBeats: Double, strength: Double) -> [NoteEvent] {
        guard gridBeats > 0 else { return notes }
        let clampedStrength = min(max(strength, 0), 1)
        return notes.map { note in
            var quantized = note
            let nearestGrid = (note.startBeat / gridBeats).rounded() * gridBeats
            quantized.startBeat = note.startBeat + (nearestGrid - note.startBeat) * clampedStrength
            return quantized
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter QuantizerTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all tests pass (58 pre-existing + 9 new = 67), no regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectModel/Quantizer.swift Tests/ProjectModelTests/QuantizerTests.swift
git commit -m "Add Quantizer pure grid-snapping logic"
```

---

## Task 2: `ProjectDocument` — Apply Quantization to a Region

**Files:**
- Modify: `Sources/ProjectModel/ProjectDocument.swift`
- Modify: `Tests/ProjectModelTests/ProjectDocumentTests.swift`

**Interfaces:**
- Consumes: `Quantizer.quantize(_:gridBeats:strength:)` (Task 1).
- Produces: `ProjectDocument.quantizeNotes(gridBeats: Double, strength: Double, inTrackAt trackIndex: Int)`. Used by `AppState.applyQuantization()` (Task 3).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ProjectModelTests/ProjectDocumentTests.swift` (inside the existing `@MainActor final class ProjectDocumentTests: XCTestCase { ... }`):

```swift
    func testQuantizeNotesAppliesQuantizerToCurrentRegion() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 0)

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].startBeat, 0.25, accuracy: 0.0001)
    }

    func testQuantizeNotesIsNotUndoRegistered() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 0)

        XCTAssertFalse(doc.undoManager.canUndo)
    }

    func testQuantizeNotesNoOpsForOutOfRangeTrackIndex() {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0.3, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano", regions: [region])]))

        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 5)

        XCTAssertEqual(doc.project.tracks[0].regions[0].notes[0].startBeat, 0.3, accuracy: 0.0001)
    }

    func testQuantizeNotesNoOpsForTrackWithNoRegions() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        // Should not crash.
        doc.quantizeNotes(gridBeats: 0.25, strength: 1, inTrackAt: 0)
        XCTAssertTrue(doc.project.tracks[0].regions.isEmpty)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectDocumentTests`
Expected: FAIL — `quantizeNotes` does not exist yet.

- [ ] **Step 3: Write the implementation**

In `Sources/ProjectModel/ProjectDocument.swift`, insert the following between the end of `restoreNotes(_:inTrackAt:)` and the start of `setTempo(_:)`:

```swift
    public func quantizeNotes(gridBeats: Double, strength: Double, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        let notes = project.tracks[trackIndex].regions[regionIndex].notes
        project.tracks[trackIndex].regions[regionIndex].notes = Quantizer.quantize(notes, gridBeats: gridBeats, strength: strength)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectDocumentTests`
Expected: PASS (25 tests: the 21 pre-existing plus the 4 new ones).

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all tests pass, no regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectModel/ProjectDocument.swift Tests/ProjectModelTests/ProjectDocumentTests.swift
git commit -m "Add quantizeNotes to ProjectDocument"
```

---

## Task 3: `AppState` — Quantize Controls

**Files:**
- Modify: `Sources/MeridianStudioApp/AppState.swift`

**Interfaces:**
- Consumes: `ProjectDocument.quantizeNotes(gridBeats:strength:inTrackAt:)` (Task 2).
- Produces: `AppState.quantizeGridBeats: Double` (published), `AppState.quantizeStrength: Double` (published), `AppState.applyQuantization()`. Used by `QuantizeControlView` (Task 4).

No automated tests for this task — matches the project's established precedent for `AppState` (no test target for the app layer).

- [ ] **Step 1: Add the published properties**

In `Sources/MeridianStudioApp/AppState.swift`, replace:

```swift
    /// The single selected note in the piano roll, if any. Not reset when the
    /// selected track changes or a document is swapped — `PianoRollView` only ever
    /// shows the current track's notes, so a stale id simply matches nothing,
    /// which is visually equivalent to no selection without duplicating the reset
    /// logic `bindDocument()` already owns for `selectedTrackIndex`.
    @Published var selectedNoteID: UUID?
```

with:

```swift
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
```

- [ ] **Step 2: Add `applyQuantization()`**

Add this method at the end of the `AppState` class, after `deleteSelectedNote()` and before the closing brace:

```swift

    func applyQuantization() {
        document.quantizeNotes(gridBeats: quantizeGridBeats, strength: quantizeStrength, inTrackAt: selectedTrackIndex)
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/MeridianStudioApp/AppState.swift
git commit -m "Add quantize controls and applyQuantization to AppState"
```

---

## Task 4: `QuantizeControlView` — UI

**Files:**
- Create: `Sources/MeridianStudioApp/QuantizeControlView.swift`
- Modify: `Sources/MeridianStudioApp/ContentView.swift`

**Interfaces:**
- Consumes: `AppState.quantizeGridBeats`, `.quantizeStrength`, `.applyQuantization()` (Task 3).

No automated tests for this task — matches the project's established precedent for SwiftUI views (no UI testing harness). Verified by build and the manual smoke test.

- [ ] **Step 1: Create `QuantizeControlView.swift`**

```swift
// Sources/MeridianStudioApp/QuantizeControlView.swift
import SwiftUI

struct QuantizeControlView: View {
    @EnvironmentObject var appState: AppState

    private let gridOptions: [(label: String, beats: Double)] = [
        ("1/4", 1.0),
        ("1/8", 0.5),
        ("1/16", 0.25),
        ("1/32", 0.125)
    ]

    var body: some View {
        HStack {
            Text("Quantize").font(.headline)

            Picker("Grid", selection: $appState.quantizeGridBeats) {
                ForEach(gridOptions, id: \.beats) { option in
                    Text(option.label).tag(option.beats)
                }
            }
            .frame(width: 100)

            Slider(value: $appState.quantizeStrength, in: 0...1)
                .frame(width: 120)
            Text("\(Int(appState.quantizeStrength * 100))%")
                .frame(width: 40, alignment: .leading)
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Apply") {
                appState.applyQuantization()
            }

            Spacer()
        }
        .padding(8)
    }
}
```

- [ ] **Step 2: Wire it into `ContentView`**

In `Sources/MeridianStudioApp/ContentView.swift`, replace:

```swift
                VStack(spacing: 0) {
                    TimelineView()
                    PianoRollView()
                }
```

with:

```swift
                VStack(spacing: 0) {
                    TimelineView()
                    QuantizeControlView()
                    PianoRollView()
                }
```

- [ ] **Step 3: Build**

Run: `rm -rf .build && swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: all tests still pass (this task adds no new tests, but must not break anything).

- [ ] **Step 5: Manual smoke test**

Run: `swift run MeridianStudioApp`

Check (in addition to everything from prior milestones' smoke-test checklists):
- A "Quantize" toolbar with a grid picker, a strength slider, a percentage label, and an "Apply" button appears between the timeline and the piano roll.
- Record a take with a few notes played slightly off the beat.
- Set the grid to "1/16", strength to 100%, click Apply — notes should visibly snap to the nearest sixteenth-note grid line in the piano roll.
- Undo that with a fresh take, set strength to 50%, click Apply — notes should move partway toward the grid, not all the way.
- Changing the grid resolution and clicking Apply again should re-quantize against the new grid.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeridianStudioApp/QuantizeControlView.swift Sources/MeridianStudioApp/ContentView.swift
git commit -m "Add QuantizeControlView and wire it into ContentView"
```

---

## Task 5: Documentation

**Files:**
- Modify: `docs/architecture.md`

**Interfaces:** None — documentation only, reflecting what Tasks 1–4 built.

- [ ] **Step 1: Add a quantization paragraph**

In `docs/architecture.md`, replace:

```markdown
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

with:

```markdown
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

Quantization (Phase 2, the last piece of "Full MIDI editing"):
`Quantizer.quantize(_:gridBeats:strength:)` is pure logic in
`ProjectModel` — for each note, it moves `startBeat` toward the nearest
grid line by `strength` (0...1, clamped; 0 = no change, 1 = a hard
snap), leaving every other field untouched.
`ProjectDocument.quantizeNotes` applies it to a track's current region
and, like `updateNote`, is a field edit with no undo registration — a
batch position edit is conceptually many field edits, not a removal.
It operates on the whole region rather than a selection, since
multi-select doesn't exist yet.
```

- [ ] **Step 2: Commit**

```bash
git add docs/architecture.md
git commit -m "Document quantization in architecture.md"
```

- [ ] **Step 3: Push**

```bash
git push origin main
```
