//
//  CameraFilterPicker.swift
//  Slice
//
//  Created by rit3zh CX on 11/12/26.
//

import CoreImage
import SliceCore
import SwiftUI

/// The webcam's look: a row of round swatches, each a little picture through its filter.
struct CameraFilterPicker: View {
    @Binding var filter: CameraFilter

    var body: some View {
        HStack(spacing: 0) {
            ForEach(CameraFilter.allCases, id: \.self) { f in
                FilterSwatch(filter: f, selected: f == filter) { filter = f }
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct FilterSwatch: View {
    let filter: CameraFilter
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if let image = FilterSwatches.image(for: filter) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 30, height: 30)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            .padding(3)
            .overlay(Circle().strokeBorder(Theme.accent.opacity(selected ? 1 : 0), lineWidth: 2))
            .scaleEffect(hovering && !selected ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
        .animation(Theme.hover, value: selected)
        .help(filter.label)
        .accessibilityLabel(filter.label)
    }
}

/// A small made-up portrait, warm against a cool background with a little of each colour, through every filter.
@MainActor
private enum FilterSwatches {
    private static var cache: [CameraFilter: NSImage] = [:]
    private static let size = CGSize(width: 96, height: 96)

    static func image(for filter: CameraFilter) -> NSImage? {
        if let cached = cache[filter] { return cached }
        let rect = CGRect(origin: .zero, size: size)
        guard let cg = context.createCGImage(filter.apply(to: portrait.cropped(to: rect)), from: rect) else { return nil }
        let image = NSImage(cgImage: cg, size: CGSize(width: size.width / 2, height: size.height / 2))
        cache[filter] = image
        return image
    }

    private static let context = CIContext()

    private static let portrait: CIImage = {
        let w = size.width, h = size.height
        let backdrop = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: h), "inputPoint1": CIVector(x: w, y: 0),
            "inputColor0": CIColor(red: 0.16, green: 0.52, blue: 0.62), "inputColor1": CIColor(red: 0.12, green: 0.16, blue: 0.38),
        ])!.outputImage!
        func blob(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ color: CIColor) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: x, y: y), "inputRadius0": r * 0.82, "inputRadius1": r,
                "inputColor0": color, "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            ])!.outputImage!
        }
        let lamp = blob(w * 0.85, h * 0.82, h * 0.14, CIColor(red: 0.98, green: 0.78, blue: 0.3))
        let plant = blob(w * 0.1, h * 0.3, h * 0.22, CIColor(red: 0.3, green: 0.7, blue: 0.32))
        let shoulders = blob(w * 0.5, -h * 0.2, h * 0.5, CIColor(red: 0.86, green: 0.24, blue: 0.3))
        let face = blob(w * 0.5, h * 0.55, h * 0.24, CIColor(red: 0.95, green: 0.72, blue: 0.58))
        return [lamp, plant, shoulders, face].reduce(backdrop) { $1.composited(over: $0) }
    }()
}
