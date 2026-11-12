//
//  FrameRenderer+Mockup.swift
//  SliceCore
//
//  Created by rit3zh CX on 11/12/26.
//

import CoreImage

extension FrameRenderer {
    /// The recording's shape inside a mockup, its corners as the mockup's display has them, as seen at zoom `k`.
    func mockupMask(_ m: ScreenMockup, geometry g: ScreenGeometry, rect: CGRect, zoom k: CGFloat) -> CIImage {
        let l = m.layout(content: g.contentRect)
        let most = min(rect.width, rect.height) / 2
        let top = min(l.contentTopRadius * k, most), bottom = min(l.contentBottomRadius * k, most)
        guard abs(top - bottom) > 0.5, let kernel = Self.cornerRectKernel else { return roundedRect(rect, radius: max(top, bottom)) }
        // Bottom left, bottom right, top left, top right.
        let radii = CIVector(x: bottom, y: bottom, z: top, w: top)
        let bounds = CIVector(x: rect.minX, y: rect.minY, z: rect.width, w: rect.height)
        return kernel.apply(extent: rect.insetBy(dx: -1, dy: -1), roiCallback: { _, _ in .null }, arguments: [bounds, radii])
            ?? roundedRect(rect, radius: max(top, bottom))
    }

    /// The browser window drawn behind the recording, as seen through `view`.
    func mockupLayer(_ m: ScreenMockup, geometry g: ScreenGeometry, view: CGRect, output: CGSize) -> CIImage {
        let k = output.width / view.width
        func onScreen(_ r: CGRect) -> CGRect { flip(viewed(r, view: view, output: output), height: output.height) }
        let c = g.contentRect
        let l = m.layout(content: c)
        let outline = onScreen(l.outline)
        guard m.kind != .none else { return .empty() }
        let colors = SafariToolbar.Palette.of(dark: m.dark)
        var under = filled(roundedRect(outline, radius: l.outlineRadius * k), with: CIColor(cgColor: colors.frame))
        let u = SafariMetrics.unit(for: c.size)
        if let toolbar = safariToolbar(m, width: l.outline.width / u, unit: u, zoom: k) {
            let s = u * k / toolbar.pixelsPerUnit
            let placed = toolbar.image.transformed(by: CGAffineTransform(scaleX: s, y: s)
                .concatenating(CGAffineTransform(translationX: outline.minX,
                                                 y: outline.maxY - SafariMetrics.toolbar * u * k)))
            under = placed.composited(over: under)
        }
        return under
    }

    /// Fills a white mask with one colour.
    func filled(_ mask: CIImage, with color: CIColor) -> CIImage {
        CIImage(color: color).cropped(to: mask.extent)
            .applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
    }

    /// The toolbar, `width` units wide, drawn sharp for zoom `k`: at the unzoomed size times the next power of two,
    /// so a zoom redraws it a few times rather than every frame, and kept.
    func safariToolbar(_ m: ScreenMockup, width: CGFloat, unit u: CGFloat,
                       zoom k: CGFloat) -> (image: CIImage, pixelsPerUnit: CGFloat)? {
        let steps = max(ceil(log2(max(k, 1)) - 0.001), 0)
        let ppu = min(u * pow(2, steps), 8192 / max(width, 1))
        let w = Int(ceil(width * ppu)), h = Int(ceil(SafariMetrics.toolbar * ppu))
        guard w > 0, h > 0 else { return nil }
        let key = "\(m.kind.rawValue)|\(m.dark)|\(m.url)|\(Int(width * 4))|\(w)x\(h)" as NSString
        if let cached = mockupToolbars.object(forKey: key) { return (cached, ppu) }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: ppu, y: -ppu)
        SafariToolbar.draw(in: ctx, width: width, minimal: m.kind == .safariMinimal, dark: m.dark, url: m.url)
        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        mockupToolbars.setObject(image, forKey: key)
        return (image, ppu)
    }
}
