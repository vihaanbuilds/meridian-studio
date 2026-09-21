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

    /// The region length (in beats) a completed MIDI take should be saved
    /// with. Using only the last note's release time (as a DAW region
    /// legitimately does — see `AppState.stopRecording()`) understates a
    /// session's real length whenever the patient leaves silence before
    /// pressing Stop, which makes the trend chart's "duration" metric mean
    /// different things for MIDI vs. audio sessions. `finalBeat` — the
    /// whole Start→Stop span — is the floor; the last note's own end is
    /// still taken in case `finalize(atBeat:)` ever reports a beat earlier
    /// than a note that's already ended (not reachable today, but this
    /// keeps the region from ever being shorter than its own notes).
    static func midiRegionLengthBeats(finalBeat: Double, notes: [NoteEvent]) -> Double {
        let lastNoteEnd = notes.map { $0.startBeat + $0.lengthBeats }.max() ?? 0
        return max(ceil(finalBeat), ceil(lastNoteEnd), 1)
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
            // Every legitimately completed session has a strictly positive
            // duration by construction (CompanionState floors both region
            // kinds above zero). A duration of exactly 0 is reachable only
            // from a bundle `startSession()` created but `stopSession()`
            // never finished — e.g. the app was quit mid-session. Filtering
            // it here (not by adding cleanup elsewhere) keeps the fix in
            // this one pure, already-tested function.
            guard durationSeconds > 0 else { return nil }
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
