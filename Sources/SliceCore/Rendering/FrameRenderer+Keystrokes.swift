//
//  FrameRenderer+Keystrokes.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/13/26.
//

import AppKit
import CoreImage
import CoreText

extension FrameRenderer {
    func keystrokeLayer(scene: RenderScene, time t: Double, avoiding camera: CGRect?, output: CGSize,
                        clearance: () -> CGFloat) -> CIImage? {
        let states = scene.keystrokes.states(at: t)
        guard !states.isEmpty else { return nil }
        let settings = scene.project.keystrokes
        let fontSize = (min(output.width, output.height) * settings.size).rounded()
        guard fontSize >= 4 else { return nil }
        let lift = clearance()
        var layer: CIImage?
        let maxWidth = output.width - 2 * Self.keycapInset(output)
        for state in states where state.opacity > 0.002 {
            let key = "\(state.label)|\(state.count)|\(state.isText)|\(settings.style.rawValue)|\(fontSize)|\(Int(maxWidth))" as NSString
            let cap: CIImage
            if state.isText {
                // Changes every frame while letters come in, so it's put together from kept pieces instead.
                guard let line = typedLineImage(state.label, reveal: state.reveal, style: settings.style, fontSize: fontSize,
                                                maxWidth: maxWidth) else { continue }
                cap = line
            } else if let cached = keycapCache.object(forKey: key) {
                cap = cached
            } else {
                guard let made = Self.keycapImage(state.label, count: state.count, isText: state.isText, style: settings.style,
                                                  fontSize: fontSize, maxWidth: maxWidth) else { continue }
                keycapCache.setObject(made, forKey: key)
                cap = made
            }
            let size = cap.extent.insetBy(dx: Self.keycapMargin(fontSize), dy: Self.keycapMargin(fontSize)).size
            var rect = Self.keycapRect(size: size, position: settings.position, alignment: settings.alignment, clearance: lift,
                                       camera: camera, output: output, snap: !state.isText)
            // Stacked, older presses step away from the edge as newer ones arrive.
            if state.slot > 0.0005 {
                let step = CGFloat(state.slot) * (fontSize * 2 + (fontSize * 0.4).rounded())
                rect.origin.y += settings.position == .bottom ? -step : step
            }

            var image = cap
            if state.blur > 0.002 {
                let sigma = state.blur * Double(fontSize) * 0.34
                image = image.applyingGaussianBlur(sigma: sigma).cropped(to: cap.extent.insetBy(dx: -3 * sigma, dy: -3 * sigma))
            }
            if state.opacity < 0.998 { image = scaleAlpha(image, by: state.opacity) }
            if abs(state.scale - 1) > 0.0005 {
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                image = image.transformed(by: CGAffineTransform(translationX: -c.x, y: -c.y)
                    .concatenating(CGAffineTransform(scaleX: state.scale, y: state.scale))
                    .concatenating(CGAffineTransform(translationX: c.x, y: c.y)))
            }
            var drop = state.drop * size.height
            if lift > 0, settings.position == .bottom {
                drop = min(drop, CaptionMetrics(settings: scene.project.subtitles, output: output).gap * 0.8)
            }
            image = image.transformed(by: CGAffineTransform(translationX: rect.minX, y: output.height - rect.maxY - drop))
            layer = layer.map { image.composited(over: $0) } ?? image
        }
        return layer
    }

    /// How far a keystroke pinned to the left or right stays from that edge.
    static func keycapInset(_ output: CGSize) -> CGFloat { (min(output.width, output.height) * 0.06).rounded() }

    /// `snap` keeps a press on whole pixels, crisp; a typed line, whose width changes every frame, isn't, so it glides.
    static func keycapRect(size: CGSize, position: KeystrokeSettings.Position, alignment: KeystrokeSettings.Alignment = .center,
                           clearance: CGFloat, camera: CGRect?, output: CGSize, snap: Bool = true) -> CGRect {
        let atBottom = position == .bottom
        let margin = output.height * 0.06
        let inset = keycapInset(output)
        let x: CGFloat = switch alignment {
        case .leading: inset
        case .center: snap ? ((output.width - size.width) / 2).rounded() : (output.width - size.width) / 2
        case .trailing: output.width - inset - size.width
        }
        var rect = CGRect(x: x, y: 0, width: size.width, height: size.height)
        rect.origin.y = (atBottom ? output.height - margin - size.height - clearance : margin + clearance).rounded()
        if let camera { rect = clear(rect, of: camera, atBottom: atBottom, margin: margin, output: output) }
        return rect
    }
}
