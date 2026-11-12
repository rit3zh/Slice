//
//  DeviceImportStatus.swift
//  Slice
//
//  Created by rit3zh CX on 10/29/26.
//

import SwiftUI

struct DeviceImportStatus: View {
    let progress: Double

    var body: some View {
        HStack(spacing: 7) {
            ProgressView(value: progress).progressViewStyle(.circular).controlSize(.mini)
            Text("Putting it in its frame… \(Int((progress * 100).rounded()))%")
                .font(.system(size: 12).monospacedDigit())
                .contentTransition(.numericText(value: progress))
        }
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(Theme.control))
        .transition(.opacity.combined(with: .offset(y: 4)))
    }
}
