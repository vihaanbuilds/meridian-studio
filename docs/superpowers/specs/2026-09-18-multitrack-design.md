# Multi-Track Support — Design

Date: 2026-09-18
Status: Approved
Phase: 2 (first milestone)

## 1. Scope

Phase 1 shipped a `Project.tracks: [Track]` data model that already
supports multiple tracks, but every consumer of it hardcodes track index
0: recording always writes to `tracks[0]`, playback only ever reads
`tracks[0]`, the piano roll only shows `tracks[0]`, the timeline
flattens every track's regions into one visual lane, and `Track.muted`/
`Track.solo` are inert fields with no UI and no playback effect.

This milestone makes multi-track actually work:

- Add / remove tracks.
- Select which track is armed for recording and shown in the piano roll.
- Per-track lanes in the timeline.
- Functional mute/solo affecting playback.

Out of scope (deferred to a later slice, same as Phase 1's own
decomposition): quantization, and note-level editing (move/resize/
delete/select/copy-paste individual notes). A track still holds at most
one *effective* region for playback/display purposes (`regions.last`,
matching Phase 1's existing convention) — richer per-region editing is
a separate future slice, not part of "multi-track."

## 2. Data Model Changes (ProjectModel)

### `ProjectDocument` — structural track operations (undo-registered)

Mirrors the existing `addRegion`/`removeRegion` pattern exactly:

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

Identify tracks by `id` (not index) for add/remove, since indices shift
as tracks are added/removed — unlike `addRegion`/`removeRegion`, which
take an explicit `trackIndex` because regions live *within* a fixed
track. `insertTrack` is private — it exists only to make undo of a
removal re-insert at the original position; callers only ever call
`addTrack`/`removeTrack`.

### `ProjectDocument` — field mutations (not undo-registered)

Same precedent as the existing `setTempo` (a direct field mutation, no
undo registration — undo is reserved for structural add/remove, per
Phase 1's existing split):

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

### `Track` — audibility rule (new pure logic, `ProjectModel`)

Standard DAW convention: if any track is soloed, only soloed tracks are
audible (mute is ignored for soloed tracks — solo overrides mute); if
no track is soloed, every non-muted track is audible.

```swift
public enum TrackAudibility {
    public static func audibleTracks(in tracks: [Track]) -> [Track] {
        let soloed = tracks.filter { $0.solo }
        if !soloed.isEmpty { return soloed }
        return tracks.filter { !$0.muted }
    }
}
```

Pure, UI-independent, fully unit-testable — lives in `ProjectModel`
alongside `Tempo`/`ProjectStore`, not in the app layer.

## 3. MIDIEngine Change: `PlaybackEngine` Plays Multiple Regions

Today `PlaybackEngine.play(region:tempo:)` calls `stopAllNotes()` as its
first line, then schedules one region's notes. Playing multiple tracks
by calling `play(region:tempo:)` once per track would have each
subsequent call's `stopAllNotes()` cancel the previous call's
just-scheduled tasks — a real bug, not a hypothetical.

Fix: change the signature to accept every region to play in one call,
so `stopAllNotes()` runs exactly once:

```swift
public func play(regions: [MIDIRegion], tempo: Double) {
    stopAllNotes()
    for region in regions {
        for scheduled in PlaybackScheduler.schedule(region: region, tempo: tempo) {
            // ... existing per-note Task scheduling, unchanged ...
        }
    }
}
```

`PlaybackScheduler.schedule(region:tempo:)` itself is untouched — it
already operates on one region at a time; `play` just calls it in a
loop now instead of once.

## 4. AppState Changes

- New `@Published var selectedTrackIndex: Int = 0` — the track armed
  for recording and shown in the piano roll. Clamped into range
  whenever tracks are added/removed (if the selected track is removed,
  fall back to `max(selectedTrackIndex - 1, 0)`, or `0` if the project
  has no tracks left — though a project is never expected to reach zero
  tracks in practice, guard for it anyway).
- `stopRecording()`: `document.addRegion(region, toTrackAt: 0)` →
  `document.addRegion(region, toTrackAt: selectedTrackIndex)`.
- `play()`: compute `TrackAudibility.audibleTracks(in: document.project.tracks)`,
  take each audible track's `regions.last` (skip tracks with no
  regions), and call the new `playbackEngine.play(regions:tempo:)` with
  that list. The existing `isPlaying`/`playbackCompletionTask` duration
  logic extends naturally: duration is the *maximum* end-beat across
  all the regions being played, not a single region's.
- New methods: `selectTrack(at:)`, `addTrack()` (generates a name like
  "Track \(tracks.count + 1)", calls `document.addTrack`, and selects
  the new track), `removeTrack(at:)` (looks up the id at that index,
  calls `document.removeTrack(id:)`, clamps `selectedTrackIndex`),
  `toggleMute(at:)`, `toggleSolo(at:)`.

## 5. UI Changes

**`TrackListView`** — each row becomes tappable (sets
`appState.selectedTrackIndex`, visually highlighted when selected via
`.background` on the selected row), gains Mute/Solo toggle buttons
(bound to `track.muted`/`track.solo`, calling `appState.toggleMute`/
`toggleSolo`) and a delete button (calls `appState.removeTrack`, with a
`.disabled` guard so the last remaining track can't be deleted — a
project needs at least one track for recording to have anywhere to go).
A toolbar "+" button above the list calls `appState.addTrack()`.

**`TimelineView`** — replace the single flattened `ZStack` with one
row per track: `ForEach(Array(tracks.enumerated()), id: \.element.id)`,
each row a fixed-height lane (60pt, matching the current region height)
showing only that track's regions, stacked vertically in a `VStack`
inside the existing horizontal `ScrollView` (so the view scrolls
horizontally for time and simply grows vertically with track count — no
new vertical `ScrollView` needed for this milestone's expected track
counts). The selected track's lane gets a subtle background highlight,
consistent with `TrackListView`'s selection indicator.

**`PianoRollView`** — `notes` computed property changes from
`tracks.first?.regions.last?.notes` to a bounds-safe lookup at
`appState.selectedTrackIndex`.

## 6. Testing

- `ProjectDocumentTests`: `addTrack`/`removeTrack` undo/redo (mirrors
  the existing `addRegion`/`removeRegion`/undo/redo tests exactly),
  `setTrackMuted`/`setTrackSolo` field-mutation tests (mirrors
  `setTempo`'s test style).
- New `TrackAudibilityTests` (`ProjectModelTests`): no solo → all
  unmuted tracks audible; one track soloed → only it; multiple tracks
  soloed → all of them; a track that is both muted and soloed → audible
  (solo wins).
- `PlaybackEngine`/UI layer: no automated tests, same as Phase 1's
  precedent for hardware/SwiftUI adapters — verified by `swift build`
  and code review, with the manual smoke test covering the actual
  behavior.

## 7. Non-Goals / Explicit Deferrals

- Renaming a track from the UI (the model supports it via direct
  mutation, but no rename UI is built this milestone — YAGNI until a
  concrete need).
- Reordering tracks.
- Per-region (as opposed to per-track) selection, editing, or deletion.
- Quantization.
- Any AI-layer work (Phases 6+).
