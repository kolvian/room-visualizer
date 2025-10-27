//
//  ContentView.swift
//  room-visualizer
//
//  Created by Eliot Pontarelli on 9/12/25.
//

import SwiftUI
import RealityKit

struct ContentView: View {

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ToggleImmersiveSpaceButton()
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
