# Meridian Companion Milestone 1: Record, Play, Trends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the companion app's first real feature set on top of its
existing empty-shell target: auto-detected MIDI/audio session recording
into per-session `.mstudio` bundles, playback of the most recent session,
and a basic trend view of session frequency/duration over time.

**Architecture:** All new code lives in `Sources/MeridianCompanionApp/`
and `Tests/MeridianCompanionAppTests/`, consuming `ProjectModel`/
`AudioEngine`'s existing public API unchanged. A new `SessionLibrary`
enum owns session-bundle naming/scanning/history (pure, fully unit
tested); a new `CompanionState` (`@MainActor ObservableObject`, mirroring
`MeridianStudioApp.AppState`'s role but its own separate type) owns the
hardware-touching recording/playback glue (no automated tests, matching
this project's established precedent for that layer); new SwiftUI views
replace the placeholder `ContentView`.

**Tech Stack:** Swift 6, SwiftUI, Swift Charts (`import Charts`, built
into macOS 14+, no new dependency), `AVFoundation`, `CoreMIDI` — same
stack `MeridianStudioApp` already uses.

**Spec:** `docs/superpowers/specs/2026-09-21-companion-record-play-trends-design.md`
(and the architecture it builds on,
`docs/superpowers/specs/2026-09-20-two-app-architecture-design.md`)

## Global Constraints

- No changes to `ProjectModel` or `AudioEngine` — every new capability in
  this plan is achieved through their existing public API.
- No changes to `MeridianStudioApp`.
- `MeridianCompanionApp` depends only on `ProjectModel`/`AudioEngine` —
  never imports `MeridianStudioApp` (already true of `Package.swift`;
  no task in this plan touches it).
- No manual "Save As" — session storage is entirely auto-managed under
  `~/Library/Application Support/Meridian Companion/Sessions/`.
- Default tempo is 120 BPM for every session `Project` (matches
  `ProjectModel.Project`'s own existing default).
- Session bundle filenames are `Session-<yyyyMMdd-HHmmss>.mstudio`; that
  embedded timestamp — not filesystem creation-date metadata — is the
  authoritative date source for trend computation.
- The trend view is limited to two modality-agnostic metrics this
  milestone: session frequency and duration. No note-count/timing-
  consistency metrics, no export, no session delete/rename UI, no undo.
- Types/views declared in `MeridianCompanionApp` use plain (internal)
  access, not `public` — it's an executable target, not a library,
  matching `MeridianStudioApp.AppState`'s own existing convention.

---

### Task 1: `SessionLibrary` — Session Naming, Scanning, and History

**Files:**
- Create: `Sources/MeridianCompanionApp/SessionLibrary.swift`
- Test: `Tests/MeridianCompanionAppTests/SessionLibraryTests.swift`

**Interfaces:**
- Produces: `SessionLibrary.sessionsDirectory(baseDirectory:) -> URL`,
  `SessionLibrary.bundleURL(for:in:) -> URL`,
  `SessionLibrary.parseSessionDate(from:) -> Date?`,
  `SessionLibrary.loadHistory(from:) throws -> [SessionSummary]`,
  `SessionSummary` (`Identifiable` via `id: URL`, `Equatable`, with
  `date: Date`, `kind: TrackKind`, `durationSeconds: Double`). Used by
  `CompanionState` (Task 2) and the trend view (Task 3).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/MeridianCompanionAppTests/SessionLibraryTests.swift
import XCTest
import ProjectModel
@testable import MeridianCompanionApp

final class SessionLibraryTests: XCTestCase {
    private func makeTempSessionsDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func makeDate(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: string)!
    }

    func testSessionsDirectoryAppendsExpectedPath() {
        let base = URL(fileURLWithPath: "/tmp/base")
        let result = SessionLibrary.sessionsDirectory(baseDirectory: base)
        XCTAssertEqual(result.path, "/tmp/base/Meridian Companion/Sessions")
    }

    func testBundleURLFormatsTimestamp() {
        let sessionsDirectory = URL(fileURLWithPath: "/tmp/sessions")
        let date = makeDate("20260921-143007")
        let url = SessionLibrary.bundleURL(for: date, in: sessionsDirectory)
        XCTAssertEqual(url.lastPathComponent, "Session-20260921-143007.mstudio")
    }

    func testParseSessionDateRoundTripsWithBundleURL() {
        let sessionsDirectory = URL(fileURLWithPath: "/tmp/sessions")
        let date = makeDate("20260921-143007")
        let url = SessionLibrary.bundleURL(for: date, in: sessionsDirectory)
        let parsed = SessionLibrary.parseSessionDate(from: url.lastPathComponent)
        XCTAssertEqual(parsed, date)
    }

    func testParseSessionDateReturnsNilForMalformedFilename() {
        XCTAssertNil(SessionLibrary.parseSessionDate(from: "NotASession.mstudio"))
        XCTAssertNil(SessionLibrary.parseSessionDate(from: "Session-garbage.mstudio"))
        XCTAssertNil(SessionLibrary.parseSessionDate(from: "Session-20260921-143007.txt"))
    }

    func testLoadHistoryReturnsEmptyArrayWhenDirectoryDoesNotExist() throws {
        let sessionsDirectory = makeTempSessionsDirectory()
        let result = try SessionLibrary.loadHistory(from: sessionsDirectory)
        XCTAssertTrue(result.isEmpty)
    }

    func testLoadHistoryLoadsMIDISessionDuration() throws {
        let sessionsDirectory = makeTempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        let date = makeDate("20260921-090000")
        let bundleURL = SessionLibrary.bundleURL(for: date, in: sessionsDirectory)
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 8, notes: [note])
        let track = Track(name: "Session", kind: .midi, regions: [region])
        let project = Project(tempo: 120, tracks: [track])
        try ProjectStore.save(project, to: bundleURL)

        let result = try SessionLibrary.loadHistory(from: sessionsDirectory)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].date, date)
        XCTAssertEqual(result[0].kind, .midi)
        XCTAssertEqual(result[0].durationSeconds, 4.0, accuracy: 0.001)
    }

    func testLoadHistoryLoadsAudioSessionDuration() throws {
        let sessionsDirectory = makeTempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        let date = makeDate("20260921-090000")
        let bundleURL = SessionLibrary.bundleURL(for: date, in: sessionsDirectory)
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take.wav")
        let track = Track(name: "Session", kind: .audio, audioRegions: [region])
        let project = Project(tempo: 120, tracks: [track])
        try ProjectStore.save(project, to: bundleURL)

        let result = try SessionLibrary.loadHistory(from: sessionsDirectory)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].kind, .audio)
        XCTAssertEqual(result[0].durationSeconds, 2.0, accuracy: 0.001)
    }

    func testLoadHistorySkipsMalformedFilenames() throws {
        let sessionsDirectory = makeTempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        try FileManager.default.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: sessionsDirectory.appendingPathComponent("NotASession.mstudio"),
            withIntermediateDirectories: true
        )

        let result = try SessionLibrary.loadHistory(from: sessionsDirectory)

        XCTAssertTrue(result.isEmpty)
    }

    func testLoadHistorySortsByDateAscending() throws {
        let sessionsDirectory = makeTempSessionsDirectory()
        defer { try? FileManager.default.removeItem(at: sessionsDirectory) }
        let laterDate = makeDate("20260922-090000")
        let earlierDate = makeDate("20260921-090000")
        let track = Track(name: "Session", kind: .midi, regions: [MIDIRegion(startBeat: 0, lengthBeats: 1)])
        let project = Project(tempo: 120, tracks: [track])
        try ProjectStore.save(project, to: SessionLibrary.bundleURL(for: laterDate, in: sessionsDirectory))
        try ProjectStore.save(project, to: SessionLibrary.bundleURL(for: earlierDate, in: sessionsDirectory))

        let result = try SessionLibrary.loadHistory(from: sessionsDirectory)

        XCTAssertEqual(result.map(\.date), [earlierDate, laterDate])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SessionLibraryTests`
Expected: FAIL — `SessionLibrary`/`SessionSummary` do not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/MeridianCompanionApp/SessionLibrary.swift
import Foundation
import ProjectModel

/// Where every session bundle lives and how its filename encodes when it
/// happened, per docs/superpowers/specs/2026-09-21-companion-record-play-trends-design.md
/// Section 2. Deliberately kept out of ProjectModel — see that spec's
/// Section 6.3 — so every function here is pure/deterministic given its
/// arguments (no hidden FileManager calls beyond what's explicitly asked
/// for), which is what makes it unit-testable without touching the real
/// Application Support directory.
enum SessionLibrary {
    private static let sessionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.timeZone = TimeZone.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// `baseDirectory` defaults to the real Application Support directory;
    /// tests pass a temp directory instead.
    static func sessionsDirectory(
        baseDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        baseDirectory
            .appendingPathComponent("Meridian Companion", isDirectory: true)
            .appendingPathComponent("Sessions", isDirectory: true)
    }

    static func bundleURL(for date: Date, in sessionsDirectory: URL) -> URL {
        sessionsDirectory.appendingPathComponent(
            "Session-\(sessionDateFormatter.string(from: date)).mstudio",
            isDirectory: true
        )
    }

    /// Returns nil for any filename that doesn't match the
    /// `Session-<yyyyMMdd-HHmmss>.mstudio` convention — callers skip those
    /// rather than failing the whole scan.
    static func parseSessionDate(from filename: String) -> Date? {
        guard filename.hasPrefix("Session-"), filename.hasSuffix(".mstudio") else { return nil }
        let start = filename.index(filename.startIndex, offsetBy: "Session-".count)
        let end = filename.index(filename.endIndex, offsetBy: -".mstudio".count)
        guard start < end else { return nil }
        return sessionDateFormatter.date(from: String(filename[start..<end]))
    }

    /// Scans `sessionsDirectory` for every session bundle, loads each via
    /// unmodified `ProjectStore.load`, and computes its duration in real
    /// seconds via unmodified `Tempo.seconds(forBeats:tempo:)` — no
    /// ProjectModel change needed. A bundle whose filename doesn't match the
    /// naming convention, or that fails to load, is silently skipped rather
    /// than failing the whole scan: a single corrupt session shouldn't break
    /// the trend view for every other one. Returns `[]`, not an error, when
    /// the directory doesn't exist yet (the common case before a patient's
    /// first-ever session).
    static func loadHistory(from sessionsDirectory: URL) throws -> [SessionSummary] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsDirectory.path) else { return [] }
        let bundleURLs = try fileManager.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)
        let summaries = bundleURLs.compactMap { url -> SessionSummary? in
            guard let date = parseSessionDate(from: url.lastPathComponent) else { return nil }
            guard let project = try? ProjectStore.load(from: url) else { return nil }
            guard let track = project.tracks.first else { return nil }
            let lengthBeats: Double
            switch track.kind {
            case .audio:
                lengthBeats = track.audioRegions.first?.lengthBeats ?? 0
            case .midi:
                lengthBeats = track.regions.first?.lengthBeats ?? 0
            }
            let durationSeconds = Tempo.seconds(forBeats: lengthBeats, tempo: project.tempo)
            return SessionSummary(id: url, date: date, kind: track.kind, durationSeconds: durationSeconds)
        }
        return summaries.sorted { $0.date < $1.date }
    }
}

struct SessionSummary: Identifiable, Equatable {
    var id: URL
    var date: Date
    var kind: TrackKind
    var durationSeconds: Double
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SessionLibraryTests`
Expected: PASS (9 tests).

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run: `swift test`
Expected: 97 pre-existing (77 ProjectModelTests + 19 AudioEngineTests + 1
MeridianCompanionAppShellTests, the existing shell placeholder) + 9 new =
106 passing.

- [ ] **Step 6: Commit**

```bash
git add Sources/MeridianCompanionApp/SessionLibrary.swift Tests/MeridianCompanionAppTests/SessionLibraryTests.swift
git commit -m "Add SessionLibrary: session bundle naming, scanning, history"
```

---

### Task 2: `CompanionState` — Recording, Playback, and Modality Detection

**Files:**
- Create: `Sources/MeridianCompanionApp/CompanionState.swift`

**Interfaces:**
- Consumes: `SessionLibrary.sessionsDirectory()`, `.bundleURL(for:in:)`,
  `.loadHistory(from:)`, `SessionSummary` (Task 1).
- Produces: `CompanionState` (`@MainActor final class CompanionState:
  ObservableObject`) with `@Published private(set) var isRecording: Bool`,
  `@Published private(set) var activeTrackKind: TrackKind?`,
  `@Published private(set) var level: Float`,
  `@Published private(set) var isNoteSounding: Bool`,
  `@Published private(set) var sessions: [SessionSummary]`,
  `@Published var lastError: String?`, `func startSession()`,
  `func stopSession()`, `func playLastSession()`,
  `func refreshSessionHistory()`. Used by the SwiftUI views (Task 3).

No automated tests for this task — matches this project's established
precedent for `AppState`/hardware-adjacent glue (`CoreMIDIInput`,
`PlaybackEngine`'s tap-installing code, `AudioRecorder`): verified by
build and the manual smoke test, not unit tests, since it drives real
CoreMIDI/AVAudioEngine state that has no meaningful behavior without
actual hardware.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/MeridianCompanionApp/CompanionState.swift
import AVFoundation
import Combine
import CoreMIDI
import Foundation
import ProjectModel
import AudioEngine

@MainActor
final class CompanionState: ObservableObject {
    @Published private(set) var isRecording = false
    /// nil while idle; set to the detected modality for the duration of a
    /// session. Drives which of `level`/`isNoteSounding` the UI should show
    /// (Task 3).
    @Published private(set) var activeTrackKind: TrackKind?
    /// Meaningful only while `activeTrackKind == .audio`; 0 otherwise.
    @Published private(set) var level: Float = 0
    /// A live visual cue maintained continuously, recording or not — same
    /// role `MeridianStudioApp.AppState.liveNotes` plays, simplified here to
    /// "is anything currently held" since this app has no piano roll to show
    /// individual pitches in.
    @Published private(set) var isNoteSounding = false
    @Published private(set) var sessions: [SessionSummary] = []
    @Published var lastError: String?

    private let midiInput = CoreMIDIInput()
    private let playbackEngine = PlaybackEngine()
    private let audioRecorder: AudioRecorder
    private let midiRecorder: MIDIRecorder
    private let recordingClock = RecordingClock()
    /// The modality actually in use for the in-progress session — set
    /// alongside `activeTrackKind` at Start, read internally at Stop.
    /// `activeTrackKind` is nil-when-idle for the UI; this is always a
    /// concrete `TrackKind` so `stopSession()`'s switch doesn't need to
    /// unwrap an optional it knows is never nil while `isRecording` is true.
    private var currentTrackKind: TrackKind = .midi
    private var currentProject: Project?
    private var currentBundleURL: URL?
    private var heldPitches: Set<UInt8> = []
    private var pollTimer: Timer?

    private static let queuePollInterval: TimeInterval = 0.01
    private static let audioFileName = "take.wav"

    init() {
        audioRecorder = AudioRecorder(engine: playbackEngine.engine)
        midiRecorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { [recordingClock] in
            recordingClock.beatsElapsed()
        }))
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
        refreshSessionHistory()
    }

    // A `@MainActor` class cannot touch isolated stored properties from its
    // nonisolated `deinit`, so the timer tears itself down instead — same
    // pattern `MeridianStudioApp.AppState.startQueuePolling()` uses.
    private func startQueuePolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.queuePollInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            Task { @MainActor in self.tick() }
        }
    }

    private func tick() {
        drainMIDIQueue()
        if isRecording, activeTrackKind == .audio {
            level = audioRecorder.level
        }
    }

    private func drainMIDIQueue() {
        for message in midiInput.queue.drain() {
            let event = MIDIMessageParser.parse(message)
            updateHeldPitches(with: event)
            if isRecording, activeTrackKind == .midi {
                midiRecorder.handle(event)
            }
        }
        isNoteSounding = !heldPitches.isEmpty
    }

    private func updateHeldPitches(with event: ParsedMIDIEvent) {
        switch event {
        case .noteOn(let pitch, _, _):
            heldPitches.insert(pitch)
        case .noteOff(let pitch, _):
            heldPitches.remove(pitch)
        case .other:
            break
        }
    }

    var hasMIDIDevice: Bool {
        MIDIGetNumberOfSources() > 0
    }

    func startSession() {
        guard !isRecording else { return }
        let kind: TrackKind = hasMIDIDevice ? .midi : .audio
        let sessionsDirectory = SessionLibrary.sessionsDirectory()
        let bundleURL = SessionLibrary.bundleURL(for: Date(), in: sessionsDirectory)
        let project = Project(tracks: [Track(name: "Session", kind: kind)])
        do {
            try ProjectStore.save(project, to: bundleURL)
        } catch {
            lastError = error.localizedDescription
            return
        }
        currentProject = project
        currentBundleURL = bundleURL
        currentTrackKind = kind

        switch kind {
        case .midi:
            midiRecorder.reset()
            recordingClock.tempo = project.tempo
            recordingClock.startDate = Date()
        case .audio:
            let workingURL = bundleURL.appendingPathComponent("audio").appendingPathComponent(Self.audioFileName)
            do {
                try audioRecorder.start(to: workingURL)
            } catch {
                lastError = error.localizedDescription
                try? FileManager.default.removeItem(at: bundleURL)
                currentProject = nil
                currentBundleURL = nil
                return
            }
        }
        activeTrackKind = kind
        isRecording = true
    }

    func stopSession() {
        guard isRecording, var project = currentProject, let bundleURL = currentBundleURL else { return }

        switch currentTrackKind {
        case .midi:
            // Drain first, while `isRecording` is still true and `startDate`
            // is still set — mirrors `MeridianStudioApp.AppState.stopRecording()`'s
            // exact ordering: draining after flipping `isRecording` would
            // route the take's tail to `isNoteSounding` only, never the
            // recorder, and `RecordingClock.beatsElapsed()` returns 0 once
            // `startDate` is nil.
            drainMIDIQueue()
            let finalBeat = recordingClock.beatsElapsed()
            isRecording = false
            midiRecorder.finalize(atBeat: finalBeat)
            recordingClock.startDate = nil
            let notes = midiRecorder.recordedNotes
            guard !notes.isEmpty else {
                try? FileManager.default.removeItem(at: bundleURL)
                resetSessionState()
                refreshSessionHistory()
                return
            }
            let lengthBeats = ceil(notes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0)
            project.tracks[0].regions = [MIDIRegion(startBeat: 0, lengthBeats: max(lengthBeats, 1), notes: notes)]
        case .audio:
            isRecording = false
            guard let workingURL = audioRecorder.stop(),
                  let file = try? AVAudioFile(forReading: workingURL) else {
                try? FileManager.default.removeItem(at: bundleURL)
                resetSessionState()
                refreshSessionHistory()
                return
            }
            let durationSeconds = Double(file.length) / file.processingFormat.sampleRate
            guard durationSeconds > 0 else {
                try? FileManager.default.removeItem(at: bundleURL)
                resetSessionState()
                refreshSessionHistory()
                return
            }
            let lengthBeats = Tempo.beats(forSeconds: durationSeconds, tempo: project.tempo)
            project.tracks[0].audioRegions = [
                AudioRegion(startBeat: 0, lengthBeats: max(lengthBeats, 0.1), fileName: Self.audioFileName)
            ]
        }

        do {
            try ProjectStore.save(project, to: bundleURL)
        } catch {
            lastError = error.localizedDescription
        }
        resetSessionState()
        refreshSessionHistory()
    }

    private func resetSessionState() {
        currentProject = nil
        currentBundleURL = nil
        activeTrackKind = nil
        level = 0
    }

    func playLastSession() {
        guard let last = sessions.last else { return }
        do {
            let project = try ProjectStore.load(from: last.id)
            guard let track = project.tracks.first else { return }
            switch track.kind {
            case .midi:
                playbackEngine.play(regions: track.regions, audioRegions: [], tempo: project.tempo)
            case .audio:
                guard let region = track.audioRegions.first else { return }
                let url = last.id.appendingPathComponent("audio").appendingPathComponent(region.fileName)
                playbackEngine.play(regions: [], audioRegions: [(url: url, startBeat: region.startBeat)], tempo: project.tempo)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refreshSessionHistory() {
        do {
            sessions = try SessionLibrary.loadHistory(from: SessionLibrary.sessionsDirectory())
        } catch {
            lastError = error.localizedDescription
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds with no new errors. (`swift build` also compiles
`MeridianStudioApp`/`AudioEngine`, which already build clean — if you
see errors outside `CompanionState.swift`, they're not from this task;
stop and report rather than editing unrelated files.)

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: still 106 passing (no new tests this task, no regressions).

- [ ] **Step 4: Commit**

```bash
git add Sources/MeridianCompanionApp/CompanionState.swift
git commit -m "Add CompanionState: session recording, playback, modality detection"
```

---

### Task 3: SwiftUI Views — Recording Screen and Trend View

**Files:**
- Create: `Sources/MeridianCompanionApp/LevelMeterView.swift`
- Modify: `Sources/MeridianCompanionApp/ContentView.swift`
- Modify: `Sources/MeridianCompanionApp/MeridianCompanionApp.swift`

**Interfaces:**
- Consumes: `CompanionState` (Task 2) — every `@Published` property and
  method listed in Task 2's Interfaces block.

No automated tests for this task — matches this project's established
precedent for SwiftUI view code (`MeridianStudioApp`'s views have none
either). Verified by build and the manual smoke test (Section 8 of the
design spec — includes a real macOS Switch Control pass, not just
VoiceOver).

- [ ] **Step 1: Create `LevelMeterView.swift`**

```swift
// Sources/MeridianCompanionApp/LevelMeterView.swift
import SwiftUI

/// A minimal horizontal bar meter — a deliberate duplicate of
/// MeridianStudioApp's LevelMeterView, not an import: MeridianCompanionApp
/// cannot depend on MeridianStudioApp (see
/// docs/superpowers/specs/2026-09-20-two-app-architecture-design.md,
/// Section 2 — this handful of duplicated lines is the accepted cost).
struct LevelMeterView: View {
    let level: Float

    private let width: CGFloat = 160
    private let height: CGFloat = 20

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.secondary.opacity(0.2))
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: width * CGFloat(min(max(level, 0), 1)))
        }
        .frame(width: width, height: height)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue(level > 0.05 ? "Sound detected" : "Silent")
    }
}
```

- [ ] **Step 2: Replace `ContentView.swift`**

```swift
// Sources/MeridianCompanionApp/ContentView.swift
import SwiftUI
import Charts
import ProjectModel

struct ContentView: View {
    var body: some View {
        TabView {
            SessionView()
                .tabItem { Label("Session", systemImage: "waveform") }
            TrendView()
                .tabItem { Label("Progress", systemImage: "chart.bar") }
        }
    }
}

private struct SessionView: View {
    @EnvironmentObject private var state: CompanionState

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Button(action: toggleSession) {
                Text(state.isRecording ? "Stop" : "Start Session")
                    .font(.largeTitle)
                    .frame(minWidth: 240, minHeight: 100)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel(state.isRecording ? "Stop session" : "Start session")

            if state.activeTrackKind == .audio {
                LevelMeterView(level: state.level)
            } else {
                Text(state.isNoteSounding ? "Note sounding" : "Ready")
                    .font(.title3)
                    .foregroundColor(state.isNoteSounding ? .accentColor : .secondary)
                    .accessibilityLabel(state.isNoteSounding ? "Note sounding" : "No note sounding")
            }

            Button("Play Last Session", action: state.playLastSession)
                .disabled(state.sessions.isEmpty || state.isRecording)
                .accessibilityLabel("Play last session")

            if let lastError = state.lastError {
                Text(lastError)
                    .foregroundColor(.red)
                    .font(.caption)
                    .accessibilityLabel("Error: \(lastError)")
            }

            Spacer()
        }
        .padding()
    }

    private func toggleSession() {
        state.isRecording ? state.stopSession() : state.startSession()
    }
}

private struct TrendView: View {
    @EnvironmentObject private var state: CompanionState

    var body: some View {
        VStack(alignment: .leading) {
            Text("Session History")
                .font(.headline)
                .padding(.bottom, 4)
            if state.sessions.isEmpty {
                Text("No sessions recorded yet.")
                    .foregroundColor(.secondary)
            } else {
                Chart(state.sessions) { session in
                    BarMark(
                        x: .value("Date", session.date, unit: .day),
                        y: .value("Duration (s)", session.durationSeconds)
                    )
                }
                .accessibilityLabel("Session duration over time")
                .frame(minHeight: 200)
            }
        }
        .padding()
    }
}
```

- [ ] **Step 3: Wire `CompanionState` into the app entry point**

Replace the full contents of `Sources/MeridianCompanionApp/MeridianCompanionApp.swift`:

```swift
// Sources/MeridianCompanionApp/MeridianCompanionApp.swift
import AppKit
import SwiftUI

@main
struct MeridianCompanionApp: App {
    @StateObject private var state = CompanionState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 480, minHeight: 360)
        }
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: builds with no errors. (`Charts` is a system framework — no
`Package.swift` change is needed to use it, the same way `AVFoundation`/
`CoreMIDI` need none.)

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: still 106 passing (the existing shell test,
`testContentViewBuilds`, still constructs `ContentView()` and must still
compile against the new `ContentView` body — if it doesn't, the
shell test needs no code change, since `ContentView()`'s initializer
signature hasn't changed, only its body).

- [ ] **Step 6: Manual smoke test**

Run: `swift run MeridianCompanionApp`

Check:
- The window opens showing the "Session" tab with a large Start Session
  button.
- Press Start Session; if a MIDI keyboard is connected, playing notes
  shows "Note sounding" while held; if not, a level meter appears and
  moves while speaking/making noise into the microphone.
- Press Stop; switch to the "Progress" tab and confirm one bar appears
  in the chart.
- Press "Play Last Session" from the Session tab; confirm audible
  playback (MIDI note or recorded audio, matching whichever modality was
  used).
- Record a second session on a different day (or manually adjust the
  system clock, or just confirm the chart can show two bars using two
  manually-placed fixture bundles) to confirm the trend chart shows
  multiple sessions correctly ordered by date.
- Enable macOS Switch Control (System Settings > Accessibility > Switch
  Control) and confirm the Start Session button, Play Last Session
  button, and tab switcher are all reachable via scanning.

- [ ] **Step 7: Commit**

```bash
git add Sources/MeridianCompanionApp/LevelMeterView.swift Sources/MeridianCompanionApp/ContentView.swift Sources/MeridianCompanionApp/MeridianCompanionApp.swift
git commit -m "Add recording screen and trend view to MeridianCompanionApp"
```

---

### Task 4: Documentation

**Files:**
- Create: `docs/companion.md`
- Modify: `docs/architecture.md`
- Modify: `README.md`

**Interfaces:** None — documentation only, reflecting what Tasks 1-3 built.

- [ ] **Step 1: Create `docs/companion.md`**

```markdown
# Meridian Companion

Meridian Companion is the accessibility-first, rehab/therapy-facing
sibling to Meridian Studio, sharing only `ProjectModel`/`AudioEngine`
with it — see
`docs/superpowers/specs/2026-09-20-two-app-architecture-design.md` for
the architectural split and
`docs/superpowers/specs/2026-09-21-companion-record-play-trends-design.md`
for this app's first milestone.

## Session model

Unlike Meridian Studio, there is no manual Save As: the app auto-manages
its own session library under
`~/Library/Application Support/Meridian Companion/Sessions/`, one
`.mstudio` bundle per session, named `Session-<yyyyMMdd-HHmmss>.mstudio`.
Every bundle is written through unmodified `ProjectStore.save`/`.load` —
`SessionLibrary` (`Sources/MeridianCompanionApp/SessionLibrary.swift`)
owns the naming/scanning convention entirely within this app's own
target, not in `ProjectModel`, per the architecture spec's standing rule
that neither shared package grows an audience-specific concept.

## Modality auto-detection

At the start of each session, `CompanionState.hasMIDIDevice` checks
`MIDIGetNumberOfSources() > 0`. A MIDI device present records a
`.midi`-kind track via `CoreMIDIInput`/`MIDIRecorder`; otherwise a
`.audio`-kind track records via `AudioRecorder` — both exactly as
Meridian Studio's own `AppState` uses them. Detection is fresh at every
Start, not cached at launch, since a keyboard could be plugged in or
unplugged between sessions.

## Trends

`SessionLibrary.loadHistory(from:)` scans the session library and
computes two metrics only — session frequency and duration — chosen
specifically because they're computable identically for MIDI and audio
sessions. Note-level/timing-consistency metrics are deferred to a later
milestone; the underlying `NoteEvent.startBeat` data is already being
recorded and saved, so nothing here blocks adding that metric later.

## Known limitations

If no MIDI device is present and microphone access is denied, an audio
session still "succeeds" while capturing only silence — no error is
surfaced anywhere. Same class of gap as Meridian Studio's own recording
path (see `docs/audio.md`); not solved by this milestone.
```

- [ ] **Step 2: Add a cross-reference paragraph to `docs/architecture.md`**

In `docs/architecture.md`, replace:

```markdown
Undo/redo is model-level scaffolding only: `ProjectDocument` owns an
`UndoManager` that `addRegion`/`removeRegion`/`addTrack`/`removeTrack`
register with, and unit tests exercise undo and redo directly — but it
is not wired into the app's Edit menu or responder chain, so Cmd-Z does
```

with:

```markdown
As of the two-app architecture
(`docs/superpowers/specs/2026-09-20-two-app-architecture-design.md`),
`ProjectModel` and `AudioEngine` are the entire foundation for a second
app, `MeridianCompanionApp` (see `docs/companion.md`) — not just
`MeridianStudioApp`. Neither app imports the other; this is enforced by
`Package.swift` simply never listing that dependency.

Undo/redo is model-level scaffolding only: `ProjectDocument` owns an
`UndoManager` that `addRegion`/`removeRegion`/`addTrack`/`removeTrack`
register with, and unit tests exercise undo and redo directly — but it
is not wired into the app's Edit menu or responder chain, so Cmd-Z does
```

(This inserts the new paragraph immediately before the existing
"Undo/redo is model-level scaffolding only" paragraph — the replace
block above includes that paragraph's first four lines unchanged only
so the insertion point is unambiguous; do not otherwise alter it.)

- [ ] **Step 3: Update `README.md`'s repository layout**

In `README.md`, replace:

```
Sources/
  MeridianStudioApp/   # SwiftUI app (UI layer)
  ProjectModel/        # Project/Track/Region/NoteEvent model, persistence
  AudioEngine/         # CoreMIDI input, recording, playback scheduling
```

with:

```
Sources/
  MeridianStudioApp/     # SwiftUI app (UI layer)
  MeridianCompanionApp/  # SwiftUI companion app (see docs/companion.md)
  ProjectModel/          # Project/Track/Region/NoteEvent model, persistence
  AudioEngine/           # CoreMIDI input, recording, playback scheduling
```

- [ ] **Step 4: Commit**

```bash
git add docs/companion.md docs/architecture.md README.md
git commit -m "Document Meridian Companion's session/trend architecture"
```

---

## Self-Review Notes (completed during plan authoring)

- **Spec coverage:** Section 2 (storage) → Task 1. Section 3 (session
  data shape) → Task 2. Section 4 (modality detection) → Task 2. Section
  5 (recording UI) → Task 3. Section 6 (playback) → Task 2. Section 7
  (trend view, both computation and chart) → Tasks 1 and 3. Section 8
  (accessibility) → Task 3 (labels) + Task 3's manual smoke test (Switch
  Control pass). Section 9 (`CompanionState` shape) → Task 2. Section 10
  (testing split) → Tasks 1 (tested) and 2/3 (not, matching precedent).
  Section 11 (non-goals) → reflected in this plan's Global Constraints
  and by simply not building any of them. No gaps found.
- **Placeholder scan:** no TBD/TODO; every step has real code or an
  executable command.
- **Type consistency:** `SessionSummary`'s fields (`id: URL`, `date:
  Date`, `kind: TrackKind`, `durationSeconds: Double`) are identical
  across Task 1's implementation, Task 1's tests, Task 2's
  `playLastSession()`/`refreshSessionHistory()`, and Task 3's
  `TrendView`. `SessionLibrary.sessionsDirectory()`/`.bundleURL(for:in:)`/
  `.loadHistory(from:)` signatures match between Task 1's implementation
  and Task 2's call sites. `CompanionState`'s published property names
  (`isRecording`, `activeTrackKind`, `level`, `isNoteSounding`,
  `sessions`, `lastError`) and method names (`startSession`,
  `stopSession`, `playLastSession`, `refreshSessionHistory`) match
  between Task 2's implementation and Task 3's view code.
