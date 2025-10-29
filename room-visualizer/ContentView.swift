//
//  ContentView.swift
//  room-visualizer
//
//  Created by Eliot Pontarelli on 9/12/25.
//

import SwiftUI
import RealityKit

struct ContentView: View {
    @Environment(AppModel.self) var appModel

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ToggleImmersiveSpaceButton()

                // Model selection section
                VStack(spacing: 12) {
                    Text("Select Style Model")
                        .font(.headline)

                    HStack(spacing: 12) {
                        Button(action: {
                            appModel.selectedModel = "starry_night"
                        }) {
                            VStack(spacing: 8) {
                                Image(systemName: "sparkles")
                                    .font(.largeTitle)
                                Text("Starry Night")
                                    .font(.caption)
                            }
                            .frame(width: 140, height: 100)
                        }
                        .buttonStyle(.bordered)
                        .tint(appModel.selectedModel == "starry_night" ? .blue : .gray)

                        Button(action: {
                            appModel.selectedModel = "rain_princess"
                        }) {
                            VStack(spacing: 8) {
                                Image(systemName: "cloud.rain.fill")
                                    .font(.largeTitle)
                                Text("Rain Princess")
                                    .font(.caption)
                            }
                            .frame(width: 140, height: 100)
                        }
                        .buttonStyle(.bordered)
                        .tint(appModel.selectedModel == "rain_princess" ? .blue : .gray)
                    }

                    if appModel.isLoadingModel {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading model...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(.thinMaterial)
                .cornerRadius(12)

                NavigationLink("Style Transfer MVP", destination: DemoStyleBenchmarkView())
                    .buttonStyle(.borderedProminent)

                Button("Test Model Load") {
                    TestModelLoad.testLoad()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .navigationTitle("Room Visualizer")
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
