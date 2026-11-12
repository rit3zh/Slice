//
//  FrameRenderer+TypedLine.swift
//  SliceCore
//
//  Created by rit3zh CX on 11/12/26.
//

import AppKit
import CoreImage
import CoreText

/// A typed line as it's being typed: the plate eases wider for each new letter, and the letter comes into focus,
/// out of a blur and up into place, rather than appearing whole.
extension FrameRenderer {
    /// Laid out like `keycapImage`: the plate's bottom left at the origin, `keycapMargin` around it.
    func typedLineImage(_ label: String, reveal: [Int: Double], style: KeystrokeSettings.Style, fontSize f: CGFloat,
                        maxWidth: CGFloat) -> CIImage? {
        let font = NSFont.systemFont(ofSize: f, weight: .medium)
        let height = (f * 2).rounded()
        let pad = style == .minimal ? 0 : f * 0.66
        let m = Self.keycapMargin(f)

        let chars = Array(label)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: [.font: font]))

        // Where each character starts along the line, and where the last ends.
        var xs: [CGFloat] = []
        var utf16 = 0
        for c in chars {
            xs.append(CTLineGetOffsetForStringIndex(line, utf16, nil))
            utf16 += c.utf16.count
        }
        xs.append(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))

        func ease(_ p: Double) -> CGFloat { CGFloat(1 - pow(1 - min(max(p, 0), 1), 3)) }
        let first = reveal.keys.min().map { min($0, chars.count) } ?? chars.count
        var shown = xs[first]
        for i in first ..< chars.count { shown += (xs[i + 1] - xs[i]) * ease(reveal[i] ?? 1) }

        // The line grows to a set width, then scrolls: older letters slide off the front, fading as they go, so fast
        // typing reads as a moving window onto the newest words rather than a growing bar cut short.
        let window = max(min(maxWidth - 2 * pad, f * Self.typedWindow), f * 4)
        let area = min(shown, window)
        let scroll = max(shown - window, 0)
        let plateWidth = style == .minimal ? area : max(area + 2 * pad, height)

        let bounds = CGRect(x: -m, y: -m, width: plateWidth + 2 * m, height: height + 2 * m)
        var image = CIImage(color: .clear).cropped(to: bounds)
        if style != .minimal, let plate = typedPlate(width: plateWidth, style: style, fontSize: f) {
            // Drawn to the nearest pixel and stretched the rest of the way, so the bar eases rather than steps.
            let drawn = plate.extent.width - 2 * m
            image = plate.transformed(by: CGAffineTransform(scaleX: plateWidth / max(drawn, 1), y: 1)).composited(over: image)
        }
        guard let ink = typedText(label, style: style, fontSize: f) else { return image }
        let lift = style == .keycaps ? f * 0.08 : 0
        let place = CGAffineTransform(translationX: pad - scroll, y: lift)
        let tall = CGRect(x: 0, y: -m, width: 0, height: height + 2 * m)
        // Letters are cut apart on whole pixels of the text image, the same pixel ending one and starting the next, so
        // no seam shows between them. Settled letters as they are; the first's shadow reaches back past the start.
        let cuts = xs.map { $0.rounded() }
        var text = ink.cropped(to: CGRect(x: -m, y: tall.minY, width: cuts[first] + m, height: tall.height)).transformed(by: place)
        for i in first ..< chars.count {
            let p = Double(ease(reveal[i] ?? 1))
            var glyph = ink.cropped(to: CGRect(x: cuts[i], y: tall.minY, width: cuts[i + 1] - cuts[i] + (i == chars.count - 1 ? m : 0),
                                               height: tall.height))
            if p < 0.999 {
                let sigma = (1 - p) * Double(f) * 0.3
                if sigma > 0.05 { glyph = glyph.applyingGaussianBlur(sigma: sigma).cropped(to: glyph.extent.insetBy(dx: -3 * sigma, dy: 0)) }
                glyph = scaleAlpha(glyph, by: p).transformed(by: CGAffineTransform(translationX: 0, y: -(1 - p) * f * 0.22))
            }
            text = glyph.transformed(by: place).composited(over: text)
        }
        if scroll > 0.5 {
            // Only what's in the window, its leading edge fading out; the fade itself comes in as the scroll starts.
            let fade = f * 3
            let strength = min(scroll / fade, 1)
            let edge = CIFilter(name: "CILinearGradient", parameters: [
                "inputPoint0": CIVector(x: pad, y: 0), "inputPoint1": CIVector(x: pad + fade, y: 0),
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1 - strength), "inputColor1": CIColor(red: 1, green: 1, blue: 1),
            ])!.outputImage!
            let visible = CGRect(x: pad, y: tall.minY, width: area + m, height: tall.height)
            text = text.cropped(to: visible).applyingFilter("CIBlendWithAlphaMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: edge.cropped(to: visible),
            ])
        }
        return text.composited(over: image).cropped(to: bounds)
    }

    /// How wide a typed line grows before it scrolls, in multiples of the font size: about a short sentence.
    static let typedWindow: CGFloat = 15

    /// The line's text alone, from x 0 at its start and y 0 at the plate's bottom; kept while it's typed.
    private func typedText(_ text: String, style: KeystrokeSettings.Style, fontSize f: CGFloat) -> CIImage? {
        let key = "typed|\(text)|\(style.rawValue)|\(f)" as NSString
        if let cached = keycapCache.object(forKey: key) { return cached }
        let font = NSFont.systemFont(ofSize: f, weight: .medium)
        let ink = CGColor(gray: style == .light ? 0.1 : 1, alpha: 1)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink]))
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let height = (f * 2).rounded(), m = Self.keycapMargin(f)
        guard let ctx = CGContext(data: nil, width: Int((width + 2 * m).rounded(.up)), height: Int(height + 2 * m), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if style == .minimal {
            ctx.setShadow(offset: CGSize(width: 0, height: -f * 0.06), blur: f * 0.45, color: CGColor(gray: 0, alpha: 0.75))
        }
        ctx.textPosition = CGPoint(x: m, y: m + (height - font.capHeight) / 2)
        CTLineDraw(line, ctx)
        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: -m, y: -m))
        keycapCache.setObject(image, forKey: key)
        return image
    }

    /// The plate alone at a width, to the nearest pixel.
    private func typedPlate(width: CGFloat, style: KeystrokeSettings.Style, fontSize f: CGFloat) -> CIImage? {
        let w = width.rounded()
        let key = "plate|\(w)|\(style.rawValue)|\(f)" as NSString
        if let cached = keycapCache.object(forKey: key) { return cached }
        let height = (f * 2).rounded(), m = Self.keycapMargin(f)
        guard let ctx = CGContext(data: nil, width: Int(w + 2 * m), height: Int(height + 2 * m), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let plate = CGRect(x: m, y: m, width: w, height: height)
        if style == .keycaps {
            Self.drawKeycap(plate, fontSize: f, in: ctx)
        } else {
            Self.drawPlate(plate, light: style == .light, fontSize: f, in: ctx)
        }
        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: -m, y: -m))
        keycapCache.setObject(image, forKey: key)
        return image
    }
}
