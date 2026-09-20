public enum Quantizer {
    /// `gridBeats` is the grid spacing in beats (1.0 = quarter-note grid, 0.5 =
    /// eighth, 0.25 = sixteenth, matching this app's existing beats-as-the-
    /// fundamental-unit convention). `strength` is 0...1 (0 = no change, 1 = hard
    /// snap to the nearest grid line), clamped. Only `startBeat` changes.
    ///
    /// A non-finite `strength` is treated as 0 (leave the notes alone) rather
    /// than clamped: Swift's global `min`/`max` do NOT clamp NaN (all NaN
    /// comparisons are false, so `max(.nan, 0) == .nan`), and a NaN strength
    /// would produce a NaN `startBeat` that flows into
    /// `PlaybackEngine.play`'s `UInt64(seconds * 1e9)` conversion and traps.
    /// This is the same hazard `ProjectDocument.setTempo` guards against.
    /// `.infinity` *is* safe under `min`/`max`, but it is garbage input just
    /// the same, so it takes the conservative no-change path too.
    ///
    /// `maxStartBeat`, when given, holds a note that STARTED inside the bound
    /// from being quantized past it: its new `startBeat` is capped at or below
    /// `maxStartBeat - lengthBeats` (never below 0). It is optional and
    /// defaults to `nil` — how far a note may travel is a property of whatever
    /// canvas is displaying it, so the caller supplies the bound and this
    /// module stays UI-agnostic.
    ///
    /// A note that already starts beyond `maxStartBeat` is left untouched by
    /// the bound (still quantized normally otherwise). A take longer than the
    /// canvas has notes well past it — the app's recorder has no upper bound
    /// on `startBeat`, and any take over ~10s at the default 120 BPM exceeds a
    /// typical 20-beat canvas — and clamping those unconditionally would stack
    /// the whole tail of the take onto a single beat, irreversibly, since
    /// `quantizeNotes` registers no undo. The bound exists to stop a quantize
    /// step pushing a *reachable* note out of reach, not to drag
    /// already-unreachable notes onto the edge.
    public static func quantize(_ notes: [NoteEvent], gridBeats: Double, strength: Double, maxStartBeat: Double? = nil) -> [NoteEvent] {
        guard gridBeats > 0 else { return notes }
        let clampedStrength = strength.isFinite ? min(max(strength, 0), 1) : 0
        return notes.map { note in
            var quantized = note
            let nearestGrid = (note.startBeat / gridBeats).rounded() * gridBeats
            var newStartBeat = note.startBeat + (nearestGrid - note.startBeat) * clampedStrength
            if let maxStartBeat, note.startBeat < maxStartBeat {
                newStartBeat = min(newStartBeat, max(maxStartBeat - note.lengthBeats, 0))
            }
            quantized.startBeat = newStartBeat
            return quantized
        }
    }
}
