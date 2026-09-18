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
