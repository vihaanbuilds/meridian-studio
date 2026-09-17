# Phase 1 App Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Phase 1 Meridian Studio app shell: one MIDI track, MIDI keyboard input/recording/playback, a basic timeline and piano roll, and save/open, as a pure Swift Package Manager project buildable without Xcode.

**Architecture:** Three SPM targets — `ProjectModel` (UI-independent Codable data model + versioned persistence + undo), `MIDIEngine` (CoreMIDI input adapter, pure MIDI parsing/recording logic, AVAudioEngine-based playback), and `MeridianStudioApp` (SwiftUI executable depending on both). Hardware-touching code (CoreMIDI, AVAudioEngine) is kept thin; all the interesting logic (parsing, note-pairing, scheduling math, persistence) is pure and unit tested.

**Tech Stack:** Swift 6, SwiftUI, CoreMIDI, AVFoundation (`AVAudioEngine`/`AVAudioUnitSampler`), XCTest, Swift Package Manager (no Xcode project, no third-party dependencies).

**Spec:** `docs/superpowers/specs/2026-09-16-meridian-studio-design.md`

## Global Constraints

- Deployment target: macOS 14.0+ (spec Section 10).
- Zero third-party dependencies in Phase 1 (spec Section 6).
- Real-time safety: the CoreMIDI read callback thread must never allocate beyond a fixed buffer, block, log, or touch the project model directly — it only parses bytes and pushes onto a thread-safe queue (spec Section 8).
- No Xcode required locally; the app is a plain SPM executable target, built/run/tested via `swift build` / `swift run` / `swift test` (spec Section 4).
- License: MIT (already in repo root).
- `swift test` must pass locally and in CI (spec Section 12).
- Project files are versioned JSON bundles (`.mstudio` directories) with an explicit `schemaVersion` (spec Section 7).

---

## Task 1: SPM Package Skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/ProjectModel/.gitkeep` (placeholder removed once Task 2 adds real files)
- Create: `Sources/MIDIEngine/.gitkeep`
- Create: `Sources/MeridianStudioApp/.gitkeep`

**Interfaces:**
- Produces: three library/executable targets (`ProjectModel`, `MIDIEngine`, `MeridianStudioApp`) and two test targets (`ProjectModelTests`, `MIDIEngineTests`) that every later task builds on.

- [ ] **Step 1: Create `Package.swift`**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeridianStudio",
    platforms: [.macOS(.v14)],
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
)
```

- [ ] **Step 2: Create empty source directories so SwiftPM recognizes the targets**

```bash
mkdir -p Sources/ProjectModel Sources/MIDIEngine Sources/MeridianStudioApp
mkdir -p Tests/ProjectModelTests Tests/MIDIEngineTests
touch Sources/ProjectModel/.gitkeep Sources/MIDIEngine/.gitkeep Sources/MeridianStudioApp/.gitkeep
touch Tests/ProjectModelTests/.gitkeep Tests/MIDIEngineTests/.gitkeep
```

- [ ] **Step 3: Verify the manifest resolves**

Run: `swift package describe`
Expected: lists the three targets and two test targets with no errors. (`swift build` will fail until Task 2 adds real source files — that's expected at this point.)

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "Add SPM package skeleton for Phase 1"
```

---

## Task 2: ProjectModel Core Types

**Files:**
- Create: `Sources/ProjectModel/NoteEvent.swift`
- Create: `Sources/ProjectModel/TimeSignature.swift`
- Create: `Sources/ProjectModel/MIDIRegion.swift`
- Create: `Sources/ProjectModel/Track.swift`
- Create: `Sources/ProjectModel/Project.swift`
- Delete: `Sources/ProjectModel/.gitkeep`
- Test: `Tests/ProjectModelTests/CodableRoundTripTests.swift`
- Delete: `Tests/ProjectModelTests/.gitkeep`

**Interfaces:**
- Produces: `NoteEvent(pitch: UInt8, velocity: UInt8, startBeat: Double, lengthBeats: Double)`, `TimeSignature(numerator: Int, denominator: Int)`, `MIDIRegion(id: UUID, startBeat: Double, lengthBeats: Double, notes: [NoteEvent])`, `TrackKind.midi`, `Track(id: UUID, name: String, kind: TrackKind, muted: Bool, solo: Bool, regions: [MIDIRegion])`, `Project(schemaVersion: Int, sampleRate: Double, tempo: Double, timeSignature: TimeSignature, tracks: [Track])`, `Project.currentSchemaVersion`. All `Codable`, `Equatable`, `Sendable`; `MIDIRegion` and `Track` are `Identifiable`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ProjectModelTests/CodableRoundTripTests.swift
import XCTest
@testable import ProjectModel

final class CodableRoundTripTests: XCTestCase {
    func testNoteEventRoundTrips() throws {
        let note = NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(NoteEvent.self, from: data)
        XCTAssertEqual(decoded, note)
    }

    func testProjectRoundTrips() throws {
        let note = NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 2)
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [note])
        let track = Track(name: "Piano", regions: [region])
        let project = Project(tracks: [track])

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(Project.self, from: data)

        XCTAssertEqual(decoded, project)
        XCTAssertEqual(decoded.schemaVersion, Project.currentSchemaVersion)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter CodableRoundTripTests`
Expected: FAIL — `NoteEvent`/`MIDIRegion`/`Track`/`Project` do not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/ProjectModel/NoteEvent.swift
import Foundation

public struct NoteEvent: Codable, Equatable, Sendable {
    public var pitch: UInt8
    public var velocity: UInt8
    public var startBeat: Double
    public var lengthBeats: Double

    public init(pitch: UInt8, velocity: UInt8, startBeat: Double, lengthBeats: Double) {
        self.pitch = pitch
        self.velocity = velocity
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
    }
}
```

```swift
// Sources/ProjectModel/TimeSignature.swift
public struct TimeSignature: Codable, Equatable, Sendable {
    public var numerator: Int
    public var denominator: Int

    public init(numerator: Int = 4, denominator: Int = 4) {
        self.numerator = numerator
        self.denominator = denominator
    }
}
```

```swift
// Sources/ProjectModel/MIDIRegion.swift
import Foundation

public struct MIDIRegion: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startBeat: Double
    public var lengthBeats: Double
    public var notes: [NoteEvent]

    public init(id: UUID = UUID(), startBeat: Double, lengthBeats: Double, notes: [NoteEvent] = []) {
        self.id = id
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
        self.notes = notes
    }
}
```

```swift
// Sources/ProjectModel/Track.swift
import Foundation

public enum TrackKind: String, Codable, Sendable {
    case midi
}

public struct Track: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: TrackKind
    public var muted: Bool
    public var solo: Bool
    public var regions: [MIDIRegion]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: TrackKind = .midi,
        muted: Bool = false,
        solo: Bool = false,
        regions: [MIDIRegion] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.muted = muted
        self.solo = solo
        self.regions = regions
    }
}
```

```swift
// Sources/ProjectModel/Project.swift
public struct Project: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var sampleRate: Double
    public var tempo: Double
    public var timeSignature: TimeSignature
    public var tracks: [Track]

    public init(
        sampleRate: Double = 44100,
        tempo: Double = 120,
        timeSignature: TimeSignature = TimeSignature(),
        tracks: [Track] = []
    ) {
        self.schemaVersion = Project.currentSchemaVersion
        self.sampleRate = sampleRate
        self.tempo = tempo
        self.timeSignature = timeSignature
        self.tracks = tracks
    }
}
```

- [ ] **Step 4: Remove placeholder files**

```bash
rm Sources/ProjectModel/.gitkeep Tests/ProjectModelTests/.gitkeep
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter CodableRoundTripTests`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ProjectModel Tests/ProjectModelTests
git commit -m "Add ProjectModel core types with Codable round-trip tests"
```

---

## Task 3: Tempo Beat/Second Conversion

**Files:**
- Create: `Sources/ProjectModel/Tempo.swift`
- Test: `Tests/ProjectModelTests/TempoTests.swift`

**Interfaces:**
- Produces: `Tempo.seconds(forBeats: Double, tempo: Double) -> Double`, `Tempo.beats(forSeconds: Double, tempo: Double) -> Double`. Used by `MIDIEngine`'s `PlaybackScheduler` (Task 9) and the app's `RecordingClock` (Task 13).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ProjectModelTests/TempoTests.swift
import XCTest
@testable import ProjectModel

final class TempoTests: XCTestCase {
    func testSecondsAt120BPM() {
        XCTAssertEqual(Tempo.seconds(forBeats: 1, tempo: 120), 0.5, accuracy: 0.0001)
    }

    func testSecondsAt60BPM() {
        XCTAssertEqual(Tempo.seconds(forBeats: 4, tempo: 60), 4.0, accuracy: 0.0001)
    }

    func testBeatsAt120BPM() {
        XCTAssertEqual(Tempo.beats(forSeconds: 1, tempo: 120), 2.0, accuracy: 0.0001)
    }

    func testRoundTripIsIdentity() {
        let seconds = Tempo.seconds(forBeats: 3.5, tempo: 97)
        XCTAssertEqual(Tempo.beats(forSeconds: seconds, tempo: 97), 3.5, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TempoTests`
Expected: FAIL — `Tempo` does not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/ProjectModel/Tempo.swift
public enum Tempo {
    public static func seconds(forBeats beats: Double, tempo: Double) -> Double {
        beats * 60.0 / tempo
    }

    public static func beats(forSeconds seconds: Double, tempo: Double) -> Double {
        seconds * tempo / 60.0
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TempoTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectModel/Tempo.swift Tests/ProjectModelTests/TempoTests.swift
git commit -m "Add Tempo beat/second conversion"
```

---

## Task 4: ProjectStore Persistence & Schema Versioning

**Files:**
- Create: `Sources/ProjectModel/ProjectStore.swift`
- Test: `Tests/ProjectModelTests/ProjectStoreTests.swift`

**Interfaces:**
- Consumes: `Project` (Task 2).
- Produces: `ProjectStoreError.unsupportedSchemaVersion(Int)`, `ProjectStore.save(_ project: Project, to url: URL) throws`, `ProjectStore.load(from url: URL) throws -> Project`. Used by the app's file menu (Task 14) and the integration test (Task 12).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ProjectModelTests/ProjectStoreTests.swift
import XCTest
@testable import ProjectModel

final class ProjectStoreTests: XCTestCase {
    private func makeTempBundleURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Test.mstudio")
    }

    func testSaveAndLoadRoundTrips() throws {
        let project = Project(tracks: [Track(name: "Piano")])
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try ProjectStore.save(project, to: url)
        let loaded = try ProjectStore.load(from: url)

        XCTAssertEqual(loaded, project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("midi").path))
    }

    func testLoadRejectsUnsupportedSchemaVersion() throws {
        let url = makeTempBundleURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let futureVersionJSON = """
        {"schemaVersion": 999, "sampleRate": 44100, "tempo": 120, "timeSignature": {"numerator": 4, "denominator": 4}, "tracks": []}
        """
        try futureVersionJSON.write(to: url.appendingPathComponent("project.json"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectStore.load(from: url)) { error in
            XCTAssertEqual(error as? ProjectStoreError, .unsupportedSchemaVersion(999))
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProjectStoreTests`
Expected: FAIL — `ProjectStore` does not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/ProjectModel/ProjectStore.swift
import Foundation

public enum ProjectStoreError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

public enum ProjectStore {
    private static let projectFileName = "project.json"
    private static let midiDirectoryName = "midi"

    public static func save(_ project: Project, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: url.appendingPathComponent(midiDirectoryName, isDirectory: true),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        try data.write(to: url.appendingPathComponent(projectFileName), options: .atomic)
    }

    public static func load(from url: URL) throws -> Project {
        let data = try Data(contentsOf: url.appendingPathComponent(projectFileName))
        let project = try JSONDecoder().decode(Project.self, from: data)
        try migrate(project)
        return project
    }

    private static func migrate(_ project: Project) throws {
        guard project.schemaVersion == Project.currentSchemaVersion else {
            throw ProjectStoreError.unsupportedSchemaVersion(project.schemaVersion)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProjectStoreTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectModel/ProjectStore.swift Tests/ProjectModelTests/ProjectStoreTests.swift
git commit -m "Add versioned project persistence"
```

---

## Task 5: ProjectDocument (Undo-Capable Wrapper)

**Files:**
- Create: `Sources/ProjectModel/ProjectDocument.swift`
- Test: `Tests/ProjectModelTests/ProjectDocumentTests.swift`

**Interfaces:**
- Consumes: `Project`, `Track`, `MIDIRegion` (Task 2).
- Produces: `@MainActor final class ProjectDocument: ObservableObject` with `var project: Project { get }`, `let undoManager: UndoManager`, `func addRegion(_ region: MIDIRegion, toTrackAt trackIndex: Int)`, `func removeRegion(id: UUID, fromTrackAt trackIndex: Int)`, `func setTempo(_ tempo: Double)`, `init(project: Project = Project())`. Used by the app layer (Tasks 13–14) and the integration test (Task 12).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/ProjectModelTests/ProjectDocumentTests.swift
import XCTest
@testable import ProjectModel

@MainActor
final class ProjectDocumentTests: XCTestCase {
    func testAddRegionAppendsToTrack() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [])
        doc.addRegion(region, toTrackAt: 0)
        XCTAssertEqual(doc.project.tracks[0].regions.count, 1)
    }

    func testUndoRemovesRecordedRegion() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [])
        doc.addRegion(region, toTrackAt: 0)
        doc.undoManager.undo()
        XCTAssertEqual(doc.project.tracks[0].regions.count, 0)
    }

    func testRedoReAddsRegion() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        let region = MIDIRegion(startBeat: 0, lengthBeats: 4, notes: [])
        doc.addRegion(region, toTrackAt: 0)
        doc.undoManager.undo()
        doc.undoManager.redo()
        XCTAssertEqual(doc.project.tracks[0].regions.count, 1)
    }

    func testSetTempoUpdatesProject() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        doc.setTempo(140)
        XCTAssertEqual(doc.project.tempo, 140)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ProjectDocumentTests`
Expected: FAIL — `ProjectDocument` does not exist yet.

- [ ] **Step 3: Write the implementation**

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

    public func addRegion(_ region: MIDIRegion, toTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        project.tracks[trackIndex].regions.append(region)
        undoManager.registerUndo(withTarget: self) { doc in
            doc.removeRegion(id: region.id, fromTrackAt: trackIndex)
        }
    }

    public func removeRegion(id: UUID, fromTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].regions.firstIndex(where: { $0.id == id }) else { return }
        let removed = project.tracks[trackIndex].regions.remove(at: index)
        undoManager.registerUndo(withTarget: self) { doc in
            doc.addRegion(removed, toTrackAt: trackIndex)
        }
    }

    public func setTempo(_ tempo: Double) {
        project.tempo = tempo
    }

    public func replaceProject(_ newProject: Project) {
        project = newProject
        undoManager.removeAllActions()
    }
}
```

Note: `project` is declared `public private(set)` — within this file, methods of `ProjectDocument` may still assign it directly (`private(set)` restricts writes to *outside* the type, not to other methods of the same type).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ProjectDocumentTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ProjectModel/ProjectDocument.swift Tests/ProjectModelTests/ProjectDocumentTests.swift
git commit -m "Add undo-capable ProjectDocument wrapper"
```

---

## Task 6: MIDIEventQueue (Thread-Safe Ring Buffer)

**Files:**
- Create: `Sources/MIDIEngine/RawMIDIMessage.swift`
- Create: `Sources/MIDIEngine/MIDIEventQueue.swift`
- Delete: `Sources/MIDIEngine/.gitkeep`
- Test: `Tests/MIDIEngineTests/MIDIEventQueueTests.swift`
- Delete: `Tests/MIDIEngineTests/.gitkeep`

**Interfaces:**
- Produces: `RawMIDIMessage(status: UInt8, data1: UInt8, data2: UInt8, timestamp: UInt64)` (`Equatable`, `Sendable`), `MIDIEventQueue(capacity: Int = 256)` with `func push(_ message: RawMIDIMessage)` and `func drain() -> [RawMIDIMessage]`, both `Sendable`. Used by `CoreMIDIInput` (Task 10) and the app's polling loop (Task 13).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/MIDIEngineTests/MIDIEventQueueTests.swift
import XCTest
@testable import MIDIEngine

final class MIDIEventQueueTests: XCTestCase {
    func testPushAndDrainPreservesOrder() {
        let queue = MIDIEventQueue(capacity: 4)
        let messages = (0..<3).map { RawMIDIMessage(status: 0x90, data1: UInt8($0), data2: 100, timestamp: 0) }
        messages.forEach { queue.push($0) }
        XCTAssertEqual(queue.drain(), messages)
    }

    func testDropsMessagesWhenFull() {
        let queue = MIDIEventQueue(capacity: 2)
        queue.push(RawMIDIMessage(status: 0x90, data1: 1, data2: 100, timestamp: 0))
        queue.push(RawMIDIMessage(status: 0x90, data1: 2, data2: 100, timestamp: 0))
        queue.push(RawMIDIMessage(status: 0x90, data1: 3, data2: 100, timestamp: 0)) // dropped, queue is full

        let drained = queue.drain()
        XCTAssertEqual(drained.map(\.data1), [1, 2])
    }

    func testDrainEmptiesQueue() {
        let queue = MIDIEventQueue()
        queue.push(RawMIDIMessage(status: 0x90, data1: 1, data2: 100, timestamp: 0))
        _ = queue.drain()
        XCTAssertEqual(queue.drain(), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MIDIEventQueueTests`
Expected: FAIL — `RawMIDIMessage`/`MIDIEventQueue` do not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/MIDIEngine/RawMIDIMessage.swift
public struct RawMIDIMessage: Equatable, Sendable {
    public var status: UInt8
    public var data1: UInt8
    public var data2: UInt8
    public var timestamp: UInt64

    public init(status: UInt8, data1: UInt8, data2: UInt8, timestamp: UInt64) {
        self.status = status
        self.data1 = data1
        self.data2 = data2
        self.timestamp = timestamp
    }
}
```

```swift
// Sources/MIDIEngine/MIDIEventQueue.swift
import os

/// Thread-safe handoff from the CoreMIDI callback thread to the main actor.
/// Allocation-free after construction; drops the newest message rather than
/// blocking or growing when full, per the real-time-safety principle.
public final class MIDIEventQueue: Sendable {
    private struct State {
        var buffer: [RawMIDIMessage?]
        var head = 0
        var tail = 0
        var count = 0
    }

    private let storage: OSAllocatedUnfairLock<State>

    public init(capacity: Int = 256) {
        storage = OSAllocatedUnfairLock(initialState: State(buffer: Array(repeating: nil, count: capacity)))
    }

    public func push(_ message: RawMIDIMessage) {
        storage.withLock { state in
            guard state.count < state.buffer.count else { return }
            state.buffer[state.tail] = message
            state.tail = (state.tail + 1) % state.buffer.count
            state.count += 1
        }
    }

    public func drain() -> [RawMIDIMessage] {
        storage.withLock { state in
            var result: [RawMIDIMessage] = []
            result.reserveCapacity(state.count)
            while state.count > 0 {
                if let message = state.buffer[state.head] {
                    result.append(message)
                }
                state.buffer[state.head] = nil
                state.head = (state.head + 1) % state.buffer.count
                state.count -= 1
            }
            return result
        }
    }
}
```

- [ ] **Step 4: Remove placeholder files**

```bash
rm Sources/MIDIEngine/.gitkeep Tests/MIDIEngineTests/.gitkeep
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter MIDIEventQueueTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/MIDIEngine Tests/MIDIEngineTests
git commit -m "Add thread-safe MIDI event queue"
```

---

## Task 7: MIDI Message Parsing

**Files:**
- Create: `Sources/MIDIEngine/MIDIMessageParser.swift`
- Test: `Tests/MIDIEngineTests/MIDIMessageParserTests.swift`

**Interfaces:**
- Consumes: `RawMIDIMessage` (Task 6).
- Produces: `ParsedMIDIEvent` enum (`.noteOn(pitch: UInt8, velocity: UInt8, timestamp: UInt64)`, `.noteOff(pitch: UInt8, timestamp: UInt64)`, `.other`), `MIDIMessageParser.parse(_ message: RawMIDIMessage) -> ParsedMIDIEvent`. Used by `MIDIRecorder` (Task 8).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/MIDIEngineTests/MIDIMessageParserTests.swift
import XCTest
@testable import MIDIEngine

final class MIDIMessageParserTests: XCTestCase {
    func testNoteOnParses() {
        let event = MIDIMessageParser.parse(RawMIDIMessage(status: 0x90, data1: 60, data2: 100, timestamp: 5))
        XCTAssertEqual(event, .noteOn(pitch: 60, velocity: 100, timestamp: 5))
    }

    func testNoteOnWithZeroVelocityIsNoteOff() {
        let event = MIDIMessageParser.parse(RawMIDIMessage(status: 0x90, data1: 60, data2: 0, timestamp: 5))
        XCTAssertEqual(event, .noteOff(pitch: 60, timestamp: 5))
    }

    func testNoteOffParses() {
        let event = MIDIMessageParser.parse(RawMIDIMessage(status: 0x80, data1: 60, data2: 64, timestamp: 5))
        XCTAssertEqual(event, .noteOff(pitch: 60, timestamp: 5))
    }

    func testControlChangeIsOther() {
        let event = MIDIMessageParser.parse(RawMIDIMessage(status: 0xB0, data1: 7, data2: 127, timestamp: 5))
        XCTAssertEqual(event, .other)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MIDIMessageParserTests`
Expected: FAIL — `ParsedMIDIEvent`/`MIDIMessageParser` do not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/MIDIEngine/MIDIMessageParser.swift
public enum ParsedMIDIEvent: Equatable, Sendable {
    case noteOn(pitch: UInt8, velocity: UInt8, timestamp: UInt64)
    case noteOff(pitch: UInt8, timestamp: UInt64)
    case other
}

public enum MIDIMessageParser {
    public static func parse(_ message: RawMIDIMessage) -> ParsedMIDIEvent {
        switch message.status & 0xF0 {
        case 0x90:
            if message.data2 == 0 {
                return .noteOff(pitch: message.data1, timestamp: message.timestamp)
            }
            return .noteOn(pitch: message.data1, velocity: message.data2, timestamp: message.timestamp)
        case 0x80:
            return .noteOff(pitch: message.data1, timestamp: message.timestamp)
        default:
            return .other
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MIDIMessageParserTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MIDIEngine/MIDIMessageParser.swift Tests/MIDIEngineTests/MIDIMessageParserTests.swift
git commit -m "Add pure MIDI message parsing"
```

---

## Task 8: MIDIRecorder (Note Pairing)

**Files:**
- Create: `Sources/MIDIEngine/MIDIRecorder.swift`
- Test: `Tests/MIDIEngineTests/MIDIRecorderTests.swift`

**Interfaces:**
- Consumes: `ParsedMIDIEvent` (Task 7), `NoteEvent` (Task 2, via `ProjectModel`).
- Produces: `NoteRecorderClock(nowBeats: @escaping () -> Double)`, `@MainActor final class MIDIRecorder` with `init(clock: NoteRecorderClock)`, `func handle(_ event: ParsedMIDIEvent)`, `var recordedNotes: [NoteEvent] { get }`, `func reset()`. Used by the app's recording loop (Task 13) and the integration test (Task 12).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/MIDIEngineTests/MIDIRecorderTests.swift
import XCTest
import ProjectModel
@testable import MIDIEngine

@MainActor
final class MIDIRecorderTests: XCTestCase {
    func testRecordsSingleNote() {
        var time = 0.0
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { time }))

        recorder.handle(.noteOn(pitch: 60, velocity: 100, timestamp: 0))
        time = 1.0
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))

        XCTAssertEqual(recorder.recordedNotes, [NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)])
    }

    func testRecordsOverlappingNotesOnDifferentPitches() {
        var time = 0.0
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { time }))

        recorder.handle(.noteOn(pitch: 60, velocity: 100, timestamp: 0))
        time = 0.5
        recorder.handle(.noteOn(pitch: 64, velocity: 90, timestamp: 0))
        time = 1.0
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))
        time = 1.5
        recorder.handle(.noteOff(pitch: 64, timestamp: 0))

        XCTAssertEqual(recorder.recordedNotes, [
            NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
            NoteEvent(pitch: 64, velocity: 90, startBeat: 0.5, lengthBeats: 1)
        ])
    }

    func testNoteOffWithoutMatchingNoteOnIsIgnored() {
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { 0 }))
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))
        XCTAssertEqual(recorder.recordedNotes, [])
    }

    func testResetClearsState() {
        var time = 0.0
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { time }))
        recorder.handle(.noteOn(pitch: 60, velocity: 100, timestamp: 0))
        time = 1.0
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))
        recorder.reset()
        XCTAssertEqual(recorder.recordedNotes, [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MIDIRecorderTests`
Expected: FAIL — `NoteRecorderClock`/`MIDIRecorder` do not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/MIDIEngine/MIDIRecorder.swift
import ProjectModel

public struct NoteRecorderClock {
    public var nowBeats: () -> Double

    public init(nowBeats: @escaping () -> Double) {
        self.nowBeats = nowBeats
    }
}

@MainActor
public final class MIDIRecorder {
    private var activeNotes: [UInt8: (velocity: UInt8, startBeat: Double)] = [:]
    public private(set) var recordedNotes: [NoteEvent] = []
    private let clock: NoteRecorderClock

    public init(clock: NoteRecorderClock) {
        self.clock = clock
    }

    public func handle(_ event: ParsedMIDIEvent) {
        switch event {
        case .noteOn(let pitch, let velocity, _):
            activeNotes[pitch] = (velocity, clock.nowBeats())
        case .noteOff(let pitch, _):
            guard let started = activeNotes.removeValue(forKey: pitch) else { return }
            let length = max(clock.nowBeats() - started.startBeat, 0.0)
            recordedNotes.append(
                NoteEvent(pitch: pitch, velocity: started.velocity, startBeat: started.startBeat, lengthBeats: length)
            )
        case .other:
            break
        }
    }

    public func reset() {
        activeNotes.removeAll()
        recordedNotes.removeAll()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MIDIRecorderTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/MIDIEngine/MIDIRecorder.swift Tests/MIDIEngineTests/MIDIRecorderTests.swift
git commit -m "Add MIDI note-pairing recorder"
```

---

## Task 9: PlaybackScheduler (Pure Scheduling Math)

**Files:**
- Create: `Sources/MIDIEngine/PlaybackScheduler.swift`
- Test: `Tests/MIDIEngineTests/PlaybackSchedulerTests.swift`

**Interfaces:**
- Consumes: `MIDIRegion`, `Tempo` (Task 2/3, via `ProjectModel`).
- Produces: `ScheduledNote(pitch: UInt8, velocity: UInt8, startSeconds: Double, lengthSeconds: Double)` (`Equatable`), `PlaybackScheduler.schedule(region: MIDIRegion, tempo: Double) -> [ScheduledNote]`. Used by `PlaybackEngine` (Task 11).

- [ ] **Step 1: Write the failing test**

```swift
// Tests/MIDIEngineTests/PlaybackSchedulerTests.swift
import XCTest
import ProjectModel
@testable import MIDIEngine

final class PlaybackSchedulerTests: XCTestCase {
    func testSchedulesNotesAt120BPM() {
        let region = MIDIRegion(startBeat: 0, lengthBeats: 2, notes: [
            NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
            NoteEvent(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 0.5)
        ])

        let scheduled = PlaybackScheduler.schedule(region: region, tempo: 120)

        XCTAssertEqual(scheduled, [
            ScheduledNote(pitch: 60, velocity: 100, startSeconds: 0, lengthSeconds: 0.5),
            ScheduledNote(pitch: 64, velocity: 90, startSeconds: 0.5, lengthSeconds: 0.25)
        ])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PlaybackSchedulerTests`
Expected: FAIL — `ScheduledNote`/`PlaybackScheduler` do not exist yet.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/MIDIEngine/PlaybackScheduler.swift
import ProjectModel

public struct ScheduledNote: Equatable {
    public var pitch: UInt8
    public var velocity: UInt8
    public var startSeconds: Double
    public var lengthSeconds: Double

    public init(pitch: UInt8, velocity: UInt8, startSeconds: Double, lengthSeconds: Double) {
        self.pitch = pitch
        self.velocity = velocity
        self.startSeconds = startSeconds
        self.lengthSeconds = lengthSeconds
    }
}

public enum PlaybackScheduler {
    public static func schedule(region: MIDIRegion, tempo: Double) -> [ScheduledNote] {
        region.notes.map { note in
            ScheduledNote(
                pitch: note.pitch,
                velocity: note.velocity,
                startSeconds: Tempo.seconds(forBeats: note.startBeat, tempo: tempo),
                lengthSeconds: Tempo.seconds(forBeats: note.lengthBeats, tempo: tempo)
            )
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PlaybackSchedulerTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add Sources/MIDIEngine/PlaybackScheduler.swift Tests/MIDIEngineTests/PlaybackSchedulerTests.swift
git commit -m "Add pure playback scheduling math"
```

---

## Task 10: CoreMIDIInput Hardware Adapter

**Files:**
- Create: `Sources/MIDIEngine/CoreMIDIInput.swift`

**Interfaces:**
- Consumes: `RawMIDIMessage`, `MIDIEventQueue` (Task 6).
- Produces: `enum MIDIEngineError: Error` (`.clientCreationFailed(OSStatus)`, `.portCreationFailed(OSStatus)`), `final class CoreMIDIInput` with `let queue: MIDIEventQueue`, `func start() throws`, `func stop()`. Used by `AppState` (Task 13).

This task has no automated tests — it requires a real CoreMIDI daemon connection, which unit tests can't meaningfully exercise. It's verified by a successful build plus the manual smoke test in Task 13.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/MIDIEngine/CoreMIDIInput.swift
import CoreMIDI
import Darwin

public enum MIDIEngineError: Error {
    case clientCreationFailed(OSStatus)
    case portCreationFailed(OSStatus)
}

/// Thin adapter over the classic (MIDI 1.0) CoreMIDI API. Parses only
/// simple 3-byte channel messages starting at the beginning of a packet —
/// it does not handle running status or SysEx, which real keyboards
/// typically don't send for plain note on/off. That's a documented Phase 1
/// limitation (see docs/midi.md).
public final class CoreMIDIInput {
    public let queue = MIDIEventQueue()
    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()

    public init() {}

    public func start() throws {
        var newClient = MIDIClientRef()
        let clientStatus = MIDIClientCreate("MeridianStudio" as CFString, nil, nil, &newClient)
        guard clientStatus == noErr else { throw MIDIEngineError.clientCreationFailed(clientStatus) }
        client = newClient

        var newPort = MIDIPortRef()
        let context = Unmanaged.passUnretained(self).toOpaque()
        let portStatus = MIDIInputPortCreate(client, "MeridianStudioInput" as CFString, Self.readProc, context, &newPort)
        guard portStatus == noErr else { throw MIDIEngineError.portCreationFailed(portStatus) }
        inputPort = newPort

        let sourceCount = MIDIGetNumberOfSources()
        for index in 0..<sourceCount {
            MIDIPortConnectSource(inputPort, MIDIGetSource(index), nil)
        }
    }

    public func stop() {
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if client != 0 { MIDIClientDispose(client) }
        inputPort = 0
        client = 0
    }

    private static let readProc: MIDIReadProc = { packetListPointer, readProcRefCon, _ in
        guard let readProcRefCon else { return }
        let input = Unmanaged<CoreMIDIInput>.fromOpaque(readProcRefCon).takeUnretainedValue()

        var packet = packetListPointer.pointee.packet
        for _ in 0..<packetListPointer.pointee.numPackets {
            let hostTime = mach_absolute_time()
            let length = Int(packet.length)
            withUnsafeBytes(of: packet.data) { rawBuffer in
                var offset = 0
                while offset + 2 < length {
                    let status = rawBuffer[offset]
                    guard status & 0x80 != 0 else { offset += 1; continue }
                    let data1 = rawBuffer[offset + 1]
                    let data2 = rawBuffer[offset + 2]
                    input.queue.push(RawMIDIMessage(status: status, data1: data1, data2: data2, timestamp: hostTime))
                    offset += 3
                }
            }
            packet = MIDIPacketNext(&packet)
        }
    }
}
```

- [ ] **Step 2: Verify the target builds**

Run: `swift build --target MIDIEngine`
Expected: builds with no errors (CoreMIDI is a system framework, linked automatically).

- [ ] **Step 3: Commit**

```bash
git add Sources/MIDIEngine/CoreMIDIInput.swift
git commit -m "Add CoreMIDI hardware input adapter"
```

---

## Task 11: PlaybackEngine (AVAudioEngine Wrapper)

**Files:**
- Create: `Sources/MIDIEngine/PlaybackEngine.swift`

**Interfaces:**
- Consumes: `MIDIRegion` (via `ProjectModel`), `PlaybackScheduler` (Task 9).
- Produces: `@MainActor final class PlaybackEngine` with `init()`, `func start() throws`, `func stop()`, `func play(region: MIDIRegion, tempo: Double)`. Used by `AppState` (Task 13).

Like Task 10, this has no automated tests (it needs a real audio device) — verified by a successful build plus the manual smoke test in Task 13.

- [ ] **Step 1: Write the implementation**

```swift
// Sources/MIDIEngine/PlaybackEngine.swift
import AVFoundation
import ProjectModel

@MainActor
public final class PlaybackEngine {
    private let engine = AVAudioEngine()
    private let sampler = AVAudioUnitSampler()

    public init() {
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)
    }

    public func start() throws {
        try engine.start()
    }

    public func stop() {
        engine.stop()
    }

    /// Wall-clock scheduling via `Task.sleep`, not sample-accurate `AVAudioTime`
    /// scheduling — acceptable for Phase 1's "audible and roughly in sync" bar.
    /// See docs/midi.md for the sample-accurate-scheduling follow-up note.
    public func play(region: MIDIRegion, tempo: Double) {
        for scheduled in PlaybackScheduler.schedule(region: region, tempo: tempo) {
            Task { @MainActor [sampler] in
                try? await Task.sleep(nanoseconds: UInt64(max(scheduled.startSeconds, 0) * 1_000_000_000))
                sampler.startNote(scheduled.pitch, withVelocity: scheduled.velocity, onChannel: 0)
                try? await Task.sleep(nanoseconds: UInt64(max(scheduled.lengthSeconds, 0) * 1_000_000_000))
                sampler.stopNote(scheduled.pitch, onChannel: 0)
            }
        }
    }
}
```

- [ ] **Step 2: Verify the target builds**

Run: `swift build --target MIDIEngine`
Expected: builds with no errors (AVFoundation is a system framework, linked automatically).

- [ ] **Step 3: Commit**

```bash
git add Sources/MIDIEngine/PlaybackEngine.swift
git commit -m "Add AVAudioEngine-based MIDI playback"
```

---

## Task 12: Record → Persist → Reopen Integration Test

**Files:**
- Test: `Tests/MIDIEngineTests/RecordAndPersistIntegrationTests.swift`

**Interfaces:**
- Consumes: `MIDIRecorder`, `NoteRecorderClock` (Task 8), `ProjectDocument` (Task 5), `ProjectStore` (Task 4).
- Produces: nothing new — this is a pure test task mirroring the spec's EVAL 001/EVAL 005 at Phase 1 scale.

- [ ] **Step 1: Write the test**

```swift
// Tests/MIDIEngineTests/RecordAndPersistIntegrationTests.swift
import XCTest
import ProjectModel
@testable import MIDIEngine

@MainActor
final class RecordAndPersistIntegrationTests: XCTestCase {
    func testRecordSaveReopenRoundTrip() throws {
        var time = 0.0
        let recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { time }))

        recorder.handle(.noteOn(pitch: 60, velocity: 100, timestamp: 0))
        time = 1.0
        recorder.handle(.noteOff(pitch: 60, timestamp: 0))

        recorder.handle(.noteOn(pitch: 64, velocity: 90, timestamp: 0))
        time = 2.0
        recorder.handle(.noteOff(pitch: 64, timestamp: 0))

        let region = MIDIRegion(startBeat: 0, lengthBeats: 2, notes: recorder.recordedNotes)
        let document = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        document.addRegion(region, toTrackAt: 0)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("RoundTrip.mstudio")
        defer { try? FileManager.default.removeItem(at: url) }

        try ProjectStore.save(document.project, to: url)
        let reopened = try ProjectStore.load(from: url)

        XCTAssertEqual(reopened, document.project)
        XCTAssertEqual(reopened.tracks[0].regions[0].notes.count, 2)
        XCTAssertEqual(reopened.tracks[0].regions[0].notes[0], NoteEvent(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1))
        XCTAssertEqual(reopened.tracks[0].regions[0].notes[1], NoteEvent(pitch: 64, velocity: 90, startBeat: 0, lengthBeats: 2))
    }
}
```

- [ ] **Step 2: Run test to verify it passes**

Run: `swift test --filter RecordAndPersistIntegrationTests`
Expected: PASS (1 test). If it fails, check whether the failure is in recording (Task 8), persistence (Task 4/5), or the test's own expected values before changing implementation code.

- [ ] **Step 3: Run the full test suite**

Run: `swift test`
Expected: all tests across `ProjectModelTests` and `MIDIEngineTests` pass.

- [ ] **Step 4: Commit**

```bash
git add Tests/MIDIEngineTests/RecordAndPersistIntegrationTests.swift
git commit -m "Add record-save-reopen integration test"
```

---

## Task 13: App Shell — Transport, Track List, Timeline, Piano Roll

**Files:**
- Create: `Sources/MeridianStudioApp/RecordingClock.swift`
- Create: `Sources/MeridianStudioApp/AppState.swift`
- Create: `Sources/MeridianStudioApp/ContentView.swift`
- Create: `Sources/MeridianStudioApp/TransportView.swift`
- Create: `Sources/MeridianStudioApp/TrackListView.swift`
- Create: `Sources/MeridianStudioApp/TimelineView.swift`
- Create: `Sources/MeridianStudioApp/PianoRollView.swift`
- Create: `Sources/MeridianStudioApp/MeridianStudioApp.swift`
- Delete: `Sources/MeridianStudioApp/.gitkeep`

**Interfaces:**
- Consumes: `ProjectDocument`, `Project`, `Track`, `MIDIRegion`, `NoteEvent`, `Tempo` (`ProjectModel`); `CoreMIDIInput`, `MIDIEventQueue`, `MIDIMessageParser`, `MIDIRecorder`, `NoteRecorderClock`, `PlaybackEngine` (`MIDIEngine`).
- Produces: `final class RecordingClock` with `var startDate: Date?`, `var tempo: Double`, `func beatsElapsed() -> Double`; `@MainActor final class AppState: ObservableObject` with `@Published var document: ProjectDocument`, `@Published var isPlaying: Bool`, `@Published var isRecording: Bool`, `@Published var fileURL: URL?`, `func toggleRecording()`, `func play()`, `func stopPlayback()`. Task 14 extends `AppState` with file-menu actions.

This is a UI-assembly task with no automated tests — there is no UI testing harness in Phase 1 (see Global Constraints / spec Section 11). It's verified by a successful build and the manual smoke test below. **Note on tooling:** this session cannot see or interact with a native macOS GUI window, so the manual smoke test must be run by you; the plan states exactly what to check.

- [ ] **Step 1: Write `RecordingClock`**

```swift
// Sources/MeridianStudioApp/RecordingClock.swift
import Foundation
import ProjectModel

final class RecordingClock {
    var startDate: Date?
    var tempo: Double = 120

    func beatsElapsed() -> Double {
        guard let startDate else { return 0 }
        return Tempo.beats(forSeconds: Date().timeIntervalSince(startDate), tempo: tempo)
    }
}
```

- [ ] **Step 2: Write `AppState`**

```swift
// Sources/MeridianStudioApp/AppState.swift
import Combine
import Foundation
import ProjectModel
import MIDIEngine

@MainActor
final class AppState: ObservableObject {
    @Published var document: ProjectDocument {
        didSet { bindDocument() }
    }
    @Published var isPlaying = false
    @Published var isRecording = false
    @Published var fileURL: URL?

    let midiInput = CoreMIDIInput()
    let playbackEngine = PlaybackEngine()
    private let recorder: MIDIRecorder
    private let recordingClock = RecordingClock()
    private var pollTimer: Timer?
    private var documentCancellable: AnyCancellable?

    init() {
        let doc = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        self.document = doc
        self.recorder = MIDIRecorder(clock: NoteRecorderClock(nowBeats: { [recordingClock] in
            recordingClock.beatsElapsed()
        }))
        bindDocument()

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
    }

    private func bindDocument() {
        recordingClock.tempo = document.project.tempo
        documentCancellable = document.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recordingClock.tempo = document.project.tempo
        recorder.reset()
        recordingClock.startDate = Date()
        isRecording = true
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainMIDIQueue() }
        }
    }

    private func stopRecording() {
        isRecording = false
        pollTimer?.invalidate()
        pollTimer = nil
        recordingClock.startDate = nil
        drainMIDIQueue()

        guard !recorder.recordedNotes.isEmpty else { return }
        let regionLength = ceil(recorder.recordedNotes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0)
        let region = MIDIRegion(startBeat: 0, lengthBeats: max(regionLength, 1), notes: recorder.recordedNotes)
        document.addRegion(region, toTrackAt: 0)
    }

    private func drainMIDIQueue() {
        for message in midiInput.queue.drain() {
            recorder.handle(MIDIMessageParser.parse(message))
        }
    }

    func play() {
        guard let region = document.project.tracks.first?.regions.last else { return }
        isPlaying = true
        playbackEngine.play(region: region, tempo: document.project.tempo)
    }

    func stopPlayback() {
        isPlaying = false
    }
}
```

- [ ] **Step 3: Write `TransportView`**

```swift
// Sources/MeridianStudioApp/TransportView.swift
import SwiftUI

struct TransportView: View {
    @EnvironmentObject var appState: AppState

    private var tempoBinding: Binding<Double> {
        Binding(
            get: { appState.document.project.tempo },
            set: { appState.document.setTempo($0) }
        )
    }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: { appState.play() }) {
                Image(systemName: "play.fill")
            }
            Button(action: { appState.stopPlayback() }) {
                Image(systemName: "stop.fill")
            }
            Button(action: { appState.toggleRecording() }) {
                Image(systemName: appState.isRecording ? "record.circle.fill" : "record.circle")
                    .foregroundColor(appState.isRecording ? .red : .primary)
            }
            Divider().frame(height: 20)
            HStack {
                Text("Tempo")
                TextField("Tempo", value: tempoBinding, format: .number)
                    .frame(width: 60)
            }
            Spacer()
        }
        .padding(8)
    }
}
```

- [ ] **Step 4: Write `TrackListView`**

```swift
// Sources/MeridianStudioApp/TrackListView.swift
import SwiftUI

struct TrackListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(appState.document.project.tracks) { track in
            HStack {
                Text(track.name)
                Spacer()
                Text("\(track.regions.count) region(s)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}
```

- [ ] **Step 5: Write `TimelineView`**

```swift
// Sources/MeridianStudioApp/TimelineView.swift
import SwiftUI

// Single-track layout for Phase 1; per-track lanes arrive with multi-track support in Phase 2.
struct TimelineView: View {
    @EnvironmentObject var appState: AppState
    private let pixelsPerBeat: CGFloat = 40

    var body: some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                ForEach(appState.document.project.tracks.flatMap(\.regions)) { region in
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: CGFloat(region.lengthBeats) * pixelsPerBeat, height: 60)
                        .offset(x: CGFloat(region.startBeat) * pixelsPerBeat)
                        .overlay(alignment: .topLeading) {
                            Text("Region").font(.caption2).padding(2)
                        }
                }
            }
            .frame(minWidth: 800, minHeight: 60, alignment: .topLeading)
        }
        .frame(height: 80)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}
```

- [ ] **Step 6: Write `PianoRollView`**

```swift
// Sources/MeridianStudioApp/PianoRollView.swift
import SwiftUI
import ProjectModel

struct PianoRollView: View {
    @EnvironmentObject var appState: AppState
    private let pixelsPerBeat: CGFloat = 40
    private let pixelsPerSemitone: CGFloat = 6
    private let lowestPitch: UInt8 = 36
    private let highestPitch: UInt8 = 96

    private var notes: [NoteEvent] {
        appState.document.project.tracks.first?.regions.last?.notes ?? []
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Rectangle()
                        .fill(Color.green.opacity(0.8))
                        .frame(width: max(CGFloat(note.lengthBeats) * pixelsPerBeat, 4), height: pixelsPerSemitone)
                        .offset(
                            x: CGFloat(note.startBeat) * pixelsPerBeat,
                            y: CGFloat(Int(highestPitch) - Int(note.pitch)) * pixelsPerSemitone
                        )
                }
            }
            .frame(
                width: 800,
                height: CGFloat(highestPitch - lowestPitch) * pixelsPerSemitone,
                alignment: .topLeading
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}
```

- [ ] **Step 7: Write `ContentView`**

```swift
// Sources/MeridianStudioApp/ContentView.swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 0) {
            TransportView()
            HSplitView {
                TrackListView()
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
                VStack(spacing: 0) {
                    TimelineView()
                    PianoRollView()
                }
            }
        }
    }
}
```

- [ ] **Step 8: Write the app entry point**

```swift
// Sources/MeridianStudioApp/MeridianStudioApp.swift
import AppKit
import SwiftUI

@main
struct MeridianStudioApp: App {
    @StateObject private var appState = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
    }
}
```

- [ ] **Step 9: Remove placeholder file**

```bash
rm Sources/MeridianStudioApp/.gitkeep
```

- [ ] **Step 10: Build**

Run: `swift build`
Expected: builds with no errors. Fix any compiler errors before proceeding — Swift 6's strict concurrency checker may flag something this plan didn't anticipate; resolve it the normal way (adjust actor isolation or `Sendable` conformance) rather than disabling checks.

- [ ] **Step 11: Manual smoke test**

Run: `swift run MeridianStudioApp`

Check:
- A window opens titled "MeridianStudioApp" with a transport bar, a "Piano" track in the left list, an empty timeline, and an empty piano roll.
- Clicking the tempo field and typing a new number updates it (no crash).
- If a MIDI keyboard is connected: click the record button, play a few notes, click record again to stop — a colored region appears in the timeline and note rectangles appear in the piano roll.
- Click play — if the region has notes, you should hear them (built-in sampler sound) roughly in time.
- Quit and relaunch — the app starts with a fresh empty project (persistence is wired up in Task 14, not yet here).

Note any deviation from the above before moving on — this task's "test" is you, the user, actually running it, since this session cannot see or interact with a GUI window.

- [ ] **Step 12: Commit**

```bash
git add Sources/MeridianStudioApp
git commit -m "Add SwiftUI app shell: transport, track list, timeline, piano roll"
```

---

## Task 14: File Menu — New / Open / Save / Save As

**Files:**
- Create: `Sources/MeridianStudioApp/ProjectDocumentIO.swift`
- Modify: `Sources/MeridianStudioApp/MeridianStudioApp.swift` (add `.commands`)

**Interfaces:**
- Consumes: `ProjectStore` (Task 4), `AppState` (Task 13).
- Produces: `extension AppState` with `func newProject()`, `func openProject()`, `func saveProject()`, `func saveProjectAs()`.

No automated tests — the underlying save/load correctness is already covered by `ProjectStoreTests` (Task 4) and the integration test (Task 12); this task only wires that logic to menu commands and file panels, verified by manual smoke test.

- [ ] **Step 1: Write `ProjectDocumentIO`**

```swift
// Sources/MeridianStudioApp/ProjectDocumentIO.swift
import AppKit
import ProjectModel

extension AppState {
    func newProject() {
        document = ProjectDocument(project: Project(tracks: [Track(name: "Piano")]))
        fileURL = nil
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let project = try ProjectStore.load(from: url)
            document = ProjectDocument(project: project)
            fileURL = url
        } catch {
            presentError(error)
        }
    }

    func saveProject() {
        if let fileURL {
            persist(to: fileURL)
        } else {
            saveProjectAs()
        }
    }

    func saveProjectAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Untitled.mstudio"
        panel.prompt = "Save"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        persist(to: url)
        fileURL = url
    }

    private func persist(to url: URL) {
        do {
            try ProjectStore.save(document.project, to: url)
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        NSAlert(error: error).runModal()
    }
}
```

- [ ] **Step 2: Wire menu commands**

Modify `Sources/MeridianStudioApp/MeridianStudioApp.swift` — replace the `body` property with:

```swift
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { appState.newProject() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Open…") { appState.openProject() }
                    .keyboardShortcut("o", modifiers: .command)
                Divider()
                Button("Save") { appState.saveProject() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Save As…") { appState.saveProjectAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 4: Manual smoke test**

Run: `swift run MeridianStudioApp`

Check:
- Cmd+S (or Save As from the File menu) opens a save panel; choosing a location creates `<name>.mstudio/project.json` on disk (verify with `ls` in another terminal).
- Quit, relaunch, Cmd+O, select the folder you just saved — the track/region/notes you had reappear exactly as before.
- Cmd+N resets to a fresh empty "Piano" track project.

- [ ] **Step 5: Commit**

```bash
git add Sources/MeridianStudioApp/ProjectDocumentIO.swift Sources/MeridianStudioApp/MeridianStudioApp.swift
git commit -m "Wire New/Open/Save/Save As to ProjectStore"
```

---

## Task 15: Documentation & CI

**Files:**
- Create: `docs/architecture.md`
- Create: `docs/project-format.md`
- Create: `docs/midi.md`
- Create: `docs/testing.md`
- Create: `docs/evals.md`
- Create: `evals/README.md`
- Create: `evals/eval_project_io/README.md`
- Create: `evals/eval_midi/README.md`
- Create: `.github/workflows/ci.yml`

**Interfaces:** None — documentation and CI configuration only, reflecting what Tasks 1–14 actually built.

- [ ] **Step 1: Write `docs/architecture.md`**

```markdown
# Architecture

Meridian Studio is a macOS-native DAW built in layers, mirroring the
separation described in the Phase 0 design spec
(`docs/superpowers/specs/2026-09-16-meridian-studio-design.md`):

- **UI** (`Sources/MeridianStudioApp`) — SwiftUI views: transport,
  track list, timeline, piano roll. Depends on `ProjectModel` and
  `MIDIEngine`, never the other way around.
- **Project Model** (`Sources/ProjectModel`) — `Project`, `Track`,
  `MIDIRegion`, `NoteEvent` value types (Codable, UI-independent),
  `ProjectStore` (versioned JSON persistence), and `ProjectDocument`
  (an `UndoManager`-backed observable wrapper). No SwiftUI import.
- **MIDI Engine** (`Sources/MIDIEngine`) — `CoreMIDIInput` (hardware
  adapter), `MIDIEventQueue` (thread-safe handoff off the CoreMIDI
  callback thread), `MIDIMessageParser`/`MIDIRecorder` (pure,
  unit-tested note-pairing logic), and `PlaybackEngine`/
  `PlaybackScheduler` (AVAudioEngine-based playback).

Real-time safety: the CoreMIDI read callback only parses bytes and
pushes onto `MIDIEventQueue` (allocation-free after construction,
guarded by `OSAllocatedUnfairLock`, drops events rather than blocking
when full). All project-model mutation happens on the main actor, off
that callback thread.

There is no audio-recording engine, mixer, or AI layer yet — see the
roadmap in the Phase 0 spec.
```

- [ ] **Step 2: Write `docs/project-format.md`**

```markdown
# Project File Format

A Meridian Studio project is a directory bundle with a `.mstudio`
extension, e.g. `MySong.mstudio/`:

    MySong.mstudio/
      project.json   # schemaVersion, sampleRate, tempo, timeSignature, tracks[]
      midi/          # reserved for future per-region MIDI files (unused in
                      # Phase 1 — note events are embedded directly in project.json)

`project.json` always has a top-level `schemaVersion` integer.
`ProjectStore.load(from:)` rejects any version other than
`Project.currentSchemaVersion` (currently `1`) with
`ProjectStoreError.unsupportedSchemaVersion`, so a real migration
function has somewhere to hook in once a second schema version exists.

Known Phase 1 limitation: the `.mstudio` extension is not registered
as a macOS document type (no Info.plist/UTType), so Finder shows it as
a plain folder rather than a package icon. Deferred until proper
app-bundle packaging lands in a later phase.
```

- [ ] **Step 3: Write `docs/midi.md`**

```markdown
# MIDI Engine

## Input
`CoreMIDIInput` opens a `MIDIClient`/`MIDIInputPort` (classic MIDI 1.0
API) and connects to every currently available source. Its read
callback runs on a CoreMIDI-managed thread and does the minimum
possible work: extract 3-byte channel messages from each packet and
push a `RawMIDIMessage` onto `MIDIEventQueue`. It does not parse
running status or SysEx — a documented Phase 1 limitation.

## Recording
`MIDIMessageParser.parse(_:)` turns a `RawMIDIMessage` into a
`ParsedMIDIEvent` (`.noteOn`, `.noteOff`, `.other`). `MIDIRecorder`
pairs `.noteOn`/`.noteOff` events per pitch into `NoteEvent`s using an
injectable clock (`NoteRecorderClock`), which is what makes it
testable without real time or hardware.

## Playback
`PlaybackScheduler.schedule(region:tempo:)` is pure beat-to-second math
(no I/O). `PlaybackEngine` uses it to schedule `AVAudioUnitSampler`
note on/off calls. This is wall-clock scheduling via `Task.sleep`, not
sample-accurate `AVAudioTime` scheduling — acceptable for Phase 1's
"audible and roughly in sync" bar; sample-accurate scheduling is a
candidate refinement once the mixer/automation phases need tighter
timing.
```

- [ ] **Step 4: Write `docs/testing.md`**

```markdown
# Testing

- `Tests/ProjectModelTests` — Codable round-trips, `Tempo` beat/second
  math, `ProjectStore` save/load and schema-version rejection,
  `ProjectDocument` undo/redo.
- `Tests/MIDIEngineTests` — `MIDIEventQueue` ordering/overflow,
  `MIDIMessageParser` byte parsing, `MIDIRecorder` note pairing,
  `PlaybackScheduler` beat-to-second math, and an integration test
  (`RecordAndPersistIntegrationTests`) that drives synthetic MIDI
  events through recording, saving, and reopening a project and
  asserts the result is identical.
- `CoreMIDIInput` and `PlaybackEngine` are hardware-touching adapters
  with no automated tests (they need a real CoreMIDI daemon/audio
  device); they're covered by build success plus the manual smoke
  tests in the Phase 1 implementation plan.
- Run everything: `swift test`. CI (`.github/workflows/ci.yml`) runs
  the same command on every push/PR.
```

- [ ] **Step 5: Write `docs/evals.md`**

```markdown
# Evals

Phase 1 evals live under `/evals`, one directory per capability, each
with a README stating input, expected result, and pass/fail criteria
— see `evals/eval_project_io/README.md` and `evals/eval_midi/README.md`.
They're currently satisfied by the automated test suite
(`RecordAndPersistIntegrationTests` for project I/O; the `MIDIEngine`
unit tests for MIDI). As later phases add audio, mixer, and AI
features, they get their own eval directories per the Phase 0 spec's
eval architecture (Section 11).
```

- [ ] **Step 6: Write `evals/README.md`**

```markdown
# Evals

Structured, pass/fail evaluations for Meridian Studio features, per
the format in the Phase 0 design spec
(`docs/superpowers/specs/2026-09-16-meridian-studio-design.md`,
Section 11): each subdirectory states its input, expected result, and
tolerance. Phase 1 has `eval_project_io` and `eval_midi`; more arrive
as later phases add audio, mixer, and AI capabilities.
```

- [ ] **Step 7: Write `evals/eval_project_io/README.md`**

```markdown
# Eval: Project I/O

**Input:** A project with one MIDI track containing a region of two
notes (created via `MIDIRecorder` from synthetic MIDI events).

**Action:** Save the project to a `.mstudio` bundle, then reopen it.

**Expected result:** The reopened `Project` is equal to the original
(same tempo, time signature, tracks, regions, and note data).

**Pass/fail criteria:** Exact equality (`Project: Equatable`) — no
tolerance, since this is lossless JSON round-tripping, not lossy audio.

**Automated by:** `Tests/MIDIEngineTests/RecordAndPersistIntegrationTests.swift`.
```

- [ ] **Step 8: Write `evals/eval_midi/README.md`**

```markdown
# Eval: MIDI Recording

**Input:** A MIDI note-on for pitch 60 (middle C) at velocity 100,
followed one beat later by a matching note-off.

**Expected result:** `MIDIRecorder` produces exactly one `NoteEvent`
with `pitch: 60`, `velocity: 100`, `startBeat: 0`, `lengthBeats: 1`.

**Pass/fail criteria:** Exact match on pitch and velocity; timing
tolerance is whatever the injected clock reports (deterministic in
tests). No duplicate notes, no dropped notes.

**Automated by:** `Tests/MIDIEngineTests/MIDIRecorderTests.swift`.
```

- [ ] **Step 9: Write `.github/workflows/ci.yml`**

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  build-and-test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - name: Swift version
        run: swift --version
      - name: Build
        run: swift build
      - name: Test
        run: swift test
```

- [ ] **Step 10: Commit**

```bash
git add docs evals .github
git commit -m "Add Phase 1 documentation and CI workflow"
```

- [ ] **Step 11: Push**

```bash
git push origin main
```

Expected: CI runs on GitHub Actions and passes (`swift build` + `swift test` green).
