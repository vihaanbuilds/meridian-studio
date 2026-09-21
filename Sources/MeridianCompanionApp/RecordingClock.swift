// Sources/MeridianCompanionApp/RecordingClock.swift
import Foundation
import ProjectModel

/// A deliberate duplicate of MeridianStudioApp's RecordingClock, not an
/// import: MeridianCompanionApp cannot depend on MeridianStudioApp (see
/// docs/superpowers/specs/2026-09-20-two-app-architecture-design.md,
/// Section 2). This one is ~8 lines built purely on ProjectModel.Tempo —
/// the same accepted-duplication cost as LevelMeterView.
final class RecordingClock {
    var startDate: Date?
    var tempo: Double = 120

    func beatsElapsed() -> Double {
        guard let startDate else { return 0 }
        return Tempo.beats(forSeconds: Date().timeIntervalSince(startDate), tempo: tempo)
    }
}
