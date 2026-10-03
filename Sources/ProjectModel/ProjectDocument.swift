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

    /// Splits the region with `id` into two at `splitBeat`. A no-op if
    /// `splitBeat` doesn't fall strictly inside the region (e.g. a
    /// double-click landed exactly on or past an edge) — never produces a
    /// degenerate zero-length half. Both halves reference the same
    /// `fileName`; no audio file is read, copied, or written. Registered as
    /// a single undo step via `mergeAudioRegions`'s mutual re-registration
    /// (the same idiom `addAudioRegion`/`removeAudioRegion` already use for
    /// their own undo/redo symmetry) — not composed from three chained
    /// `removeAudioRegion`/`addAudioRegion` calls, which would register
    /// three separate undo steps instead of one.
    public func splitAudioRegion(id: UUID, atBeat splitBeat: Double, tempo: Double, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == id }) else { return }
        let original = project.tracks[trackIndex].audioRegions[index]
        guard splitBeat > original.startBeat, splitBeat < original.startBeat + original.lengthBeats else { return }

        let firstLengthBeats = splitBeat - original.startBeat
        let elapsedSeconds = Tempo.seconds(forBeats: firstLengthBeats, tempo: tempo)
        let first = AudioRegion(
            startBeat: original.startBeat, lengthBeats: firstLengthBeats,
            fileName: original.fileName, sourceOffsetSeconds: original.sourceOffsetSeconds
        )
        let second = AudioRegion(
            startBeat: splitBeat, lengthBeats: original.lengthBeats - firstLengthBeats,
            fileName: original.fileName, sourceOffsetSeconds: original.sourceOffsetSeconds + elapsedSeconds
        )

        project.tracks[trackIndex].audioRegions.remove(at: index)
        project.tracks[trackIndex].audioRegions.append(first)
        project.tracks[trackIndex].audioRegions.append(second)

        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.mergeAudioRegions(first.id, second.id, into: original, splitBeat: splitBeat, tempo: tempo, inTrackAt: trackIndex)
            }
        }
    }

    /// The inverse of `splitAudioRegion` — removes both halves, restores
    /// `original`, and registers undo for *this* operation as a call back
    /// into `splitAudioRegion` at the same point, so redo re-splits.
    private func mergeAudioRegions(_ firstID: UUID, _ secondID: UUID, into original: AudioRegion, splitBeat: Double, tempo: Double, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        project.tracks[trackIndex].audioRegions.removeAll { $0.id == firstID || $0.id == secondID }
        project.tracks[trackIndex].audioRegions.append(original)

        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.splitAudioRegion(id: original.id, atBeat: splitBeat, tempo: tempo, inTrackAt: trackIndex)
            }
        }
    }

    /// Live setter for the drag in progress — no undo registration, same
    /// reasoning as `updateNote`. Called on every `onChanged` frame.
    public func updateAudioRegion(_ region: AudioRegion, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == region.id }) else { return }
        project.tracks[trackIndex].audioRegions[index] = region
    }

    /// Called once, at drag-end, with the region's value captured when the
    /// drag started. Registers one undo step for the whole gesture, mirroring
    /// `commitNoteEdit`.
    public func commitAudioRegionEdit(from original: AudioRegion, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let index = project.tracks[trackIndex].audioRegions.firstIndex(where: { $0.id == original.id }) else { return }
        let current = project.tracks[trackIndex].audioRegions[index]
        guard current != original else { return }
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.updateAudioRegion(original, inTrackAt: trackIndex)
                doc.commitAudioRegionEdit(from: current, inTrackAt: trackIndex)
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

    /// Called once, at drag-end, with the note's value captured when the
    /// drag started. Registers one undo step for the whole gesture —
    /// restoring `original` via the same mutual-re-registration idiom
    /// `addRegion`/`removeRegion` already use, so redo works symmetrically.
    /// `updateNote` itself stays undo-free on purpose: it's called on every
    /// `onChanged` frame during a drag, and registering undo there would
    /// turn one drag gesture into dozens of undo steps.
    public func commitNoteEdit(from original: NoteEvent, inTrackAt trackIndex: Int) {
        guard project.tracks.indices.contains(trackIndex) else { return }
        guard let regionIndex = project.tracks[trackIndex].regions.indices.last else { return }
        guard let noteIndex = project.tracks[trackIndex].regions[regionIndex].notes.firstIndex(where: { $0.id == original.id }) else { return }
        let current = project.tracks[trackIndex].regions[regionIndex].notes[noteIndex]
        guard current != original else { return }
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.updateNote(original, inTrackAt: trackIndex)
                doc.commitNoteEdit(from: current, inTrackAt: trackIndex)
            }
        }
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
