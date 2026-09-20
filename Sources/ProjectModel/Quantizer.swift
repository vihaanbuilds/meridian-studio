public enum Quantizer {
    /// `gridBeats` is the grid spacing in beats (1.0 = quarter-note grid, 0.5 =
    /// eighth, 0.25 = sixteenth, matching this app's existing beats-as-the-
    /// fundamental-unit convention). `strength` is 0...1 (0 = no change, 1 = hard
    /// snap to the nearest grid line), clamped. Only `startBeat` changes.
    public static func quantize(_ notes: [NoteEvent], gridBeats: Double, strength: Double) -> [NoteEvent] {
        guard gridBeats > 0 else { return notes }
        let clampedStrength = min(max(strength, 0), 1)
        return notes.map { note in
            var quantized = note
            let nearestGrid = (note.startBeat / gridBeats).rounded() * gridBeats
            quantized.startBeat = note.startBeat + (nearestGrid - note.startBeat) * clampedStrength
            return quantized
        }
    }
}
