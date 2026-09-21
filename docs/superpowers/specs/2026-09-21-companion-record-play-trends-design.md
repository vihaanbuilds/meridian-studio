# Meridian Companion — Milestone 1: Record, Play, Basic Trends — Design

Date: 2026-09-21
Status: Approved
Architecture: `docs/superpowers/specs/2026-09-20-two-app-architecture-design.md`

## 1. Scope

The first buildable slice of the companion app (working name "Meridian
Companion," per the architecture spec): a patient can start a session,
the app records via whatever input is available (MIDI keyboard or
microphone), stop ends it and saves it, "Play Last" plays it back, and
a basic trend view shows how often and how long sessions have been
happening over time.

Explicitly out of scope for this milestone (per the architecture
spec's Section 6 and the milestone-scoping decision that chose this
over the larger options): clinician export/sharing, timing-consistency
(motor-precision) metrics, session delete/rename management, undo.
Each is a candidate for its own later milestone, not a gap in this one.

## 2. Storage Model

No manual "Save As" — that friction is appropriate for a musician
managing many projects, not for a patient whose whole interaction with
the app should be "press one button." The app auto-manages its own
session library:

```
~/Library/Application Support/Meridian Companion/Sessions/
  Session-20260921-090612.mstudio
  Session-20260921-143007.mstudio
  Session-20260922-091530.mstudio
  ...
```

- The `Sessions/` directory is created on first launch if absent
  (`FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)`
  + `"Meridian Companion/Sessions"`, `withIntermediateDirectories: true`).
- Each session's filename is `Session-<yyyyMMdd-HHmmss>.mstudio`, the
  timestamp taken at the moment the session is saved (Stop pressed).
  The filename's embedded timestamp — not filesystem creation-date
  metadata, which can be altered by copies/backups/sync tools — is the
  authoritative date source for trend computation (Section 6).
- Every bundle is written via **unmodified** `ProjectStore.save`. No
  change to `ProjectModel` or `AudioEngine` for any of this — this
  entire section is companion-app-only code reading/writing through
  the shared packages' existing public API, per the architecture
  spec's Section 6.3 resolution.

## 3. Session Data Shape

Each session bundle holds a `Project` with exactly one `Track`, freshly
created per session (no persistent "the" project — every Start creates
a new one-track `Project` in memory, Stop saves it as a new bundle):

- `Track.kind` is `.midi` or `.audio`, decided at Start time by
  modality detection (Section 4).
- The track's `regions`/`audioRegions` holds exactly one region — the
  session just recorded.
- Tempo: a fixed default (120 BPM, matching every other new project in
  this codebase's existing default) — the companion app exposes no
  tempo control, so this only matters as the divisor/multiplier
  `Tempo.seconds(forBeats:tempo:)` already uses for duration math
  (Section 6).

No multi-track, no manual region editing, no piano roll — consistent
with the architecture spec's Section 6.2.

## 4. Modality Auto-Detection

At the moment "Start Session" is pressed:

```swift
import CoreMIDI

var hasMIDIDevice: Bool {
    MIDIGetNumberOfSources() > 0
}
```

- **`hasMIDIDevice == true`**: start a fresh `.midi`-kind `Track`,
  record via `CoreMIDIInput`/`MIDIRecorder` exactly as
  `MeridianStudioApp` already does, producing a `MIDIRegion` on Stop.
- **`hasMIDIDevice == false`**: start a fresh `.audio`-kind `Track`,
  record via `AudioRecorder` exactly as `MeridianStudioApp` already
  does, producing an `AudioRegion` on Stop.

This is a plain CoreMIDI framework call made directly in
`MeridianCompanionApp`'s own code — no addition to `AudioEngine` is
needed; `CoreMIDIInput` itself doesn't need to expose a "has sources"
check for this to work. Detection happens fresh at every Start (not
cached at launch), since a keyboard could be plugged in or unplugged
between one session and the next.

**Known, carried-forward limitation, not solved by this milestone:** if
no MIDI device is present and microphone permission is denied, the
audio fallback still "succeeds" — `installTap` doesn't fail on a denied
permission, it just receives silence (the same gap identified as F10 in
the audio-recording final review on the `MeridianStudioApp` side). A
patient could end up with a session that "recorded" nothing and no
error anywhere. Worth an explicit item on this milestone's manual smoke
test (record once with mic access denied and no MIDI device, confirm
what actually happens), but a real fix — detecting and surfacing this
— is deferred to whichever milestone tackles export/error-reporting
more generally.

## 5. Recording UI

- One large `Button`-based Start/Stop control — a single element, not a
  compound gesture, so Switch Control's scanning cursor can land on it
  in one step.
- A live level meter while recording, polled from whichever recorder
  is active (`AudioRecorder.level` or a MIDI-side activity indicator —
  MIDI has no continuous "level" the way audio does, so the MIDI case
  shows a simple on/off "note currently sounding" indicator instead of
  a bar, reusing the existing `liveNotes`-style pattern
  `MeridianStudioApp.AppState` already has for this exact purpose).
- **`MeridianCompanionApp` gets its own `LevelMeterView.swift`**,
  visually similar to `MeridianStudioApp`'s but a separate file — the
  companion app cannot import `MeridianStudioApp`, so this is
  deliberate, accepted duplication (a handful of lines), not an
  oversight. Matches the architecture spec's Section 2 cost/benefit
  reasoning.
- No confirmation dialogs, no intermediate screens between "app is
  open" and "a session can start."

## 6. Playback

A "Play Last Session" control, enabled once at least one session
exists, plays the most recently saved bundle's single region via
`PlaybackEngine.play(regions:audioRegions:tempo:)` — reused exactly
as-is (resolving the one audio region's `fileName` against that
session bundle's own `audio/` directory when the last session was
audio-kind, or passing its one `MIDIRegion` through when MIDI-kind).
No "play any session," no scrubbing — always the most recent one, kept
deliberately simple for v1.

## 7. Trend View — Two Modality-Agnostic Metrics

Two metrics were considered further (note/activity count per session)
and dropped for v1 specifically because they aren't computable
uniformly across both modalities — a MIDI session has a meaningful note
count, an audio session doesn't. Rather than show an asymmetric UI
depending on what hardware a given day happened to use, v1 sticks to
the two metrics that mean the same thing regardless of modality:

- **Session frequency** — did a session happen on a given day, this
  week, this month.
- **Session duration** — `Tempo.seconds(forBeats: region.lengthBeats, tempo: project.tempo)`,
  computed identically whether the region is a `MIDIRegion` or an
  `AudioRegion` (both carry `lengthBeats`).

### Computation

```swift
struct SessionSummary: Identifiable {
    let id: URL           // the bundle's own URL — unique per session
    let date: Date         // parsed from the filename's embedded timestamp
    let kind: TrackKind
    let durationSeconds: Double
}

func loadSessionHistory() throws -> [SessionSummary] {
    let sessionsURL = /* Application Support/Meridian Companion/Sessions */
    let bundleURLs = try FileManager.default.contentsOfDirectory(at: sessionsURL, includingPropertiesForKeys: nil)
    return try bundleURLs.compactMap { url in
        guard let date = parseSessionDate(from: url.lastPathComponent) else { return nil }
        let project = try ProjectStore.load(from: url)
        guard let track = project.tracks.first else { return nil }
        let lengthBeats = track.kind == .audio
            ? (track.audioRegions.first?.lengthBeats ?? 0)
            : (track.regions.first?.lengthBeats ?? 0)
        let durationSeconds = Tempo.seconds(forBeats: lengthBeats, tempo: project.tempo)
        return SessionSummary(id: url, date: date, kind: track.kind, durationSeconds: durationSeconds)
    }
}
```

Every call here (`ProjectStore.load`, `Tempo.seconds(forBeats:tempo:)`,
`Track`/`MIDIRegion`/`AudioRegion`'s public properties) is existing,
unmodified `ProjectModel` API. `loadSessionHistory()` itself lives in
`MeridianCompanionApp`, never in the shared packages.

### View

A basic Swift Charts (`import Charts`, built into macOS 14+, no new
dependency, consistent with this project's "no third-party dependency
without documented reason" rule) bar chart: one bar per session, x-axis
date, y-axis duration in seconds/minutes. No zooming, filtering, or
date-range picker in v1 — the whole history, plainly shown.

## 8. Accessibility

- Every interactive control uses standard SwiftUI `Button`/native
  control types (not custom gesture-only views), since these get
  reasonable Switch Control scanning support by default.
- Generous hit targets and spacing on the Start/Stop control
  specifically — it's the one control every session depends on.
- `.accessibilityLabel` set explicitly on the Start/Stop control and
  the level meter (a bar has no meaningful default label).
- Manual smoke test for this milestone (added to the standing
  no-automated-UI-test precedent) explicitly includes a real macOS
  Switch Control pass, not just VoiceOver — per the architecture
  spec's Section 8.

## 9. `CompanionState` — the App-Layer Glue

Mirrors `MeridianStudioApp.AppState`'s role and shape (an
`@MainActor ObservableObject`) but is its own type in
`MeridianCompanionApp`, not shared:

```swift
@MainActor
final class CompanionState: ObservableObject {
    @Published var isRecording = false
    @Published var level: Float = 0
    @Published var sessions: [SessionSummary] = []

    private let midiInput = CoreMIDIInput()
    private let playbackEngine = PlaybackEngine()
    private let audioRecorder: AudioRecorder
    private var midiRecorder: MIDIRecorder?
    // ... recordingClock, queue-polling timer: same established
    // patterns as AppState, not restated here — the implementation
    // plan carries the exact code.

    func startSession() { /* Section 4 modality check, then start whichever recorder */ }
    func stopSession() { /* stop, save bundle per Section 2, refresh sessions */ }
    func playLastSession() { /* Section 6 */ }
    func refreshSessionHistory() { /* Section 7's loadSessionHistory() */ }
}
```

## 10. Testing

- **`MeridianCompanionAppTests`** (real tests, not just the current
  shell placeholder): `loadSessionHistory()`/`SessionSummary`
  computation against hand-built fixture bundles on disk (both MIDI-
  and audio-kind), filename date parsing (valid and malformed
  filenames), duration computation for both track kinds.
- **`CompanionState`**, the recording/playback wiring, and the SwiftUI
  views: no automated tests, matching this project's established
  precedent for `AppState`/UI/hardware-adjacent code everywhere else.
  Verified by build and the manual smoke test (Section 8).

## 11. Non-Goals (restated and expanded from Section 1)

- Clinician export/sharing (a later milestone, per the architecture
  spec's Section 6.5).
- Timing-consistency/motor-precision metrics (a later milestone; the
  underlying `NoteEvent.startBeat` data is already being recorded and
  saved, so nothing here blocks adding it later).
- Session delete/rename/management UI.
- Undo/redo (no editing surface exists in this app to need it).
- Playing any session other than the most recent one.
- Any change to `ProjectModel` or `AudioEngine` (this entire milestone
  is achievable through their existing public APIs).
- Any change to `MeridianStudioApp`.

## 12. Assumptions Log

- Default tempo 120 BPM for every session project, matching this
  codebase's existing `Project`/`Track` default elsewhere.
- Session bundles are never moved/renamed by hand by the patient — the
  filename-embedded timestamp is trusted as authoritative. A future
  milestone that needs to tolerate manual file tampering can revisit
  this.
- macOS Application Support directory is an acceptable storage location
  for now; a future milestone may need to reconsider this once the
  regulatory question (architecture spec Section 6.6) is resolved.
