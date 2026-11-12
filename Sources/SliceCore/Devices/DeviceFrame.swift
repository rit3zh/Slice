//
//  DeviceFrame.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/1/26.
//

import CoreGraphics
import Foundation
import ImageIO

public struct DeviceColor: RawRepresentable, Hashable, Codable, Sendable, Comparable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ name: String) { rawValue = name }

    public static let silver = DeviceColor("Silver")
    public static let black = DeviceColor("Black")
    public static let cosmicOrange = DeviceColor("Cosmic Orange")
    public static let deepBlue = DeviceColor("Deep Blue")

    public static func < (a: DeviceColor, b: DeviceColor) -> Bool { a.rawValue < b.rawValue }
}

public struct DeviceScreenGeometry: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat
    public var cornerRadius: CGFloat
    /// The frame's Dynamic Island or notch, drawn over the top of the display, as fractions of the image.
    public var cutout: CGRect?

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    public func rect(in size: CGSize) -> CGRect {
        CGRect(x: x * size.width, y: y * size.height, width: width * size.width, height: height * size.height)
    }
}

public struct DeviceFrameDefinition: Equatable, Sendable {
    public let model: String
    public let color: DeviceColor
    public let frameURL: URL?
    public let canvasSize: CGSize
    public let screen: DeviceScreenGeometry
    public var screenRect: CGRect { screen.rect(in: canvasSize) }
    public var screenCornerRadius: CGFloat { screen.cornerRadius * screenRect.width }
    public func scale(for device: DeviceModel) -> CGFloat {
        device.screenPixels.width > 0 ? screenRect.width / device.screenPixels.width : 1
    }

    public var isFrameless: Bool { frameURL == nil }

    public static func frameless(for device: DeviceModel) -> DeviceFrameDefinition {
        DeviceFrameDefinition(model: device.frameName, color: DeviceColor("None"), frameURL: nil, canvasSize: device.screenPixels,
                              screen: DeviceScreenGeometry(x: 0, y: 0, width: 1, height: 1, cornerRadius: 0))
    }

    var cacheKey: String { frameURL?.path ?? "frameless \(Int(canvasSize.width))x\(Int(canvasSize.height))" }
}

public struct DeviceFrameImage {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    public let mask: [UInt8]
    public let screen: DeviceScreenGeometry

    static let openingAlpha: UInt8 = 128
    static let maskGrowth = 2

    public enum LoadError: Error { case unreadable(URL), noOpening(URL) }

    public static func load(_ url: URL) throws -> DeviceFrameImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw LoadError.unreadable(url) }
        guard let frame = analyse(image) else { throw LoadError.noOpening(url) }
        return frame
    }

    public static func analyse(_ image: CGImage) -> DeviceFrameImage? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var region = [UInt8](repeating: 0, count: w * h)
        let bounds = pixels.withUnsafeBufferPointer { px in
            region.withUnsafeMutableBufferPointer { fill(px.baseAddress!, w: w, h: h, into: $0.baseAddress!) }
        }
        guard let bounds else { return nil }

        var cornerRows = 0
        while cornerRows < Int(bounds.height), region[(Int(bounds.minY) + cornerRows) * w + Int(bounds.minX)] == 0 { cornerRows += 1 }

        let mask = grow(region, w: w, h: h, by: maskGrowth)
        let cut = cutout(in: region, w: w, bounds: bounds)
        let screen = DeviceScreenGeometry(x: bounds.minX / CGFloat(w), y: bounds.minY / CGFloat(h),
                                          width: bounds.width / CGFloat(w), height: bounds.height / CGFloat(h),
                                          cornerRadius: CGFloat(cornerRows) / bounds.width,
                                          cutout: cut.map { CGRect(x: $0.minX / CGFloat(w), y: $0.minY / CGFloat(h),
                                                                   width: $0.width / CGFloat(w), height: $0.height / CGFloat(h)) })
        return DeviceFrameImage(width: w, height: h, pixels: pixels, mask: mask, screen: screen)
    }

    public static func frameless(size: CGSize) -> DeviceFrameImage {
        let w = max(Int(size.width), 1), h = max(Int(size.height), 1)
        return DeviceFrameImage(width: w, height: h, pixels: [UInt8](repeating: 0, count: w * h * 4),
                                mask: [UInt8](repeating: 255, count: w * h),
                                screen: DeviceScreenGeometry(x: 0, y: 0, width: 1, height: 1, cornerRadius: 0))
    }

    /// The frame with its island or notch taken out, the display showing through where it was: for a recording that
    /// has its own there. A little beyond it too, for its soft edge; never past the opening into the bezel.
    public func withoutCutout() -> DeviceFrameImage {
        guard let c = screen.cutout else { return self }
        let fw = CGFloat(width), fh = CGFloat(height)
        let margin = CGFloat(Self.maskGrowth + 2)
        let opening = CGRect(x: screen.x * fw, y: screen.y * fh, width: screen.width * fw, height: screen.height * fh)
        let r = CGRect(x: c.minX * fw, y: c.minY * fh, width: c.width * fw, height: c.height * fh)
            .insetBy(dx: -margin, dy: -margin).intersection(opening).integral
        guard !r.isEmpty else { return self }
        var pixels = self.pixels, mask = self.mask
        for y in Int(r.minY) ..< min(Int(r.maxY), height) {
            for x in Int(r.minX) ..< min(Int(r.maxX), width) {
                let i = y * width + x
                pixels.replaceSubrange(i * 4 ..< i * 4 + 4, with: [0, 0, 0, 0])
                mask[i] = 255
            }
        }
        var open = screen
        open.cutout = nil
        return DeviceFrameImage(width: width, height: height, pixels: pixels, mask: mask, screen: open)
    }

    /// Frame drawn inside the opening near its top, away from the rounded corners: the island or notch.
    private static func cutout(in region: [UInt8], w: Int, bounds: CGRect) -> CGRect? {
        let x0 = Int(bounds.minX + bounds.width * 0.2), x1 = Int(bounds.maxX - bounds.width * 0.2)
        let y0 = Int(bounds.minY), y1 = Int(bounds.minY + bounds.height * 0.12)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in y0 ..< y1 {
            for x in x0 ..< x1 where region[y * w + x] == 0 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func fill(_ px: UnsafePointer<UInt8>, w: Int, h: Int, into region: UnsafeMutablePointer<UInt8>) -> CGRect? {
        let threshold = openingAlpha
        @inline(__always) func open(_ i: Int) -> Bool { region[i] == 0 && px[i &* 4 &+ 3] < threshold }
        guard open((h / 2) * w + w / 2) else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1
        var stack = [(w / 2, h / 2)]
        while let (sx, y) = stack.popLast() {
            let row = y * w
            guard open(row + sx) else { continue }
            var x = sx
            while x > 0, open(row + x - 1) { x -= 1 }
            let first = x
            var above = false, below = false
            while x < w, open(row + x) {
                region[row + x] = 1
                if y > 0 {
                    let o = open(row - w + x)
                    if o, !above { stack.append((x, y - 1)) }
                    above = o
                }
                if y < h - 1 {
                    let o = open(row + w + x)
                    if o, !below { stack.append((x, y + 1)) }
                    below = o
                }
                x += 1
            }
            minX = min(minX, first); maxX = max(maxX, x - 1)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    private static func grow(_ region: [UInt8], w: Int, h: Int, by r: Int) -> [UInt8] {
        var rows = [UInt8](repeating: 0, count: w * h)
        var out = [UInt8](repeating: 0, count: w * h)
        region.withUnsafeBufferPointer { src in
            rows.withUnsafeMutableBufferPointer { mid in
                out.withUnsafeMutableBufferPointer { dst in
                    let src = src.baseAddress!, mid = mid.baseAddress!, dst = dst.baseAddress!
                    for y in 0 ..< h {
                        let row = y * w
                        var lastSet = Int.min / 2
                        for x in 0 ..< min(r, w) where src[row + x] != 0 { lastSet = x }
                        for x in 0 ..< w {
                            if x + r < w, src[row + x + r] != 0 { lastSet = x + r }
                            if lastSet >= x - r { mid[row + x] = 255 }
                        }
                    }
                    for x in 0 ..< w {
                        var lastSet = Int.min / 2
                        for y in 0 ..< min(r, h) where mid[y * w + x] != 0 { lastSet = y }
                        for y in 0 ..< h {
                            if y + r < h, mid[(y + r) * w + x] != 0 { lastSet = y + r }
                            if lastSet >= y - r { dst[y * w + x] = 255 }
                        }
                    }
                }
            }
        }
        return out
    }
}

public final class DeviceFrameCatalog: @unchecked Sendable {
    public let frames: [String: [DeviceColor: URL]]
    private let lock = NSLock()
    private var definitions: [URL: DeviceFrameDefinition] = [:]

    public init(directory: URL) {
        var found: [String: [DeviceColor: URL]] = [:]
        let fm = FileManager.default
        for folder in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            let model = folder.lastPathComponent
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
                guard let color = Self.color(of: file, model: model) else { continue }
                found[model, default: [:]][color] = file
            }
        }
        frames = found
    }

    static func color(of file: URL, model: String) -> DeviceColor? {
        guard file.pathExtension.lowercased() == "png" else { return nil }
        let name = file.deletingPathExtension().lastPathComponent
        let prefix = "\(model) - "
        guard name.hasPrefix(prefix) else { return nil }
        let color = String(name.dropFirst(prefix.count))
        guard !color.isEmpty, !color.hasSuffix(" - Shadow") else { return nil }
        return DeviceColor(color)
    }

    public var models: [String] { frames.keys.sorted() }

    public static let standInAspectTolerance: CGFloat = 0.02

    public func colors(for model: String) -> [DeviceColor] { (frames[model] ?? [:]).keys.sorted() }

    public func definition(model: String, color: DeviceColor) throws -> DeviceFrameDefinition? {
        guard let url = frames[model]?[color] else { return nil }
        if let cached = lock.withLock({ definitions[url] }) { return cached }
        let image = try DeviceFrameImage.load(url)
        let definition = DeviceFrameDefinition(model: model, color: color, frameURL: url,
                                               canvasSize: CGSize(width: image.width, height: image.height), screen: image.screen)
        lock.withLock { definitions[url] = definition }
        return definition
    }

    public func frame(for device: DeviceModel, aspectTolerance: CGFloat = standInAspectTolerance) -> (model: String, exact: Bool)? {
        if frames[device.frameName] != nil { return (device.frameName, true) }
        let target = device.screenPixels
        guard target.width > 0, target.height > 0 else { return models.first.map { ($0, false) } }
        let candidates: [(String, CGSize)] = models.compactMap { model in
            guard let color = colors(for: model).first, let d = try? definition(model: model, color: color) else { return nil }
            return (model, d.screenRect.size)
        }
        func cost(_ size: CGSize) -> CGFloat {
            let aspect = abs(log((size.width / size.height) / (target.width / target.height)))
            let scale = abs(log(size.width / target.width))
            return aspect * 10 + scale
        }
        guard let best = candidates.min(by: { cost($0.1) < cost($1.1) }),
              abs(log((best.1.width / best.1.height) / (target.width / target.height))) < aspectTolerance
        else { return nil }
        return (best.0, false)
    }
}
