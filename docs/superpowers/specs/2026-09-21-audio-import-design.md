# Importing Existing Audio Files — Design

Date: 2026-09-21
Status: Approved
Phase: 3 (second milestone)

## 1. Scope

The audio-recording milestone's own spec explicitly deferred this:
"Importing existing audio files (explicitly required for a later
Phase 3 milestone, not this one)." This milestone is that later
milestone — nothing more.

A musician picks an existing audio file from disk (a recording made
outside Meridian Studio, a sample, a reference track) and it becomes
an `AudioRegion` on a track, exactly as if it had been recorded inside
the app.

Deliberately out of scope, same "smallest useful slice" discipline
every prior milestone in this project has used:

- Multi-file import in one action (single file only this milestone).
- Waveform rendering (still the later milestone's job — regions render
  as plain colored blocks, matching how recorded regions already do).
- Any audio editing (trim/split/fade/normalize/transcode).
- Drag-and-drop import (menu-driven only, matching every other
  file-picking flow in this app — New/Open/Save all use
  `NSOpenPanel`/`NSSavePanel`, never drag targets).

## 2. Entry Point

A new "Import Audio…" item in the File menu
(`MeridianStudioApp.swift`'s existing `CommandGroup(replacing: .newItem)`,
alongside New/Open/Save/Save As), opening an `NSOpenPanel` filtered to
`UTType.audio` — the one system-defined UTType that already covers
WAV/AIFF/MP3/M4A/AAC/CAF/FLAC/etc., so no per-format allowlist needs
maintaining here or extending later when a new format matters.

Same "must save first" constraint the recording milestone already
established, reused verbatim in spirit: importing copies a file into
the project bundle's `audio/` directory, which requires `fileURL` to
be non-nil. Blocked with an alert, not a silent failure, matching
`AudioRecordingError.projectNotSaved`'s existing pattern.

## 3. Where the File Goes

If the currently selected track is `.audio`-kind, the user is asked —
a two-button `NSAlert`, not a full custom UI:

> "Add this file to the selected track, or create a new track for it?"
> **[Add to "<track name>"]** **[Create New Track]**

If the selected track is `.midi`-kind (or the selection is otherwise
invalid), there is no genuine choice to make — a new track is created
directly, no prompt shown.

A newly created track is named after the imported file (its filename
without extension), not the generic "Track N" `addTrack()` already
uses for empty tracks — "Guitar Solo.wav" imported becomes a track
named "Guitar Solo". This is the one place track naming diverges from
`addTrack()`'s existing convention, and deliberately so: an imported
file's identity is the file itself, not an ordinal position.

The new region's `startBeat` is placed immediately after whatever
audio content already exists on the target track (`0` for an empty/new
track, or right after the last existing audio region's end otherwise)
— it never overlaps existing content, and needs no user positioning
step this milestone.

## 4. File Handling

The picked file is copied — not transcoded — into
`fileURL/audio/<uuid>.<original-extension>`, the same UUID-based
naming `AudioRecorder`'s own output already uses, preserving the
original extension so format stays intact and diagnosable. `AVAudioFile`
already reads every format `UTType.audio` matches without any
conversion step, so there's no playback reason to transcode, and
copying instead of transcoding avoids both real implementation cost
(an export session) and unnecessary lossy re-encoding of a musician's
existing masters.

```swift
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
```

`unreadableFile` covers a file that passed the panel's `UTType.audio`
filter but still fails to open as audio (corrupt, or a container
format `AVAudioFile` can't decode) — caught after the copy, with the
copied file removed again rather than left as an unreferenced orphan
in the bundle (the exact failure mode the recent Save-As/orphan-bundle
fixes on both apps were about avoiding).

## 5. `AppState+AudioImport.swift`

New extension file, mirroring `AppState+AudioRecording.swift`'s shape
exactly:

```swift
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
```

`ProjectDocument.addAudioRegion`/`addTrack` are reused completely
unmodified — both already undo-registered, structural operations; no
`ProjectModel`/`AudioEngine` change is needed anywhere in this
milestone.

## 6. Timeline Visibility — And a Found, Pre-Existing Bug

`TimelineView.swift` currently only renders `track.regions` (MIDI) —
`track.audioRegions` has never been drawn, for either a recorded or,
until this milestone, an imported region. This milestone adds the
missing `ForEach(track.audioRegions)`, styled identically to the
existing MIDI-region block (a colored rectangle, a small caption
label) but in a visually distinct color so the two kinds are
distinguishable in the same lane. Still no waveform — a plain block,
same as MIDI regions, consistent with this project's existing "level
meter, not waveform" bar for the recording milestone's own visual
feedback.

**While extending this code, a genuine pre-existing bug surfaced in
the MIDI-region rendering it was about to be copied from.** The
current code is:

```swift
ForEach(track.regions) { region in
    Rectangle()
        .fill(Color.accentColor.opacity(0.6))
        .frame(width: CGFloat(region.lengthBeats) * pixelsPerBeat, height: laneHeight)
        .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
        .overlay(alignment: .topLeading) {
            Text("Region").font(.caption2).padding(2)
        }
}
```

This is the exact same modifier-ordering hazard already found and
fixed once in `PianoRollView`'s resize handle (see
`docs/superpowers/plans/2026-09-18-note-editing.md`'s Task 4, whose
Step comments document the fix in detail): `.offset()` is
layout-transparent, so a modifier
placed *after* it in the chain — here, `.overlay(alignment:)` —
positions against the region rectangle's **original, pre-offset**
frame, not its shifted one. For any region with `startBeat == 0` (the
common case for a track's first, and often only, region) the bug is
invisible, since the offset is zero — which is almost certainly why it
has shipped unnoticed since Phase 1. Any region starting later than
beat 0 would show its "Region" caption pinned near the lane's left
edge instead of following the block to its actual position.

**Fix, applied to both the existing MIDI-region block and the new
audio-region block** (`.offset()` moved to be the *last* modifier,
matching the established-correct pattern from the `PianoRollView`
fix):

```swift
ForEach(track.regions) { region in
    Rectangle()
        .fill(Color.accentColor.opacity(0.6))
        .frame(width: CGFloat(region.lengthBeats) * pixelsPerBeat, height: laneHeight)
        .overlay(alignment: .topLeading) {
            Text("Region").font(.caption2).padding(2)
        }
        .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
}
ForEach(track.audioRegions) { region in
    Rectangle()
        .fill(Color.orange.opacity(0.6))
        .frame(width: CGFloat(region.lengthBeats) * pixelsPerBeat, height: laneHeight)
        .overlay(alignment: .topLeading) {
            Text("Audio").font(.caption2).padding(2)
        }
        .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
}
```

This should be verified the same way the `PianoRollView` fix was: a
headless `ImageRenderer` render probe confirming the caption's
rendered position actually follows a non-zero `startBeat`'s offset,
for both region kinds.

## 7. Menu Wiring

In `Sources/MeridianStudioApp/MeridianStudioApp.swift`, the existing
`CommandGroup(replacing: .newItem)` gains one more item after the
Save/Save As pair:

```swift
Divider()
Button("Import Audio…") { appState.importAudio() }
    .keyboardShortcut("i", modifiers: .command)
```

## 8. Testing

- No automated tests for `AppState+AudioImport.swift` — matches this
  project's established precedent for `AppState`/file-picker-driven
  code (`ProjectDocumentIO.swift` has none either, for the same
  reason: it's `NSOpenPanel`/`NSAlert`-driven and not meaningfully
  unit-testable without a real UI).
- `TimelineView`'s fix is verified by the same render-probe technique
  already established for this exact class of bug, not by a unit
  test (SwiftUI view code has no automated tests anywhere in this
  project).
- Manual smoke test (added to the standing, still-pending checklist):
  import a `.wav` and an `.mp3` file, confirm both play back
  correctly; import onto an existing audio track and confirm the
  choice prompt appears and both choices work; try importing into an
  unsaved project and confirm the "must save first" alert appears
  instead of a crash; confirm both a recorded and an imported region
  render at their correct timeline position, including a region that
  does **not** start at beat 0.

## 9. Non-Goals

- Multi-file import.
- Waveform rendering.
- Trim/split/fade/normalize/transcode.
- Drag-and-drop.
- Any change to `ProjectModel`/`AudioEngine` (this milestone is
  achievable entirely through their existing public API).
- Any change to Meridian Companion (this milestone is Meridian
  Studio-only; the two apps remain independently evolving, per the
  two-app architecture spec).
