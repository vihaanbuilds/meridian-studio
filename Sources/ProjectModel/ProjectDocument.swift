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
            // UndoManager's handler type predates Swift concurrency and isn't itself
            // @MainActor, but registerUndo/undo/redo are only ever called from
            // MainActor-isolated code in this app, so this is genuinely safe — the
            // standard bridge for a legacy Foundation callback API like this one.
            MainActor.assumeIsolated {
                doc.removeRegion(id: region.id, fromTrackAt: trackIndex)
            }
        }
    }

    public func removeRegion(id: UUID, fromTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].regions.firstIndex(where: { $0.id == id }) else { return }
        let removed = project.tracks[trackIndex].regions.remove(at: index)
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.addRegion(removed, toTrackAt: trackIndex)
            }
        }
    }

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

    public func addTrack(_ track: Track) {
        project.tracks.append(track)
        let insertedID = track.id
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.removeTrack(id: insertedID)
            }
        }
    }

    public func removeTrack(id: UUID) {
        guard let index = project.tracks.firstIndex(where: { $0.id == id }) else { return }
        let removed = project.tracks.remove(at: index)
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.insertTrack(removed, at: index)
            }
        }
    }

    private func insertTrack(_ track: Track, at index: Int) {
        let clampedIndex = min(index, project.tracks.count)
        project.tracks.insert(track, at: clampedIndex)
        let insertedID = track.id
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.removeTrack(id: insertedID)
            }
        }
    }

    public func updateNote(_ note: NoteEvent, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        guard let noteIndex = project.tracks[trackIndex].regions[regionIndex].notes.firstIndex(where: { $0.id == note.id }) else { return }
        project.tracks[trackIndex].regions[regionIndex].notes[noteIndex] = note
    }

    public func deleteNotes(ids: Set<UUID>, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        let removedNotes = project.tracks[trackIndex].regions[regionIndex].notes.filter { ids.contains($0.id) }
        guard !removedNotes.isEmpty else { return }
        project.tracks[trackIndex].regions[regionIndex].notes.removeAll { ids.contains($0.id) }
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.restoreNotes(removedNotes, inTrackAt: trackIndex)
            }
        }
    }

    private func restoreNotes(_ notes: [NoteEvent], inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        project.tracks[trackIndex].regions[regionIndex].notes.append(contentsOf: notes)
        let ids = Set(notes.map(\.id))
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.deleteNotes(ids: ids, inTrackAt: trackIndex)
            }
        }
    }

    /// `maxStartBeat` is passed straight through to `Quantizer.quantize`: an
    /// optional upper bound on where a quantized note may end, supplied by the
    /// UI that has to keep the note reachable. `nil` (the default) means no
    /// bound.
    public func quantizeNotes(gridBeats: Double, strength: Double, maxStartBeat: Double? = nil, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        let notes = project.tracks[trackIndex].regions[regionIndex].notes
        project.tracks[trackIndex].regions[regionIndex].notes = Quantizer.quantize(notes, gridBeats: gridBeats, strength: strength, maxStartBeat: maxStartBeat)
    }

    public func setTempo(_ tempo: Double) {
        // Clamp to a small positive floor: `Tempo.seconds(forBeats:tempo:)` divides by
        // tempo, so a zero or non-finite value here produces NaN/Infinity downstream
        // (e.g. in PlaybackEngine.play's UInt64(seconds * 1e9) conversion, which traps).
        // 1 BPM is non-musical but always finite and positive. Note: Swift's global
        // `max` does NOT clamp NaN (max(.nan, 1) == .nan, since NaN comparisons are
        // always false), so NaN needs its own explicit check here.
        project.tempo = tempo.isFinite ? max(tempo, 1) : 1
    }

    public func setTrackMuted(_ muted: Bool, forTrackAt index: Int) {
        guard project.tracks.indices.contains(index) else { return }
        project.tracks[index].muted = muted
    }

    public func setTrackSolo(_ solo: Bool, forTrackAt index: Int) {
        guard project.tracks.indices.contains(index) else { return }
        project.tracks[index].solo = solo
    }

    public func replaceProject(_ newProject: Project) {
        project = newProject
        undoManager.removeAllActions()
    }
}
