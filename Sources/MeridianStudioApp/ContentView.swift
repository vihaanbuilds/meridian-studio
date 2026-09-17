// Sources/MeridianStudioApp/ContentView.swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 0) {
            TransportView()
            HSplitView {
                TrackListView()
                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 260)
                VStack(spacing: 0) {
                    TimelineView()
                    PianoRollView()
                }
            }
        }
    }
}
