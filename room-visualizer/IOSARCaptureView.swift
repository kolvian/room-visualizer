//
//  IOSARCaptureView.swift
//  room-visualizer
//
//  Created by Eliot Pontarelli on 9/12/25.
//

import SwiftUI
import RealityKit

struct IOSARCaptureView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("iOS AR Capture MVP")
                .font(.title2)
                .bold()
            Text("Coming soon")
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle("iOS AR Capture")
    }
}

#Preview(windowStyle: .automatic) {
    IOSARCaptureView()
        .environment(AppModel())
}
