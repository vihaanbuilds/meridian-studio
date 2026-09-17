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
