//
//  CursorSprite.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/9/26.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

struct NativeCursor {
    let image: CGImage
    let hotspot: CGPoint
    let pixelsPerPoint: CGFloat

    enum Set: CaseIterable {
        case bigSur, tahoe, macOS27
        case pompompurin, pizza, watermelon

        static let macOS: [Set] = [.bigSur, .tahoe, .macOS27]

        var subdirectory: String? {
            switch self {
            case .bigSur: nil
            case .tahoe: "Tahoe"
            case .macOS27: "MacOS27"
            case .pompompurin: "Cute/Pompompurin"
            case .pizza: "Cute/Pizza"
            case .watermelon: "Cute/Watermelon"
            }
        }
    }

    private struct Entry: Decodable {
        var hotspotX: Double
        var hotspotY: Double
        var pixelsPerPoint: Double
    }

    private static let all: [Set: [CursorType: NativeCursor]] = Dictionary(uniqueKeysWithValues: Set.allCases.map { ($0, load($0)) })

    private static func load(_ set: Set) -> [CursorType: NativeCursor] {
        guard var dir = Bundle.module.url(forResource: "Cursors", withExtension: nil) else { return [:] }
        if let sub = set.subdirectory { dir.appendPathComponent(sub) }
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("cursors.json")),
              let entries = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        var out: [CursorType: NativeCursor] = [:]
        for (name, e) in entries {
            guard let type = CursorType(rawValue: name), e.pixelsPerPoint > 0,
                  let source = CGImageSourceCreateWithURL(dir.appendingPathComponent("\(name).png") as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            out[type] = NativeCursor(image: image, hotspot: CGPoint(x: e.hotspotX, y: e.hotspotY), pixelsPerPoint: e.pixelsPerPoint)
        }
        return out
    }

    static func has(_ type: CursorType, in set: Set) -> Bool { all[set]?[type] != nil }

    static func `for`(_ type: CursorType, in set: Set = .bigSur) -> NativeCursor? {
        let cursors = all[set] ?? [:]
        return cursors[type] ?? cursors[.arrow]
    }

    var artwork: CursorArtwork {
        let s = 1 / pixelsPerPoint
        let rect = CGRect(x: -hotspot.x * s, y: -hotspot.y * s, width: CGFloat(image.width) * s, height: CGFloat(image.height) * s)
        let image = image
        return CursorArtwork(bounds: rect) { ctx, _ in
            ctx.interpolationQuality = .high
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
            ctx.restoreGState()
        }
    }
}

struct CursorArtwork {
    var bounds: CGRect
    var draw: (CGContext, CGFloat) -> Void

    static func arrow(fill: CGColor, edge: CGColor) -> CursorArtwork {
        let outline: [CGPoint] = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 15.5), CGPoint(x: 3.6, y: 12.1), CGPoint(x: 6.0, y: 17.6),
            CGPoint(x: 8.5, y: 16.5), CGPoint(x: 6.1, y: 11.2), CGPoint(x: 11.0, y: 11.2),
        ]
        let path = CGMutablePath()
        path.addLines(between: outline)
        path.closeSubpath()
        return CursorArtwork(bounds: path.boundingBox.insetBy(dx: -4, dy: -4).offsetBy(dx: 0, dy: 1)) { ctx, scale in
            ctx.setShadow(offset: CGSize(width: 0, height: -0.8 * scale), blur: 2.4 * scale, color: CGColor(gray: 0, alpha: 0.4))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.addPath(path)
            ctx.setLineJoin(.round)
            ctx.setLineWidth(2.2)
            ctx.setStrokeColor(edge)
            ctx.strokePath()
            ctx.addPath(path)
            ctx.setFillColor(fill)
            ctx.fillPath()
            ctx.endTransparencyLayer()
        }
    }

    static let dot: CursorArtwork = {
        let r: CGFloat = 8
        let circle = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
        // A frosted disc rather than a solid one: a faint body, brighter towards the top-left, that fades out at its
        // edge instead of ending on a hard line.
        let body = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [CGColor(gray: 1, alpha: 0.4), CGColor(gray: 1, alpha: 0.24),
                                       CGColor(gray: 1, alpha: 0)] as CFArray,
                              locations: [0, 0.75, 1])!
        return CursorArtwork(bounds: circle.insetBy(dx: -4, dy: -4).offsetBy(dx: 0, dy: 1)) { ctx, scale in
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.6 * scale), blur: 3 * scale, color: CGColor(gray: 0, alpha: 0.08))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            ctx.drawRadialGradient(body, startCenter: CGPoint(x: -0.25 * r, y: -0.25 * r), startRadius: 0,
                                   endCenter: .zero, endRadius: r, options: [])
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }()
}

final class CursorSprite {
    let image: CIImage
    /// The same pixels left in sRGB for the trail kernel, which samples them as a plain transform would and only then
    /// converts: converting first blends the edges in linear light, a slightly lighter outline.
    let encoded: CIImage
    let hotspot: CGPoint

    init(cgImage: CGImage, hotspot: CGPoint) {
        image = CIImage(cgImage: cgImage)
        encoded = CIImage(cgImage: cgImage, options: [.colorSpace: NSNull()])
        self.hotspot = hotspot
    }

    static func render(style: CursorStyle, type: CursorType, scale: CGFloat) -> CursorSprite? {
        guard let art = style.artwork(for: type) else { return nil }
        return render(art, scale: scale)
    }

    static func render(_ art: CursorArtwork, scale: CGFloat) -> CursorSprite? {
        guard let (cg, hotspot) = art.rasterised(scale: scale) else { return nil }
        return CursorSprite(cgImage: cg, hotspot: CGPoint(x: hotspot.x, y: CGFloat(cg.height) - hotspot.y))
    }
}

extension CursorArtwork {
    func rasterised(scale: CGFloat) -> (image: CGImage, hotspot: CGPoint)? {
        let box = bounds
        let w = Int((box.width * scale).rounded(.up)), h = Int((box.height * scale).rounded(.up))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        draw(ctx, scale)
        guard let cg = ctx.makeImage() else { return nil }
        return (cg, CGPoint(x: -box.minX * scale, y: -box.minY * scale))
    }
}

extension CursorStyle {
    func artwork(for type: CursorType) -> CursorArtwork? {
        artwork ?? nativeSet.flatMap { NativeCursor.for(type, in: $0)?.artwork }
            ?? .arrow(fill: CGColor(gray: 0, alpha: 1), edge: CGColor(gray: 1, alpha: 1))
    }

    public var previewTypes: [CursorType] {
        guard let set = nativeSet, NativeCursor.has(.pointingHand, in: set) else { return [.arrow] }
        return [.arrow, .pointingHand]
    }

    public func preview(_ type: CursorType = .arrow, scale: CGFloat) -> (image: CGImage, hotspot: CGPoint)? {
        artwork(for: type)?.rasterised(scale: scale)
    }
}
