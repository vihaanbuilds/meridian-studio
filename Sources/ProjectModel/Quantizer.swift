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
    public static func quantize(_ notes: [NoteEvent], gridBeats: Double, strength: Double) -> [NoteEvent] {
        guard gridBeats > 0 else { return notes }
        let clampedStrength = strength.isFinite ? min(max(strength, 0), 1) : 0
        return notes.map { note in
            var quantized = note
            let nearestGrid = (note.startBeat / gridBeats).rounded() * gridBeats
            quantized.startBeat = note.startBeat + (nearestGrid - note.startBeat) * clampedStrength
            return quantized
        }
    }
}
