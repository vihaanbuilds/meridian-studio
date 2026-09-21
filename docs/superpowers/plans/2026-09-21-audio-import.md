# Importing Existing Audio Files Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a musician import an existing audio file from disk into
Meridian Studio as an `AudioRegion`, and make audio regions (recorded
or imported) actually visible in the timeline for the first time.

**Architecture:** A new `AppState+AudioImport.swift` extension
(mirroring the existing `AppState+AudioRecording.swift`) handles file
picking, a track-choice prompt, copying the file into the project
bundle, and adding the region — all through `ProjectDocument`'s
existing, unmodified `addTrack`/`addAudioRegion`. `TimelineView.swift`
gains rendering for `track.audioRegions` (never drawn before this
milestone) and, in the same pass, a fix to a genuine pre-existing bug
in the MIDI-region rendering the new code is modeled on.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSOpenPanel`, `NSAlert`),
`AVFoundation`, `UniformTypeIdentifiers` — all already used elsewhere
in this codebase; no new dependency.

**Spec:** `docs/superpowers/specs/2026-09-21-audio-import-design.md`

## Global Constraints

- No changes to `ProjectModel`, `AudioEngine`, or `MeridianCompanionApp`
  — this milestone is achievable entirely through `ProjectModel`'s
  existing public API (`ProjectDocument.addTrack`/`addAudioRegion`,
  `AudioRegion`, `Track`, `Tempo`).
- Single file per import — no multi-file selection this milestone.
- Imported files are copied (never transcoded) into the project
  bundle's `audio/` directory, named `<uuid>.<original-extension>`,
  matching `AudioRecorder`'s own naming convention.
- Importing requires the project to already be saved (`fileURL != nil`)
  — same "must save first" constraint recording already has.
- No automated tests for `AppState+AudioImport.swift` or
  `TimelineView.swift` — matches this project's established precedent
  for file-picker-driven `AppState` code and all SwiftUI view code.

---

### Task 1: `AppState+AudioImport.swift` and Menu Wiring

**Files:**
- Create: `Sources/MeridianStudioApp/AppState+AudioImport.swift`
- Modify: `Sources/MeridianStudioApp/MeridianStudioApp.swift`

**Interfaces:**
- Consumes: `AppState.isRecording`, `.fileURL`, `.document`,
  `.selectedTrackIndex`, `.presentError(_:)` (all pre-existing);
  `ProjectDocument.addTrack(_:)`/`.addAudioRegion(_:toTrackAt:)`,
  `Track(name:kind:)`, `AudioRegion(startBeat:lengthBeats:fileName:)`,
  `Tempo.beats(forSeconds:tempo:)` (all pre-existing, unmodified).
- Produces: `AppState.importAudio()`. Used by
  `MeridianStudioApp.swift`'s new menu item; no other task in this
  plan consumes it directly.

No automated tests for this task — matches the established precedent
for `AppState`/`NSOpenPanel`-driven code (`ProjectDocumentIO.swift`
has none either).

- [ ] **Step 1: Create the extension file**

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

- [ ] **Step 2: Wire the menu item**

In `Sources/MeridianStudioApp/MeridianStudioApp.swift`, replace:

```swift
                Button("Save") { appState.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { appState.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
```

with:

```swift
                Button("Save") { appState.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { appState.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Import Audio…") { appState.importAudio() }
                    .keyboardShortcut("i", modifiers: .command)
            }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests still pass — this task adds no new
tests, and touches no file any existing test covers.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeridianStudioApp/AppState+AudioImport.swift Sources/MeridianStudioApp/MeridianStudioApp.swift
git commit -m "Add audio file import via File > Import Audio…"
```

---

### Task 2: `TimelineView` — Render Audio Regions, Fix a Pre-Existing Offset Bug

**Files:**
- Modify: `Sources/MeridianStudioApp/TimelineView.swift`

**Interfaces:**
- Consumes: `Track.audioRegions: [AudioRegion]` (pre-existing,
  unmodified — already populated by both the recording milestone and
  Task 1's import).
- Produces: nothing consumed by another task in this plan — this is
  purely a rendering change.

No automated tests for this task — matches this project's established
precedent that no SwiftUI view code has automated tests anywhere in
this codebase. Verified by build and, at review time, the same headless
`ImageRenderer` render-probe technique already used once before for
this exact class of bug (see the note in Step 1 below).

- [ ] **Step 1: Replace the whole file**

**Context for whoever implements this:** the existing MIDI-region
rendering below has a real, pre-existing bug being fixed in the same
pass as the new audio-region code that's modeled on it. `.offset()` is
layout-transparent in SwiftUI: a modifier placed *after* it in a
modifier chain (here, `.overlay(alignment:)`) positions against the
view's *original, pre-offset* frame, not the shifted one. The existing
code applies `.overlay()` *after* `.offset()`, so the "Region" caption
has always rendered pinned to the lane's left edge rather than
following the block to its actual position — invisible only because
every region shipped so far happens to start at beat 0, where the
offset is zero. This is the identical mistake already found and fixed
once before in `PianoRollView`'s resize handle (see
`docs/superpowers/plans/2026-09-18-note-editing.md`'s Task 4). The fix
is the same: move `.offset()` to be the *last* modifier in the chain.

Replace the full contents of `Sources/MeridianStudioApp/TimelineView.swift`:

```swift
// Sources/MeridianStudioApp/TimelineView.swift
import SwiftUI

struct TimelineView: View {
    @EnvironmentObject var appState: AppState
    private let pixelsPerBeat: CGFloat = 40
    private let laneHeight: CGFloat = 60
    /// Ceiling on the timeline's own height (four lanes' worth). Without it the
    /// stack grew one lane per track and squeezed `PianoRollView` to nothing in a
    /// minimum-size window; lanes past the cap are reached by scrolling vertically.
    private let maxVisibleHeight: CGFloat = 240

    private var totalHeight: CGFloat {
        CGFloat(appState.document.project.tracks.count) * laneHeight
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(appState.document.project.tracks.enumerated()), id: \.element.id) { index, track in
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(index == appState.selectedTrackIndex ? Color.accentColor.opacity(0.1) : Color.clear)
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
                    }
                    .frame(minWidth: 800, minHeight: laneHeight, alignment: .topLeading)
                    Divider()
                }
            }
        }
        .frame(height: min(max(80, totalHeight), maxVisibleHeight))
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: all pre-existing tests still pass — this task adds no new
tests.

- [ ] **Step 4: Commit**

```bash
git add Sources/MeridianStudioApp/TimelineView.swift
git commit -m "Render audio regions in the timeline; fix pre-existing offset/overlay ordering bug"
```

---

## Self-Review Notes (completed during plan authoring)

- **Spec coverage:** Spec §2 (entry point) → Task 1 Step 2. §3 (target
  choice, naming, placement) → Task 1 Step 1. §4 (copy-not-transcode,
  error cases) → Task 1 Step 1. §5 (`AppState+AudioImport.swift`) →
  Task 1 Step 1, verbatim. §6 (timeline visibility + the found offset
  bug) → Task 2 Step 1, verbatim. §7 (menu wiring) → Task 1 Step 2,
  verbatim. §8 (testing) → reflected in both tasks' "no automated
  tests" notes and this plan's Global Constraints. §9 (non-goals) →
  simply not built; nothing in either task exceeds them. No gaps found.
- **Placeholder scan:** no TBD/TODO; both tasks give complete,
  verbatim code.
- **Type consistency:** `AppState.importAudio()` (Task 1) is the exact
  method name Task 1's own menu wiring calls
  (`appState.importAudio()`) — no other task references it. Task 2 is
  fully independent of Task 1's new code (it only reads
  `Track.audioRegions`, which already existed before this plan) and
  could technically execute in either order; kept as Task 2 since the
  spec presents it second and it's the smaller, more isolated change.
