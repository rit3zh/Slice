//
//  FrameRenderer+Keycaps.swift
//  SliceCore
//
//  Created by rit3zh CX on 11/12/26.
//

import AppKit
import CoreImage
import CoreText

/// How a shortcut, key or typed line is drawn, in each of the keystroke styles: a dark or light plate, a row of
/// keycaps, or the text alone.
extension FrameRenderer {
    static func keycapMargin(_ fontSize: CGFloat) -> CGFloat { ceil(fontSize * 0.9) }

    /// Shortcuts drawn as keycaps get a key each: "⇧⌘ P" is ⇧, ⌘ and P.
    static func keycapTokens(_ label: String) -> [String] {
        let parts = label.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return [label] }
        return parts[0].map(String.init) + [parts[1]]
    }

    /// The image is drawn `keycapMargin` beyond the plate on every side, for its shadow; at the origin is the plate's
    /// bottom left. `maxWidth` cuts a long typed line short from the front.
    static func keycapImage(_ label: String, count: Int, isText: Bool = false, style: KeystrokeSettings.Style = .dark,
                            fontSize f: CGFloat, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CIImage? {
        let light = style == .light
        let ink = CGColor(gray: light ? 0.1 : 1, alpha: 1)
        let font = NSFont.systemFont(ofSize: f, weight: isText ? .medium : .semibold)
        func line(_ s: String, font: NSFont, alpha: CGFloat = 1) -> CTLine {
            CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
                .font: font, .foregroundColor: ink.copy(alpha: alpha)!, .kern: isText ? 0 : f * 0.02,
            ]))
        }
        func width(_ l: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil)) }

        let height = (f * 2).rounded()
        let pad = f * 0.66, gap = f * 0.28
        let counter = count > 1 ? line("×\(count)", font: .systemFont(ofSize: f * 0.78, weight: .medium), alpha: 0.55) : nil
        let counterWidth = counter.map { width($0) + f * 0.5 } ?? 0
        let keycaps = style == .keycaps && !isText
        var lines = (keycaps ? keycapTokens(label) : [label]).map { line($0, font: font) }

        // A typed line too long to fit loses its start.
        let room = maxWidth - counterWidth - (style == .minimal ? 0 : 2 * pad)
        if lines.count == 1, width(lines[0]) > room, room > f * 2,
           let cut = CTLineCreateTruncatedLine(lines[0], Double(room), .start, line("…", font: font)) {
            lines[0] = cut
        }

        let caps: [CGFloat] = lines.map { keycaps ? max(height, width($0) + f) : width($0) }
        let content: CGFloat = keycaps ? caps.reduce(0, +) + gap * CGFloat(caps.count - 1) : caps[0]
        let plateWidth: CGFloat = switch style {
        case .minimal, .keycaps: content + counterWidth
        case .dark, .light: max(content + counterWidth + 2 * pad, height)
        }
        let m = keycapMargin(f)
        guard let ctx = CGContext(data: nil, width: Int((plateWidth + 2 * m).rounded(.up)), height: Int(height + 2 * m),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let plate = CGRect(x: m, y: m, width: plateWidth, height: height)
        let baseline = plate.minY + (height - font.capHeight) / 2

        switch style {
        case .dark, .light:
            drawPlate(plate, light: light, fontSize: f, in: ctx)
            let start = plate.minX + (plateWidth - content - counterWidth) / 2
            draw(lines[0], at: CGPoint(x: start, y: baseline), in: ctx)
            if let counter { draw(counter, at: CGPoint(x: start + content + f * 0.5, y: baseline), in: ctx) }
        case .minimal:
            // Text alone needs a soft shadow to read over anything.
            ctx.setShadow(offset: CGSize(width: 0, height: -f * 0.06), blur: f * 0.45, color: CGColor(gray: 0, alpha: 0.75))
            draw(lines[0], at: CGPoint(x: plate.minX, y: baseline), in: ctx)
            if let counter { draw(counter, at: CGPoint(x: plate.minX + content + f * 0.5, y: baseline), in: ctx) }
        case .keycaps:
            var x = plate.minX
            for (l, w) in zip(lines, caps) {
                let cap = CGRect(x: x, y: plate.minY, width: w, height: height)
                drawKeycap(cap, fontSize: f, in: ctx)
                let lift = f * 0.08
                draw(l, at: CGPoint(x: cap.midX - width(l) / 2, y: baseline + lift), in: ctx)
                x += w + gap
            }
            if let counter {
                ctx.setShadow(offset: .zero, blur: f * 0.4, color: CGColor(gray: 0, alpha: 0.7))
                draw(counter, at: CGPoint(x: x - gap + f * 0.5, y: baseline), in: ctx)
            }
        }
        return ctx.makeImage().map { CIImage(cgImage: $0).transformed(by: CGAffineTransform(translationX: -m, y: -m)) }
    }

    private static func draw(_ line: CTLine, at p: CGPoint, in ctx: CGContext) {
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    static func drawPlate(_ plate: CGRect, light: Bool, fontSize f: CGFloat, in ctx: CGContext) {
        let radius = plate.height * 0.25
        let path = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -f * 0.12), blur: f * 0.6, color: CGColor(gray: 0, alpha: light ? 0.22 : 0.32))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: light ? 1 : 0, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setBlendMode(.copy)
        let colors = (light
            ? [CGColor(colorSpace: space, components: [0.93, 0.93, 0.95, 0.97])!, CGColor(colorSpace: space, components: [1, 1, 1, 0.97])!]
            : [CGColor(colorSpace: space, components: [0.03, 0.02, 0.045, 0.97])!,
               CGColor(colorSpace: space, components: [0.11, 0.09, 0.14, 0.92])!]) as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
        }
        ctx.restoreGState()
        let lw = max(f * 0.035, 1)
        let r = radius - lw / 2
        ctx.addPath(CGPath(roundedRect: plate.insetBy(dx: lw / 2, dy: lw / 2), cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.setStrokeColor(CGColor(gray: light ? 0 : 1, alpha: light ? 0.08 : 0.09))
        ctx.setLineWidth(lw)
        ctx.strokePath()
    }

    /// A key seen from the front: a dark skirt below a lighter top that catches the light along its upper edge.
    static func drawKeycap(_ cap: CGRect, fontSize f: CGFloat, in ctx: CGContext) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let radius = cap.height * 0.22
        let skirt = CGPath(roundedRect: cap, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -f * 0.14), blur: f * 0.5, color: CGColor(gray: 0, alpha: 0.4))
        ctx.addPath(skirt)
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.05, 0.05, 0.06, 1])!)
        ctx.fillPath()
        ctx.restoreGState()

        let top = CGRect(x: cap.minX + f * 0.07, y: cap.minY + f * 0.17, width: cap.width - f * 0.14, height: cap.height - f * 0.22)
        let r = radius * 0.85
        let face = CGPath(roundedRect: top, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.saveGState()
        ctx.addPath(face)
        ctx.clip()
        let colors = [CGColor(colorSpace: space, components: [0.27, 0.27, 0.29, 1])!,
                      CGColor(colorSpace: space, components: [0.17, 0.17, 0.19, 1])!] as CFArray
        if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: top.maxY), end: CGPoint(x: 0, y: top.minY), options: [])
        }
        ctx.restoreGState()
        let lw = max(f * 0.03, 1)
        ctx.addPath(CGPath(roundedRect: top.insetBy(dx: lw / 2, dy: lw / 2), cornerWidth: r - lw / 2, cornerHeight: r - lw / 2,
                           transform: nil))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.1))
        ctx.setLineWidth(lw)
        ctx.strokePath()
    }
}
