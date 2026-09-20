# Audio Recording & Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record real microphone audio onto a track, play it back, and show live input/output level meters — the foundation of Phase 3, before waveform rendering, editing, or importing existing files.

**Architecture:** Rename the `MIDIEngine` target to `AudioEngine` (it now houses the project's first non-MIDI real-time I/O), add `TrackKind.audio`/`AudioRegion`/`Track.audioRegions` to the data model with backward-compatible decoding, add a pure `AudioLevelMeter` + an `AudioRecorder` (mic capture) + extend `PlaybackEngine` (audio file playback) to the renamed target, then wire `AppState` and a new `LevelMeterView` on top.

**Tech Stack:** Swift 6, SwiftUI, AVFoundation, XCTest (runs for real — Xcode is installed).

**Spec:** `docs/superpowers/specs/2026-09-20-audio-recording-design.md`

## Global Constraints

- Deployment target: macOS 14.0+, zero third-party dependencies (unchanged).
- `swift test` runs for real on this machine — every task with tests must show real RED/GREEN evidence.
- Recording onto an audio track requires the project to already be saved (`AppState.fileURL != nil`) — surfaced as an alert, never a silent failure or a crash.
- `AudioRegion.fileName` is a filename only, never an absolute path — `ProjectModel` stays free of filesystem-location knowledge; the app layer resolves filenames against the project bundle's `audio/` directory.
- `addAudioRegion`/`removeAudioRegion` are undo-registered structural operations (mirroring `addRegion`/`removeRegion` exactly, including the `MainActor.assumeIsolated` bridge every undo closure in `ProjectDocument.swift` already uses — annotating the closure `@MainActor` directly does NOT work, CI's toolchain rejects it, discovered earlier this project).
- `AudioEngine`/`ProjectModel` stay UI-agnostic: `PlaybackEngine.play` takes resolved `(url: URL, startBeat: Double)` pairs, never `AudioRegion` or a project-bundle path.
- Historical spec/plan documents (anything under `docs/superpowers/specs/2026-09-16-*` or `docs/superpowers/plans/2026-09-16-*` and similar prior-milestone documents) are never edited to reflect the rename — they are records of what was decided at the time.

---

## Task 1: Rename `MIDIEngine` Target to `AudioEngine`

**Files:**
- Move: `Sources/MIDIEngine/` → `Sources/AudioEngine/`
- Move: `Tests/MIDIEngineTests/` → `Tests/AudioEngineTests/`
- Modify: `Package.swift`
- Modify: `Sources/AudioEngine/CoreMIDIInput.swift`, `Sources/AudioEngine/PlaybackScheduler.swift`, `Sources/AudioEngine/PlaybackEngine.swift`, `Sources/AudioEngine/MIDIMessageParser.swift` (path-comment headers only)
- Modify: `Sources/MeridianStudioApp/AppState.swift` (one import line)
- Modify: `Tests/AudioEngineTests/MIDIMessageParserTests.swift`, `Tests/AudioEngineTests/MIDIRecorderTests.swift`, `Tests/AudioEngineTests/MIDIEventQueueTests.swift`, `Tests/AudioEngineTests/RecordAndPersistIntegrationTests.swift`, `Tests/AudioEngineTests/PlaybackSchedulerTests.swift` (imports, path-comment headers where present)
- Modify: `docs/architecture.md`, `docs/evals.md`, `docs/testing.md`

**Interfaces:** None — pure rename, zero functional change. Every test that passes before this task must pass identically after it.

- [ ] **Step 1: Move the directories**

```bash
git mv Sources/MIDIEngine Sources/AudioEngine
git mv Tests/MIDIEngineTests Tests/AudioEngineTests
```

- [ ] **Step 2: Update `Package.swift`**

Replace:

```swift
    products: [
        .library(name: "ProjectModel", targets: ["ProjectModel"]),
        .library(name: "MIDIEngine", targets: ["MIDIEngine"]),
        .executable(name: "MeridianStudioApp", targets: ["MeridianStudioApp"])
    ],
    targets: [
        .target(name: "ProjectModel"),
        .target(name: "MIDIEngine", dependencies: ["ProjectModel"]),
        .executableTarget(name: "MeridianStudioApp", dependencies: ["ProjectModel", "MIDIEngine"]),
        .testTarget(name: "ProjectModelTests", dependencies: ["ProjectModel"]),
        .testTarget(name: "MIDIEngineTests", dependencies: ["MIDIEngine", "ProjectModel"])
    ]
```

with:

```swift
    products: [
        .library(name: "ProjectModel", targets: ["ProjectModel"]),
        .library(name: "AudioEngine", targets: ["AudioEngine"]),
        .executable(name: "MeridianStudioApp", targets: ["MeridianStudioApp"])
    ],
    targets: [
        .target(name: "ProjectModel"),
        .target(name: "AudioEngine", dependencies: ["ProjectModel"]),
        .executableTarget(name: "MeridianStudioApp", dependencies: ["ProjectModel", "AudioEngine"]),
        .testTarget(name: "ProjectModelTests", dependencies: ["ProjectModel"]),
        .testTarget(name: "AudioEngineTests", dependencies: ["AudioEngine", "ProjectModel"])
    ]
```

- [ ] **Step 3: Update path-comment headers**

In each of `Sources/AudioEngine/CoreMIDIInput.swift`, `Sources/AudioEngine/PlaybackScheduler.swift`, `Sources/AudioEngine/PlaybackEngine.swift`, `Sources/AudioEngine/MIDIMessageParser.swift`, replace the first line (`// Sources/MIDIEngine/<filename>`) with `// Sources/AudioEngine/<filename>` (same filename, only the directory changes).

- [ ] **Step 4: Update the app's import**

In `Sources/MeridianStudioApp/AppState.swift`, replace:

```swift
import MIDIEngine
```

with:

```swift
import AudioEngine
```

- [ ] **Step 5: Update test file imports and headers**

In `Tests/AudioEngineTests/MIDIMessageParserTests.swift`, `Tests/AudioEngineTests/MIDIRecorderTests.swift`, `Tests/AudioEngineTests/RecordAndPersistIntegrationTests.swift`, `Tests/AudioEngineTests/PlaybackSchedulerTests.swift`, replace the first line (`// Tests/MIDIEngineTests/<filename>`) with `// Tests/AudioEngineTests/<filename>`, and replace `@testable import MIDIEngine` with `@testable import AudioEngine`.

In `Tests/AudioEngineTests/MIDIEventQueueTests.swift` (no path-comment header to change), replace `@testable import MIDIEngine` with `@testable import AudioEngine`.

- [ ] **Step 6: Update currently-descriptive docs**

In `docs/architecture.md`, replace:

```markdown
- **MIDI Engine** (`Sources/MIDIEngine`) — `CoreMIDIInput` (hardware
```

with:

```markdown
- **Audio Engine** (`Sources/AudioEngine`, renamed from `MIDIEngine`
  once it grew a non-MIDI real-time I/O path — see the audio recording
  section below) — `CoreMIDIInput` (hardware
```

In `docs/evals.md`, replace:

```markdown
(`RecordAndPersistIntegrationTests` for project I/O; the `MIDIEngine`
```

with:

```markdown
(`RecordAndPersistIntegrationTests` for project I/O; the `AudioEngine`
```

In `docs/testing.md`, replace:

```markdown
- `Tests/MIDIEngineTests` — `MIDIEventQueue` ordering/overflow,
```

with:

```markdown
- `Tests/AudioEngineTests` (renamed from `MIDIEngineTests`) —
  `MIDIEventQueue` ordering/overflow,
```

- [ ] **Step 7: Build and run the full test suite**

Run: `rm -rf .build && swift build`
Expected: builds with no errors, no warnings.

Run: `swift test`
Expected: all 79 pre-existing tests pass, identical count and names to before this task — this is a pure rename, so anything different (a new failure, a changed count) means something was missed, not a legitimate new outcome.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Rename MIDIEngine target to AudioEngine ahead of adding real audio I/O"
```

---

## Task 2: `ProjectModel` — `TrackKind.audio`, `AudioRegion`, `Track.audioRegions`

**Files:**
- Modify: `Sources/ProjectModel/Track.swift`
- Create: `Sources/ProjectModel/AudioRegion.swift`
- Create: `Tests/ProjectModelTests/AudioRegionTests.swift`
- Modify: `Tests/ProjectModelTests/ProjectDocumentTests.swift` (a Track-decoding test only — see Step 1)

**Interfaces:**
- Produces: `TrackKind.audio`, `AudioRegion` (Codable, Equatable, Identifiable, Sendable), `Track.audioRegions: [AudioRegion]`. Used by `ProjectDocument` (Task 3), `AppState` (Tasks 7-8).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/ProjectModelTests/AudioRegionTests.swift
import XCTest
@testable import ProjectModel

final class AudioRegionTests: XCTestCase {
    func testEncodeDecodeRoundTrips() throws {
        let original = AudioRegion(startBeat: 2, lengthBeats: 4, fileName: "abc.wav")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioRegion.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testTrackKindAudioRoundTrips() throws {
        let data = try JSONEncoder().encode(TrackKind.audio)
        let decoded = try JSONDecoder().decode(TrackKind.self, from: data)
        XCTAssertEqual(decoded, .audio)
    }

    func testTrackDefaultsAudioRegionsToEmpty() {
        let track = Track(name: "Piano")
        XCTAssertTrue(track.audioRegions.isEmpty)
    }

    func testTrackDecodesLegacyJSONMissingAudioRegionsAsEmpty() throws {
        let json = """
        {"id": "11111111-1111-1111-1111-111111111111", "name": "Piano", "kind": "midi", "muted": false, "solo": false, "regions": []}
        """
        let track = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        XCTAssertTrue(track.audioRegions.isEmpty)
        XCTAssertEqual(track.name, "Piano")
    }

    func testTrackEncodeDecodeRoundTripsAudioRegions() throws {
        let region = AudioRegion(startBeat: 0, lengthBeats: 2, fileName: "take1.wav")
        let original = Track(name: "Vocals", kind: .audio, audioRegions: [region])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Track.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AudioRegionTests`
Expected: FAIL — `AudioRegion` and `TrackKind.audio` do not exist yet, `Track` has no `audioRegions`.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/ProjectModel/AudioRegion.swift
import Foundation

public struct AudioRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startBeat: Double
    public var lengthBeats: Double
    /// Filename only, never an absolute path — resolved against the project
    /// bundle's `audio/` directory by the app layer, so a bundle can be
    /// moved/renamed on disk without invalidating it.
    public var fileName: String

    public init(id: UUID = UUID(), startBeat: Double, lengthBeats: Double, fileName: String) {
        self.id = id
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.fileName = fileName
    }
}
```

Replace the full contents of `Sources/ProjectModel/Track.swift`:

```swift
import Foundation

public enum TrackKind: String, Codable, Sendable {
    case midi
    case audio
}

public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TrackKind
    public var muted: Bool
    public var solo: Bool
    public var regions: [MIDIRegion]
    public var audioRegions: [AudioRegion]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: TrackKind = .midi,
        muted: Bool = false,
        solo: Bool = false,
        regions: [MIDIRegion] = [],
        audioRegions: [AudioRegion] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.muted = muted
        self.solo = solo
        self.regions = regions
        self.audioRegions = audioRegions
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, muted, solo, regions, audioRegions
    }

    // Custom decode so a project file saved before `audioRegions` existed still
    // opens: it defaults to `[]` when absent, the same pattern already used for
    // `NoteEvent.id`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(TrackKind.self, forKey: .kind)
        muted = try container.decode(Bool.self, forKey: .muted)
        solo = try container.decode(Bool.self, forKey: .solo)
        regions = try container.decode([MIDIRegion].self, forKey: .regions)
        audioRegions = try container.decodeIfPresent([AudioRegion].self, forKey: .audioRegions) ?? []
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AudioRegionTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Run the full test suite to confirm no regressions**

Run: `swift test`
Expected: all pre-existing tests still pass (79 pre-existing + 5 new = 84). `Track`'s custom `init(from:)` must decode every existing test fixture and every previously-saved project exactly as the old synthesized init did — if any pre-existing test touching `Track` decoding fails, STOP and report BLOCKED rather than editing those tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectModel/Track.swift Sources/ProjectModel/AudioRegion.swift Tests/ProjectModelTests/AudioRegionTests.swift
git commit -m "Add TrackKind.audio, AudioRegion, and Track.audioRegions"
```

---

## Task 3: `ProjectDocument` Audio Region Operations + `ProjectStore` `audio/` Directory

**Files:**
- Modify: `Sources/ProjectModel/ProjectDocument.swift`
- Modify: `Sources/ProjectModel/ProjectStore.swift`
- Modify: `Tests/ProjectModelTests/ProjectDocumentTests.swift`
- Modify: `Tests/ProjectModelTests/ProjectStoreTests.swift`

**Interfaces:**
- Consumes: `AudioRegion` (Task 2).
- Produces: `ProjectDocument.addAudioRegion(_:toTrackAt:)`, `ProjectDocument.removeAudioRegion(id:fromTrackAt:)`. `ProjectStore.save` now also creates an `audio/` directory. Used by `AppState` (Tasks 7-8).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ProjectModelTests/ProjectDocumentTests.swift` (inside the existing `@MainActor final class ProjectDocumentTests: XCTestCase { ... }`, alongside the existing tests):

```swift
    func testAddAudioRegionAppendsRegion() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Vocals", kind: .audio)]))
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        doc.addAudioRegion(region, toTrackAt: 0)
        XCTAssertEqual(doc.project.tracks[0].audioRegions.count, 1)
        XCTAssertEqual(doc.project.tracks[0].audioRegions[0].fileName, "take1.wav")
    }

    func testUndoRemovesAddedAudioRegion() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Vocals", kind: .audio)]))
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        doc.addAudioRegion(region, toTrackAt: 0)
        doc.undoManager.undo()
        XCTAssertTrue(doc.project.tracks[0].audioRegions.isEmpty)
    }

    func testRedoReAddsAudioRegion() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Vocals", kind: .audio)]))
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        doc.addAudioRegion(region, toTrackAt: 0)
        doc.undoManager.undo()
        doc.undoManager.redo()
        XCTAssertEqual(doc.project.tracks[0].audioRegions.count, 1)
    }

    func testRemoveAudioRegionRemovesByID() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Vocals", kind: .audio, audioRegions: [region])]))
        doc.removeAudioRegion(id: region.id, fromTrackAt: 0)
        XCTAssertTrue(doc.project.tracks[0].audioRegions.isEmpty)
    }

    func testUndoReInsertsRemovedAudioRegion() {
        let region = AudioRegion(startBeat: 0, lengthBeats: 4, fileName: "take1.wav")
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Vocals", kind: .audio, audioRegions: [region])]))
        doc.removeAudioRegion(id: region.id, fromTrackAt: 0)
        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks[0].audioRegions.count, 1)
        XCTAssertEqual(doc.project.tracks[0].audioRegions[0].fileName, "take1.wav")
    }
```

Add to `Tests/ProjectModelTests/ProjectStoreTests.swift`:

```swift
    func testSaveCreatesAudioDirectory() throws {
        let project = Project(tracks: [Track(name: "Piano")])
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try ProjectStore.save(project, to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("audio").path))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ProjectDocumentTests` and `swift test --filter ProjectStoreTests`
Expected: FAIL — `addAudioRegion`/`removeAudioRegion` do not exist yet; `save` does not create `audio/` yet.

- [ ] **Step 3: Write the implementation**

In `Sources/ProjectModel/ProjectDocument.swift`, insert the following immediately after `removeRegion(id:fromTrackAt:)` and before `addTrack(_:)`:

```swift
    public func addAudioRegion(_ region: AudioRegion, toTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        project.tracks[trackIndex].audioRegions.append(region)
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.removeAudioRegion(id: region.id, fromTrackAt: trackIndex)
            }
        }
    }

    public func removeAudioRegion(id: UUID, fromTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == id }) else { return }
        let removed = project.tracks[trackIndex].audioRegions.remove(at: index)
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.addAudioRegion(removed, toTrackAt: trackIndex)
            }
        }
    }
```

In `Sources/ProjectModel/ProjectStore.swift`, replace:

```swift
    private static let projectFileName = "project.json"
    private static let midiDirectoryName = "midi"

    public static func save(_ project: Project, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: url.appendingPathComponent(midiDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
```

with:

```swift
    private static let projectFileName = "project.json"
    private static let midiDirectoryName = "midi"
    private static let audioDirectoryName = "audio"

    public static func save(_ project: Project, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: url.appendingPathComponent(midiDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: url.appendingPathComponent(audioDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter ProjectDocumentTests` and `swift test --filter ProjectStoreTests`
Expected: PASS (26 ProjectDocumentTests, 7 ProjectStoreTests).

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all tests pass (84 pre-existing + 6 new = 90), no regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectModel/ProjectDocument.swift Sources/ProjectModel/ProjectStore.swift Tests/ProjectModelTests/ProjectDocumentTests.swift Tests/ProjectModelTests/ProjectStoreTests.swift
git commit -m "Add audio region operations to ProjectDocument and audio/ to ProjectStore"
```

---

## Task 4: `AudioLevelMeter` Pure Logic

**Files:**
- Create: `Sources/AudioEngine/AudioLevelMeter.swift`
- Create: `Tests/AudioEngineTests/AudioLevelMeterTests.swift`

**Interfaces:**
- Produces: `AudioLevelMeter.peak(of: AVAudioPCMBuffer) -> Float`. Used by `AudioRecorder` (Task 5) and `PlaybackEngine` (Task 6).

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AudioEngineTests/AudioLevelMeterTests.swift
import XCTest
import AVFoundation
@testable import AudioEngine

final class AudioLevelMeterTests: XCTestCase {
    private func makeBuffer(channels samples: [[Float]]) -> AVAudioPCMBuffer {
        let channelCount = UInt32(samples.count)
        let frameCount = samples.first?.count ?? 0
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: channelCount)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<samples.count {
            for frame in 0..<samples[channel].count {
                buffer.floatChannelData![channel][frame] = samples[channel][frame]
            }
        }
        return buffer
    }

    func testSilenceHasZeroPeak() {
        let buffer = makeBuffer(channels: [[0, 0, 0, 0]])
        XCTAssertEqual(AudioLevelMeter.peak(of: buffer), 0, accuracy: 0.0001)
    }

    func testPeakIsTheLargestAbsoluteSampleValue() {
        let buffer = makeBuffer(channels: [[0.1, -0.5, 0.3, -0.2]])
        XCTAssertEqual(AudioLevelMeter.peak(of: buffer), 0.5, accuracy: 0.0001)
    }

    func testPeakIsTheMaximumAcrossChannels() {
        let buffer = makeBuffer(channels: [[0.1, 0.2], [0.6, 0.05]])
        XCTAssertEqual(AudioLevelMeter.peak(of: buffer), 0.6, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter AudioLevelMeterTests`
Expected: FAIL — `AudioLevelMeter` does not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AudioEngine/AudioLevelMeter.swift
import AVFoundation

/// A simple peak meter (largest absolute sample value across every channel and
/// frame), not RMS/dB. Pure and hardware-free, so it's the one piece of audio
/// level metering testable without a real input/output device — matches this
/// project's existing split between pure logic (`MIDIMessageParser`,
/// `PlaybackScheduler`) and their hardware-adjacent, untested siblings
/// (`CoreMIDIInput`, `PlaybackEngine`).
public enum AudioLevelMeter {
    public static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let frameCount = Int(buffer.frameLength)
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channelData[channel]
            for frame in 0..<frameCount {
                peak = max(peak, abs(samples[frame]))
            }
        }
        return peak
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AudioLevelMeterTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full test suite**

Run: `swift test`
Expected: all tests pass (90 pre-existing + 3 new = 93), no regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/AudioEngine/AudioLevelMeter.swift Tests/AudioEngineTests/AudioLevelMeterTests.swift
git commit -m "Add AudioLevelMeter pure peak-level logic"
```

---

## Task 5: `AudioRecorder` — Microphone Capture

**Files:**
- Create: `Sources/AudioEngine/AudioRecorder.swift`

**Interfaces:**
- Consumes: `AudioLevelMeter.peak(of:)` (Task 4).
- Produces: `AudioRecorder.init(engine: AVAudioEngine)`, `.start(to: URL) throws`, `.stop() -> URL?`, `.level: Float`. Used by `AppState` (Task 7).

No automated tests for this task — matches the project's established precedent for hardware-touching adapters (`CoreMIDIInput`, `PlaybackEngine`): no real audio device in CI or this environment, verified by build and the manual smoke test.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/AudioEngine/AudioRecorder.swift
import AVFoundation
import os

/// Captures the shared `AVAudioEngine`'s microphone input to a file. Writing to
/// disk and computing a peak level directly inside the tap callback is the
/// simplest professional implementation — not the glitch-proof
/// ring-buffer-plus-writer-thread design a professional multitrack DAW
/// eventually needs under heavy system load, but the standard, widely-used
/// pattern for straightforward single-track recording (see docs/audio.md).
public final class AudioRecorder {
    private let engine: AVAudioEngine
    private var audioFile: AVAudioFile?
    private let currentLevel = OSAllocatedUnfairLock<Float>(initialState: 0)

    public init(engine: AVAudioEngine) {
        self.engine = engine
    }

    public func start(to url: URL) throws {
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: inputFormat.settings)
        audioFile = file
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            try? file.write(from: buffer)
            self.currentLevel.withLock { $0 = AudioLevelMeter.peak(of: buffer) }
        }
    }

    /// Returns the URL just recorded to, or `nil` if nothing was in progress.
    /// Safe to call even if `start` was never called.
    public func stop() -> URL? {
        engine.inputNode.removeTap(onBus: 0)
        let url = audioFile?.url
        audioFile = nil
        currentLevel.withLock { $0 = 0 }
        return url
    }

    public var level: Float {
        currentLevel.withLock { $0 }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build --target AudioEngine`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/AudioEngine/AudioRecorder.swift
git commit -m "Add AudioRecorder for microphone capture"
```

---

## Task 6: `PlaybackEngine` Plays Audio Regions

**Files:**
- Modify: `Sources/AudioEngine/PlaybackEngine.swift`

**Interfaces:**
- Consumes: `AudioLevelMeter.peak(of:)` (Task 4).
- Produces: `PlaybackEngine.engine: AVAudioEngine` (now exposed, was `private`), `PlaybackEngine.play(regions:audioRegions:tempo:)` (signature grows), `PlaybackEngine.level: Float`. `stopAllNotes()` also silences audio playback. Used by `AppState` (Tasks 7-8).

No automated tests for this task — matches the project's established precedent for `PlaybackEngine` (an AVFoundation hardware adapter).

- [ ] **Step 1: Replace the whole file**

Replace the full contents of `Sources/AudioEngine/PlaybackEngine.swift`:

```swift
// Sources/AudioEngine/PlaybackEngine.swift
import AVFoundation
import ProjectModel
import os

@MainActor
public final class PlaybackEngine {
    /// Shared with `AudioRecorder`, which needs the same running engine's
    /// `inputNode` for simultaneous record + play back. `AppState` constructs
    /// `AudioRecorder(engine: playbackEngine.engine)`, which is why this can't
    /// stay `private`.
    public let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()
    private let audioPlayerNode = AVAudioPlayerNode()
    /// Every in-flight `Task` spawned by `play(regions:audioRegions:tempo:)`.
    /// Without this, Stop could not reach the sleeping tasks and they kept
    /// firing note-on/note-off after the transport had supposedly stopped.
    private var scheduledTasks: [Task<Void, Never>] = []
    private let currentOutputLevel = OSAllocatedUnfairLock<Float>(initialState: 0)

    public init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        engine.attach(audioPlayerNode)
        engine.connect(audioPlayerNode, to: engine.mainMixerNode, format: nil)
        audioPlayerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            self.currentOutputLevel.withLock { $0 = AudioLevelMeter.peak(of: buffer) }
        }
    }

    public var level: Float {
        currentOutputLevel.withLock { $0 }
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        stopAllNotes()
        engine.stop()
    }

    /// Wall-clock scheduling via `Task.sleep` for MIDI notes (not sample-accurate
    /// `AVAudioTime` scheduling — acceptable for Phase 1's "audible and roughly
    /// in sync" bar; see docs/midi.md). Audio regions DO use `AVAudioTime`
    /// scheduling via `scheduleFile`, since `AVAudioPlayerNode` wants it and it
    /// costs nothing extra here. `audioRegions` are plain `(url, startBeat)`
    /// pairs, not `AudioRegion` values — this module never resolves filenames
    /// into project-bundle paths, the app layer does that before calling.
    public func play(regions: [MIDIRegion], audioRegions: [(url: URL, startBeat: Double)], tempo: Double) {
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
        for audioRegion in audioRegions {
            guard let file = try? AVAudioFile(forReading: audioRegion.url) else { continue }
            let startSeconds = Tempo.seconds(forBeats: audioRegion.startBeat, tempo: tempo)
            let when = AVAudioTime(
                sampleTime: AVAudioFramePosition(max(startSeconds, 0) * file.processingFormat.sampleRate),
                atRate: file.processingFormat.sampleRate
            )
            audioPlayerNode.scheduleFile(file, at: when)
        }
        audioPlayerNode.play()
    }

    /// Cancels every scheduled note still in flight and silences anything currently
    /// sounding, MIDI or audio. Safe to call when nothing is playing.
    public func stopAllNotes() {
        for task in scheduledTasks {
            task.cancel()
        }
        scheduledTasks.removeAll()
        for pitch in UInt8(0)...UInt8(127) {
            sampler.stopNote(pitch, onChannel: 0)
        }
        audioPlayerNode.stop()
    }
}
```

- [ ] **Step 2: Verify the target builds**

Run: `swift build --target AudioEngine`
Expected: builds with no errors. This target-scoped build does not touch `MeridianStudioApp`, so `AppState.swift`'s not-yet-updated call to the old `play(regions:tempo:)` signature (fixed in Task 8) has no effect here.

- [ ] **Step 3: Commit**

```bash
git add Sources/AudioEngine/PlaybackEngine.swift
git commit -m "PlaybackEngine plays audio regions alongside MIDI"
```

---

## Task 7: `AppState` — Audio Recording Wiring

**Files:**
- Modify: `Sources/MeridianStudioApp/AppState.swift`
- Modify: `Sources/MeridianStudioApp/ProjectDocumentIO.swift`
- Create: `Sources/MeridianStudioApp/AppState+AudioRecording.swift`

**Interfaces:**
- Consumes: `AudioRecorder` (Task 5), `PlaybackEngine.engine` (Task 6), `ProjectDocument.addAudioRegion` (Task 3).
- Produces: `AppState.audioRecorder: AudioRecorder`, `.inputLevel: Float` (published), `startAudioRecording()`/`stopAudioRecording()`, `toggleRecording()` now routes to them for an audio-kind armed track. Used by `AppState`'s own `toggleRecording()` and by `LevelMeterView` (Task 9).

No automated tests for this task — matches the project's established precedent for `AppState` (no test target for the app layer).

- [ ] **Step 1: Make `presentError` reachable from another file**

In `Sources/MeridianStudioApp/ProjectDocumentIO.swift`, replace:

```swift
    private func presentError(_ error: Error) {
        NSAlert(error: error).runModal()
    }
```

with:

```swift
    func presentError(_ error: Error) {
        NSAlert(error: error).runModal()
    }
```

(Removing `private` — Swift's `private` on a top-level extension member scopes to the whole *file*, not the type, so `AppState+AudioRecording.swift`, a different file, cannot call it while it stays `private`. Internal access is still restricted to this module, which is all that's needed.)

- [ ] **Step 2: Make `recordingClock` reachable from another file**

In `Sources/MeridianStudioApp/AppState.swift`, replace:

```swift
    private let recordingClock = RecordingClock()
```

with:

```swift
    let recordingClock = RecordingClock()
```

(Same reasoning as Step 1 — `AppState+AudioRecording.swift` reuses the existing recording-tempo bookkeeping rather than duplicating it.)

- [ ] **Step 3: Add the `audioRecorder` property and `inputLevel`**

In `Sources/MeridianStudioApp/AppState.swift`, replace:

```swift
    /// 0...1, how strongly `applyQuantization()` snaps notes toward the grid —
    /// 1.0 (a hard snap) by default.
    @Published var quantizeStrength: Double = 1.0
```

with:

```swift
    /// 0...1, how strongly `applyQuantization()` snaps notes toward the grid —
    /// 1.0 (a hard snap) by default.
    @Published var quantizeStrength: Double = 1.0
    /// Live microphone input level (0...1-ish peak, not calibrated dB) while an
    /// audio track is armed and recording. Polled the same way `liveNotes`
    /// tracks MIDI input — a visual cue only, maintained via the same timer
    /// that drains the MIDI queue.
    @Published private(set) var inputLevel: Float = 0
```

Replace:

```swift
    let midiInput = CoreMIDIInput()
    let playbackEngine = PlaybackEngine()
    private let recorder: MIDIRecorder
```

with:

```swift
    let midiInput = CoreMIDIInput()
    let playbackEngine = PlaybackEngine()
    let audioRecorder: AudioRecorder
    private let recorder: MIDIRecorder
```

In `init()`, replace:

```swift
        self.recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { [recordingClock] in
            recordingClock.beatsElapsed()
        }))
        bindDocument()
```

with:

```swift
        self.recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { [recordingClock] in
            recordingClock.beatsElapsed()
        }))
        // `playbackEngine`'s own inline initializer has already run by this point
        // in a class's init, so `playbackEngine.engine` is safe to read here —
        // sharing the one running AVAudioEngine is required for simultaneous
        // record + playback (two independent AVAudioEngine instances would each
        // try to own the system's audio hardware).
        self.audioRecorder = AudioRecorder(engine: playbackEngine.engine)
        bindDocument()
```

- [ ] **Step 4: Route `toggleRecording()` by the armed track's kind**

Replace:

```swift
    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }
```

with:

```swift
    var armedTrackKind: TrackKind {
        guard document.project.tracks.indices.contains(selectedTrackIndex) else { return .midi }
        return document.project.tracks[selectedTrackIndex].kind
    }

    func toggleRecording() {
        if isRecording {
            armedTrackKind == .audio ? stopAudioRecording() : stopRecording()
        } else {
            armedTrackKind == .audio ? startAudioRecording() : startRecording()
        }
    }
```

- [ ] **Step 5: Poll the input level**

In `startQueuePolling()`, replace:

```swift
            Task { @MainActor in self.drainMIDIQueue() }
```

with:

```swift
            Task { @MainActor in
                self.drainMIDIQueue()
                self.inputLevel = self.audioRecorder.level
            }
```

- [ ] **Step 6: Create the audio-recording extension**

```swift
// Sources/MeridianStudioApp/AppState+AudioRecording.swift
import AVFoundation
import ProjectModel
import AudioEngine

enum AudioRecordingError: Error, LocalizedError {
    case projectNotSaved

    var errorDescription: String? {
        switch self {
        case .projectNotSaved:
            return "Save this project before recording audio — audio takes are written to a file next to your saved project."
        }
    }
}

extension AppState {
    private static let inProgressAudioFileName = ".recording-in-progress.wav"

    func startAudioRecording() {
        guard let fileURL else {
            presentError(AudioRecordingError.projectNotSaved)
            return
        }
        let workingURL = fileURL.appendingPathComponent("audio").appendingPathComponent(Self.inProgressAudioFileName)
        do {
            try audioRecorder.start(to: workingURL)
            recordingClock.tempo = document.project.tempo
            isRecording = true
        } catch {
            presentError(error)
        }
    }

    func stopAudioRecording() {
        isRecording = false
        guard let workingURL = audioRecorder.stop(), let fileURL else { return }
        guard let file = try? AVAudioFile(forReading: workingURL) else { return }
        let durationSeconds = Double(file.length) / file.processingFormat.sampleRate
        guard durationSeconds > 0 else {
            try? FileManager.default.removeItem(at: workingURL)
            return
        }
        let lengthBeats = Tempo.beats(forSeconds: durationSeconds, tempo: recordingClock.tempo)
        let region = AudioRegion(startBeat: 0, lengthBeats: max(lengthBeats, 0.1), fileName: "\(UUID().uuidString).wav")
        let finalURL = fileURL.appendingPathComponent("audio").appendingPathComponent(region.fileName)
        do {
            try FileManager.default.moveItem(at: workingURL, to: finalURL)
            document.addAudioRegion(region, toTrackAt: selectedTrackIndex)
        } catch {
            presentError(error)
        }
    }
}
```

- [ ] **Step 7: Build**

Run: `swift build`
Expected: builds with no errors. (`play()`'s call to `playbackEngine.play(regions:tempo:)` still uses the pre-Task-6 signature at this point — Task 8 fixes that call site. If this step fails specifically because of that call site and nothing else, that is expected and resolved next task; any other failure is a real problem in this task's own changes.)

- [ ] **Step 8: Commit**

```bash
git add Sources/MeridianStudioApp/AppState.swift Sources/MeridianStudioApp/ProjectDocumentIO.swift Sources/MeridianStudioApp/AppState+AudioRecording.swift
git commit -m "Wire AppState to record audio onto an armed audio track"
```

---

## Task 8: `AppState` — Audio Playback Wiring

**Files:**
- Modify: `Sources/MeridianStudioApp/AppState.swift`

**Interfaces:**
- Consumes: `PlaybackEngine.play(regions:audioRegions:tempo:)`, `.level` (Task 6).
- Produces: `AppState.outputLevel: Float` (published); `play()` now also plays audible tracks' audio regions. Used by `LevelMeterView` (Task 9).

No automated tests for this task — matches the project's established precedent for `AppState`.

- [ ] **Step 1: Add `outputLevel` and poll it**

Replace:

```swift
    /// Live microphone input level (0...1-ish peak, not calibrated dB) while an
    /// audio track is armed and recording. Polled the same way `liveNotes`
    /// tracks MIDI input — a visual cue only, maintained via the same timer
    /// that drains the MIDI queue.
    @Published private(set) var inputLevel: Float = 0
```

with:

```swift
    /// Live microphone input level (0...1-ish peak, not calibrated dB) while an
    /// audio track is armed and recording. Polled the same way `liveNotes`
    /// tracks MIDI input — a visual cue only, maintained via the same timer
    /// that drains the MIDI queue.
    @Published private(set) var inputLevel: Float = 0
    /// Live output level while anything (MIDI or audio) is playing back. Reads
    /// naturally as 0 when nothing is scheduled — the tap receives silence.
    @Published private(set) var outputLevel: Float = 0
```

In `startQueuePolling()`, replace:

```swift
            Task { @MainActor in
                self.drainMIDIQueue()
                self.inputLevel = self.audioRecorder.level
            }
```

with:

```swift
            Task { @MainActor in
                self.drainMIDIQueue()
                self.inputLevel = self.audioRecorder.level
                self.outputLevel = self.playbackEngine.level
            }
```

- [ ] **Step 2: Extend `play()` to also play audio regions**

Replace the full `play()` method:

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

with:

```swift
    func play() {
        let audibleTracks = TrackAudibility.audibleTracks(in: document.project.tracks)
        let regions = audibleTracks.compactMap(\.regions.last)
        let resolvedAudioRegions = resolveAudioRegions(in: audibleTracks)
        guard !regions.isEmpty || !resolvedAudioRegions.isEmpty else { return }
        let tempo = document.project.tempo
        playbackCompletionTask?.cancel()
        isPlaying = true
        playbackEngine.play(regions: regions, audioRegions: resolvedAudioRegions, tempo: tempo)

        // `PlaybackEngine` has no completion callback, so mirror the run length here
        // to clear `isPlaying` when a play-through ends on its own. Duration is the
        // longest of every region being played, MIDI or audio.
        let midiEndBeat = regions.map { region in
            max(region.notes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0, region.lengthBeats)
        }.max() ?? 0
        let audioEndBeat = audibleTracks.compactMap(\.audioRegions.last).map { $0.startBeat + $0.lengthBeats }.max() ?? 0
        let endBeat = max(midiEndBeat, audioEndBeat)
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

    /// Resolves each audible track's most recent audio region's filename against
    /// the project bundle's `audio/` directory. Requires `fileURL` — an audio
    /// track can only ever have a recorded region if the project was already
    /// saved (see `AppState+AudioRecording.swift`), so this never silently drops
    /// audio due to a nil `fileURL` in practice.
    private func resolveAudioRegions(in tracks: [Track]) -> [(url: URL, startBeat: Double)] {
        guard let fileURL else { return [] }
        return tracks.compactMap { track in
            guard let region = track.audioRegions.last else { return nil }
            let url = fileURL.appendingPathComponent("audio").appendingPathComponent(region.fileName)
            return (url: url, startBeat: region.startBeat)
        }
    }
```

- [ ] **Step 3: Build**

Run: `rm -rf .build && swift build`
Expected: builds with no errors, no warnings. This resolves the Task 7 caller-side gap too.

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: all 93 tests still pass — this task adds no new tests, but must not break anything.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeridianStudioApp/AppState.swift
git commit -m "Play audio regions alongside MIDI, with an output level meter"
```

---

## Task 9: UI — Level Meters and Creating an Audio Track

**Files:**
- Create: `Sources/MeridianStudioApp/LevelMeterView.swift`
- Modify: `Sources/MeridianStudioApp/TransportView.swift`
- Modify: `Sources/MeridianStudioApp/TrackListView.swift`
- Modify: `Sources/MeridianStudioApp/AppState.swift` (`addTrack` gains a `kind` parameter)

**Interfaces:**
- Consumes: `AppState.inputLevel`, `.outputLevel` (Task 8), `.armedTrackKind` (Task 7).

No automated tests for this task — matches the project's established precedent for SwiftUI views. Verified by build and the manual smoke test.

If you hit a genuine compiler error in the code below that isn't a trivial, faithful-to-intent fix, STOP and report BLOCKED with root-cause analysis rather than guessing — this has happened several times in this project's history with SwiftUI-specific code.

- [ ] **Step 1: Create `LevelMeterView.swift`**

```swift
// Sources/MeridianStudioApp/LevelMeterView.swift
import SwiftUI

/// A minimal horizontal bar meter — not a calibrated dB scale, not peak-hold,
/// just "how loud is it right now." A real meter is later polish; this exists
/// so input/output has *some* visual confirmation before waveform rendering
/// ships, the same role Phase 1's live MIDI-note highlighting served before
/// full piano-roll editing existed.
struct LevelMeterView: View {
    let label: String
    let level: Float

    private let width: CGFloat = 60
    private let height: CGFloat = 8

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption2).foregroundColor(.secondary)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.secondary.opacity(0.2))
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: width * CGFloat(min(max(level, 0), 1)))
            }
            .frame(width: width, height: height)
        }
    }
}
```

- [ ] **Step 2: Wire both meters into `TransportView`**

Replace:

```swift
            Divider().frame(height: 20)
            HStack {
                Text("Tempo")
                TextField("Tempo", value: tempoBinding, format: .number)
                    .frame(width: 60)
            }
            Spacer()
        }
        .padding(8)
```

with:

```swift
            Divider().frame(height: 20)
            HStack {
                Text("Tempo")
                TextField("Tempo", value: tempoBinding, format: .number)
                    .frame(width: 60)
            }
            Divider().frame(height: 20)
            LevelMeterView(label: "In", level: appState.inputLevel)
            LevelMeterView(label: "Out", level: appState.outputLevel)
            Spacer()
        }
        .padding(8)
```

- [ ] **Step 3: Let `addTrack()` create an audio track**

In `Sources/MeridianStudioApp/AppState.swift`, replace:

```swift
    func addTrack() {
        let name = "Track \(document.project.tracks.count + 1)"
        document.addTrack(Track(name: name))
```

with:

```swift
    func addTrack(kind: TrackKind = .midi) {
        let name = "Track \(document.project.tracks.count + 1)"
        document.addTrack(Track(name: name, kind: kind))
```

(the rest of the method — the `guard !isRecording` and `selectedTrackIndex` assignment — is unchanged, only the signature and the `Track(...)` construction change).

- [ ] **Step 4: Add an audio-track option and per-kind region count to `TrackListView`**

Replace:

```swift
            HStack {
                Text("Tracks").font(.headline)
                Spacer()
                Button(action: { appState.addTrack() }) {
                    Image(systemName: "plus")
                }
            }
            .padding(8)
```

with:

```swift
            HStack {
                Text("Tracks").font(.headline)
                Spacer()
                Menu {
                    Button("Add MIDI Track") { appState.addTrack(kind: .midi) }
                    Button("Add Audio Track") { appState.addTrack(kind: .audio) }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .padding(8)
```

Replace:

```swift
                        Text("\(track.regions.count) region(s)")
                            .font(.caption)
                            .foregroundColor(.secondary)
```

with:

```swift
                        Text("\(track.kind == .audio ? track.audioRegions.count : track.regions.count) region(s)")
                            .font(.caption)
                            .foregroundColor(.secondary)
```

- [ ] **Step 5: Build**

Run: `rm -rf .build && swift build`
Expected: builds with no errors, no warnings.

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: all 93 tests still pass.

- [ ] **Step 7: Manual smoke test**

Run: `swift run MeridianStudioApp`

Check (in addition to everything from prior milestones' smoke-test checklists):
- Save the project first (File > Save As) — required before audio recording will work.
- The "+" button in the track list now offers "Add MIDI Track" and "Add Audio Track".
- Add an audio track, select it, press Record — the "In" meter near the transport should move while you speak or play into the microphone.
- Press Stop — a region should appear in that track's row ("1 region(s)").
- Press Play — you should hear the recorded audio play back, and the "Out" meter should move.
- Press Stop mid-playback — audio should stop immediately, not trail off.
- Try recording on an audio track *before* ever saving the project (in a fresh, unsaved project) — you should see an alert telling you to save first, not a crash or silent failure.
- Confirm MIDI recording/playback on a MIDI track still works exactly as before (no regression).

- [ ] **Step 8: Commit**

```bash
git add Sources/MeridianStudioApp/LevelMeterView.swift Sources/MeridianStudioApp/TransportView.swift Sources/MeridianStudioApp/TrackListView.swift Sources/MeridianStudioApp/AppState.swift
git commit -m "Add level meters and audio-track creation to the UI"
```

---

## Task 10: Documentation

**Files:**
- Modify: `docs/architecture.md`
- Create: `docs/audio.md`

**Interfaces:** None — documentation only, reflecting what Tasks 1–9 built.

- [ ] **Step 1: Add an audio-recording paragraph to `docs/architecture.md`**

Replace:

```markdown
There is no audio-recording engine, mixer, or AI layer yet — see the
roadmap in the Phase 0 spec.
```

with:

```markdown
Audio recording & playback (Phase 3, first milestone): `TrackKind.audio`
and `AudioRegion` extend the data model the same way multi-track and
note-level editing did — `Track.audioRegions` decodes to `[]` for any
project file saved before this field existed, the same
`decodeIfPresent` pattern `NoteEvent.id` established. `AudioRegion`
stores only a filename, never an absolute path, so a project bundle can
move on disk without breaking it; the app layer resolves it against the
bundle's `audio/` directory. `ProjectDocument.addAudioRegion`/
`removeAudioRegion` are undo-registered structural operations, mirroring
`addRegion`/`removeRegion` exactly. Recording onto an audio track
requires the project to already be saved — audio data is too large to
hold as an in-memory value the way MIDI notes are, and an unsaved
project has nowhere on disk to write a file, so this milestone defers
the temporary-file staging a "record before saving" experience would
need, the same "leave the adjacent complexity for later" call this
project has made repeatedly. See `docs/audio.md` for the audio engine's
real-time-safety tradeoffs, mirroring `docs/midi.md`'s role for MIDI.

There is no mixer or AI layer yet — see the roadmap in the Phase 0 spec.
```

- [ ] **Step 2: Create `docs/audio.md`**

```markdown
# Audio Engine

## Recording
`AudioRecorder` taps `AVAudioEngine.inputNode` and writes each buffer to
an `AVAudioFile` directly inside the tap callback, computing a peak
level (`AudioLevelMeter.peak(of:)`) the same way. This is the standard,
widely-used pattern for straightforward single-track recording — it is,
in fact, what Apple's own basic recording sample code does — but it is
not the glitch-proof design a professional multitrack DAW eventually
needs: writing to disk from a real-time audio callback is not strictly
real-time-safe (file I/O can block), and under heavy system load this
could produce audible glitches or dropped buffers. A ring buffer
handed off to a separate writer thread — the same shape `MIDIEventQueue`
already uses for CoreMIDI input — is the fix, deferred until it proves
necessary in practice.

Recording onto an audio track requires the project to already have a
save location (`AppState.fileURL != nil`). Raw PCM audio cannot be held
in memory as a `Codable` value the way `NoteEvent`s are; it must live in
a file, and a brand-new project has no bundle to put one in yet.
Building temporary-file staging (recording to a scratch location, then
promoting/copying it into the bundle at first save, with cleanup on
discard) is real, additional complexity this milestone defers — the app
surfaces a clear alert rather than crashing or silently failing.

## Playback
`PlaybackEngine` schedules audio regions via `AVAudioPlayerNode.scheduleFile(at:)`
using sample-accurate `AVAudioTime` — a meaningfully different approach
from the existing MIDI note scheduling, which uses wall-clock
`Task.sleep` (see docs/midi.md). Both paths currently produce the same
"audible and roughly in sync" result; unifying them under one scheduling
strategy is a candidate future refinement, not a Phase 3 requirement.

## Level meters
`AudioLevelMeter.peak(of:)` is a simple peak meter — the largest
absolute sample value across every channel and frame in one buffer —
not RMS, not a calibrated dB scale, and with no peak-hold. It is pure
and hardware-free, so it is the one piece of audio metering with
automated test coverage; `AudioRecorder`/`PlaybackEngine`'s actual tap
installation is hardware-adjacent and untested, matching this project's
existing precedent for `CoreMIDIInput`. `LevelMeterView` renders it as a
plain proportional bar. A real meter (logarithmic scale, peak-hold,
color zones) is later polish.

## Non-goals of this milestone
No waveform rendering (a real visual of the recorded shape, not just a
level meter), no trim/split/fade/normalize, no importing existing audio
files, no per-track gain/pan, and no glitch-proof capture under load —
all deferred to later Phase 3 milestones or Phase 4's mixer.
```

- [ ] **Step 3: Commit**

```bash
git add docs/architecture.md docs/audio.md
git commit -m "Document the audio engine's architecture and real-time-safety tradeoffs"
```

- [ ] **Step 4: Push**

```bash
git push origin main
```
