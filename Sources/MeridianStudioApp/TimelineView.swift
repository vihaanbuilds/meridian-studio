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
