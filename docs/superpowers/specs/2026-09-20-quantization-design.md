# Quantization — Design

Date: 2026-09-20
Status: Approved
Phase: 2 (third and final milestone)

## 1. Scope

The last piece of "Full MIDI editing" from the Phase 0 roadmap
(multi-track ✅, note-level editing ✅, quantization — this milestone).
Notes played slightly off the beat can now be snapped toward a rhythmic
grid, with an adjustable strength — the standard DAW convention (100%
= hard snap, 50% = move halfway toward the grid, 0% = no change),
rather than a blunt on/off snap.

This operates on the **whole current region** (a track's `regions.last`,
matching the existing convention used everywhere else in this app), not
a selection of notes — multi-select was explicitly deferred in the
note-editing milestone, and "quantize the take I just recorded" is the
normal DAW workflow regardless of whether multi-select exists.

Out of scope, explicitly deferred: quantizing note *length* (only
start-time snaps), quantizing a sub-selection of notes (needs
multi-select, not built), swing/groove templates, undo/redo surfaced in
the UI (matches the project's existing, already-documented deferral).

## 2. Pure Logic: `Quantizer`

New file, `ProjectModel`, alongside `Tempo`/`TrackAudibility` — pure,
UI-independent, fully unit-testable:

```swift
public enum Quantizer {
    /// `gridBeats` is the grid spacing in beats (1.0 = quarter-note grid,
    /// 0.5 = eighth, 0.25 = sixteenth, matching this app's existing
    /// beats-as-the-fundamental-unit convention). `strength` is 0...1
    /// (0 = no change, 1 = hard snap to the nearest grid line), clamped.
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

`gridBeats <= 0` is treated as "no grid" and returns notes unchanged
(defends against a stray 0 reaching here from a UI control, rather than
dividing by zero). Only `startBeat` changes; `pitch`/`velocity`/
`lengthBeats` are untouched. `NoteEvent.id` is preserved (the function
maps in place, never reconstructs with a fresh default id).

## 3. `ProjectDocument` — Batch Note Mutation

A quantize pass touches every note in a region at once — conceptually a
batch version of `updateNote`, which is why it follows `updateNote`'s
precedent, not `deleteNotes`'s: **not undo-registered** (matches
`setTempo`/`updateNote` — undo is reserved for structural add/remove
throughout this file, never for field edits, and a batch position edit
is a field edit applied many times over, not a removal).

```swift
public func quantizeNotes(gridBeats: Double, strength: Double, inTrackAt trackIndex: Int) {
    guard project.tracks.indices.contains(trackIndex) else { return }
    guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
    let notes = project.tracks[trackIndex].regions[regionIndex].notes
    project.tracks[trackIndex].regions[regionIndex].notes = Quantizer.quantize(notes, gridBeats: gridBeats, strength: strength)
}
```

Operates on `regions.last`, matching `updateNote`/`deleteNotes`'s
existing convention. No-ops (doesn't crash) for an out-of-range track
index or a track with no regions yet, matching every other method in
this file's guard style.

## 4. `AppState` — Quantize Controls

```swift
@Published var quantizeGridBeats: Double = 0.25   // sixteenth-note grid by default
@Published var quantizeStrength: Double = 1.0      // 100% by default
```

One method:

```swift
func applyQuantization() {
    document.quantizeNotes(gridBeats: quantizeGridBeats, strength: quantizeStrength, inTrackAt: selectedTrackIndex)
}
```

## 5. UI: `QuantizeControlView`

New file, `Sources/MeridianStudioApp/QuantizeControlView.swift` —
`PianoRollView.swift` is already substantial (gesture code from the
note-editing milestone); this stays a separate, focused file rather
than growing that one further, matching this project's established
practice of splitting UI by responsibility.

A thin horizontal toolbar: a `Picker` for grid resolution (labeled
"1/4", "1/8", "1/16", "1/32", bound to `appState.quantizeGridBeats`
via the underlying beats values 1.0/0.5/0.25/0.125), a `Slider` for
strength (0...1, bound to `appState.quantizeStrength`, with a `Text`
showing it as a percentage), and an "Apply" `Button` calling
`appState.applyQuantization()`.

Placement: `ContentView.swift`'s existing
`VStack { TimelineView(); PianoRollView() }` becomes
`VStack { TimelineView(); QuantizeControlView(); PianoRollView() }` —
the control sits directly above the piano roll it acts on.

## 6. Testing

- `QuantizerTests` (new, `ProjectModelTests`): strength 0 leaves notes
  unchanged; strength 1 hard-snaps to the nearest grid line (notes
  before and after a grid line, and a note already exactly on one);
  strength 0.5 moves exactly halfway; different grid resolutions
  (quarter/eighth/sixteenth) produce different nearest-grid answers for
  the same input; `pitch`/`velocity`/`lengthBeats`/`id` are unchanged
  by quantization; `gridBeats <= 0` returns the input unchanged instead
  of crashing.
- `ProjectDocumentTests`: `quantizeNotes` replaces a track's current
  region's notes with the `Quantizer` output and is *not*
  undo-registered (mirrors `updateNote`'s test style exactly); no-ops
  for an out-of-range track index and for a track with no regions.
- `AppState`/`QuantizeControlView`: no automated tests, matching this
  project's established precedent for the app layer and SwiftUI (no
  test harness) — verified by build and the manual smoke test.

## 7. Non-Goals / Explicit Deferrals

- Quantizing note length/duration (only start-time snapping).
- Quantizing a sub-selection of notes (needs multi-select).
- Swing/groove templates (quantizing toward an off-grid pocket rather
  than dead-on-grid).
- Undo/redo surfaced in the UI (pre-existing, already-documented
  deferral).
- A visible grid overlay drawn on the piano roll itself (a natural
  follow-on once quantization exists, but a separate, UI-only slice).
