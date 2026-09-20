// Sources/MeridianStudioApp/QuantizeControlView.swift
import SwiftUI

struct QuantizeControlView: View {
    @EnvironmentObject var appState: AppState

    private let gridOptions: [(label: String, beats: Double)] = [
        ("1/4", 1.0),
        ("1/8", 0.5),
        ("1/16", 0.25),
        ("1/32", 0.125)
    ]

    var body: some View {
        HStack {
            Text("Quantize").font(.headline)

            Picker("Grid", selection: $appState.quantizeGridBeats) {
                ForEach(gridOptions, id: \.beats) { option in
                    Text(option.label).tag(option.beats)
                }
            }
            .frame(width: 100)

            Slider(value: $appState.quantizeStrength, in: 0...1)
                .frame(width: 120)
            Text("\(Int(appState.quantizeStrength * 100))%")
                .frame(width: 40, alignment: .leading)
                .font(.caption)
                .foregroundColor(.secondary)

            Button("Apply") {
                appState.applyQuantization()
            }

            Spacer()
        }
        .padding(8)
    }
}
