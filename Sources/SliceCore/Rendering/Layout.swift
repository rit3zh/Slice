//
//  Layout.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/5/26.
//

import CoreGraphics
import Foundation

public struct CameraState: Interpolatable, Equatable {
    public var rect: CGRect
    public var cornerRadius: CGFloat
    public var opacity: Double
    public var screenSlot = ScreenSlot.full
    public var zoomFollow = 1.0
    public var seam = 0.0
    public var seamEdge = CGRectEdge.minXEdge

    public init(rect: CGRect, cornerRadius: CGFloat, opacity: Double, screenSlot: CGRect = ScreenSlot.full,
                zoomFollow: Double = 1, seam: Double = 0, seamEdge: CGRectEdge = .minXEdge) {
        self.rect = rect
        self.cornerRadius = cornerRadius
        self.opacity = opacity
        self.screenSlot = screenSlot
        self.zoomFollow = zoomFollow
        self.seam = seam
        self.seamEdge = seamEdge
    }

    public static let hidden = CameraState(rect: .null, cornerRadius: 0, opacity: 0)
    public var isHidden: Bool { rect.isNull || opacity <= 0.001 }

    public static func interpolate(_ a: CameraState, _ b: CameraState, _ t: Double) -> CameraState {
        var s: CameraState
        switch (a.rect.isNull, b.rect.isNull) {
        case (true, true): return .hidden
        case (true, false): s = b.shrunk(by: 1 - t)
        case (false, true): s = a.shrunk(by: t)
        case (false, false):
            s = CameraState(rect: lerp(a.rect, b.rect, t), cornerRadius: lerp(a.cornerRadius, b.cornerRadius, t),
                            opacity: lerp(a.opacity, b.opacity, t))
        }
        s.screenSlot = lerp(a.screenSlot, b.screenSlot, t)
        s.zoomFollow = lerp(a.zoomFollow, b.zoomFollow, t)
        s.seam = lerp(a.seam, b.seam, t)
        s.seamEdge = b.seam > 0 ? b.seamEdge : a.seamEdge
        return s
    }

    func scaled(by s: Double, in output: CGSize) -> CameraState {
        guard !rect.isNull, abs(s - 1) > 1e-9 else { return self }
        func anchor(_ min: CGFloat, _ size: CGFloat, _ space: CGFloat) -> CGFloat {
            let free = space - size
            return min + size * (free > 0.5 ? Swift.min(Swift.max(min / free, 0), 1) : 0.5)
        }
        let k = CGFloat(s)
        let ax = anchor(rect.minX, rect.width, output.width), ay = anchor(rect.minY, rect.height, output.height)
        return CameraState(rect: CGRect(x: ax - (ax - rect.minX) * k, y: ay - (ay - rect.minY) * k,
                                        width: rect.width * k, height: rect.height * k),
                           cornerRadius: cornerRadius * k, opacity: opacity, screenSlot: screenSlot, zoomFollow: zoomFollow,
                           seam: seam, seamEdge: seamEdge)
    }

    private func shrunk(by amount: Double) -> CameraState {
        let s = 1 - 0.15 * amount
        let w = rect.width * s, h = rect.height * s
        return CameraState(rect: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h),
                           cornerRadius: cornerRadius * s, opacity: opacity * (1 - amount), screenSlot: screenSlot,
                           zoomFollow: zoomFollow, seam: seam, seamEdge: seamEdge)
    }
}

public enum ScreenSlot {
    public static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    public static func rect(_ slot: CGRect, in output: CGSize) -> CGRect {
        CGRect(x: slot.minX * output.width, y: slot.minY * output.height,
               width: slot.width * output.width, height: slot.height * output.height)
    }

    public static func amount(_ slot: CGRect) -> Double {
        min(max(Double(1 - min(slot.width, slot.height)) / 0.25, 0), 1)
    }
}

public enum CameraLayoutResolver {
    public static func state(for layout: CameraLayout, output: CGSize, style: FrameStyle,
                             contentAspect: CGFloat? = nil) -> CameraState {
        let base = min(output.width, output.height)
        let margin = base * 0.035
        let rect: CGRect
        switch layout {
        case .hidden:
            return .hidden
        case let .corner(corner, shape, size):
            let long = base * (size == .small ? 0.32 : 0.5)
            let s: CGSize = switch shape {
            case .landscape: CGSize(width: long, height: long * 9 / 16)
            case .portrait: CGSize(width: long * 3 / 4, height: long)
            case .square: CGSize(width: long * 0.8, height: long * 0.8)
            }
            let x = (corner == .topLeft || corner == .bottomLeft) ? margin : output.width - margin - s.width
            let y = (corner == .topLeft || corner == .topRight) ? margin : output.height - margin - s.height
            rect = CGRect(origin: CGPoint(x: x, y: y), size: s)
        case let .centre(coverage):
            var w = output.width * min(max(coverage, 0.2), 1)
            var h = w * 9 / 16
            if h > output.height * 0.9 {
                h = output.height * 0.9
                w = h * 16 / 9
            }
            rect = CGRect(x: (output.width - w) / 2, y: (output.height - h) / 2, width: w, height: h)
        case .fullscreen:
            return CameraState(rect: CGRect(origin: .zero, size: output), cornerRadius: 0, opacity: 1, zoomFollow: 0)
        case let .split(side, share):
            return split(side, share: share, output: output, style: style, contentAspect: contentAspect ?? 16 / 10)
        }
        let radius = min(rect.width, rect.height) * style.cameraCornerRadius
        return CameraState(rect: rect, cornerRadius: radius, opacity: 1)
    }

    /// With a `share`, the two sit side by side in that ratio, as large as fits with all of the screen showing.
    private static func split(_ side: SplitSide, share: Double?, output: CGSize, style: FrameStyle,
                              contentAspect: CGFloat) -> CameraState {
        let base = min(output.width, output.height)
        let margin = base * max(style.effectivePadding, 0.02)
        let avail = CGRect(origin: .zero, size: output).insetBy(dx: margin, dy: margin)
        let aspect = min(max(contentAspect, 0.3), 4)
        let first = side == .left
        let camera: CGRect, screen: CGRect
        if output.width >= output.height {
            var height = avail.height
            var cameraWidth = avail.width - height * aspect
            if let share = share.map({ CGFloat(min(max($0, 0.1), 0.9)) }) {
                let total = min(avail.width, height * aspect / (1 - share))
                cameraWidth = total * share
                height = (total - cameraWidth) / aspect
            } else {
                let least = avail.width * 0.26, most = min(avail.width * 0.45, height * 0.9)
                if cameraWidth < least {
                    cameraWidth = least
                    height = (avail.width - least) / aspect
                }
                cameraWidth = min(cameraWidth, most)
            }
            let screenWidth = height * aspect
            let x = avail.minX + (avail.width - screenWidth - cameraWidth) / 2, y = avail.minY + (avail.height - height) / 2
            camera = CGRect(x: first ? x : x + screenWidth, y: y, width: cameraWidth, height: height)
            screen = CGRect(x: first ? x + cameraWidth : x, y: y, width: screenWidth, height: height)
        } else {
            var width = avail.width
            var cameraHeight = avail.height - width / aspect
            if let share = share.map({ CGFloat(min(max($0, 0.1), 0.9)) }) {
                let total = min(avail.height, width / aspect / (1 - share))
                cameraHeight = total * share
                width = (total - cameraHeight) * aspect
            } else {
                let least = avail.height * 0.3, most = min(avail.height * 0.55, width * 1.1)
                if cameraHeight < least {
                    cameraHeight = least
                    width = (avail.height - least) * aspect
                }
                cameraHeight = min(cameraHeight, most)
            }
            let screenHeight = width / aspect
            let x = avail.minX + (avail.width - width) / 2, y = avail.minY + (avail.height - screenHeight - cameraHeight) / 2
            camera = CGRect(x: x, y: first ? y : y + screenHeight, width: width, height: cameraHeight)
            screen = CGRect(x: x, y: first ? y + cameraHeight : y, width: width, height: screenHeight)
        }
        let slot = CGRect(x: screen.minX / output.width, y: screen.minY / output.height,
                          width: screen.width / output.width, height: screen.height / output.height)
        let edge: CGRectEdge = output.width >= output.height ? (first ? .maxXEdge : .minXEdge) : (first ? .maxYEdge : .minYEdge)
        return CameraState(rect: camera, cornerRadius: splitRadius(style: style, output: output), opacity: 1,
                           screenSlot: slot, zoomFollow: 0, seam: 1, seamEdge: edge)
    }

    public static func splitRadius(style: FrameStyle, output: CGSize) -> CGFloat {
        min(output.width, output.height) * max(style.screenCornerRadius * 1.6, 0.02)
    }
}

public struct ScreenGeometry: Equatable {
    public var output: CGSize
    public var contentRect: CGRect
    public var fullBleedSize: CGSize
    public var followsCursor: Bool
    public var shapedByAlpha = false
    /// The browser or phone drawn around the recording; never around a framed device, which has its own.
    public var mockup: ScreenMockup?
    /// The recording and its mockup together: `contentRect` without one.
    public var frameRect: CGRect

    public init(contentSize: CGSize, output: CGSize, style: FrameStyle, shapedByAlpha: Bool = false) {
        self.output = output
        self.shapedByAlpha = shapedByAlpha
        let base = min(output.width, output.height)
        let inset = base * style.effectivePadding
        let avail = CGSize(width: max(output.width - 2 * inset, 1), height: max(output.height - 2 * inset, 1))
        let c = contentSize.width > 0 && contentSize.height > 0 ? contentSize : output
        let mockup = shapedByAlpha || style.mockup.kind == .none ? nil : style.mockup
        self.mockup = mockup
        // The mockup grows with the recording, so the two are fitted together.
        let m = mockup?.insets(for: c) ?? .zero
        let outer = CGSize(width: c.width + m.left + m.right, height: c.height + m.top + m.bottom)
        let scale = min(avail.width / outer.width, avail.height / outer.height)
        let size = CGSize(width: c.width * scale, height: c.height * scale)
        frameRect = CGRect(x: (output.width - outer.width * scale) / 2, y: (output.height - outer.height * scale) / 2,
                           width: outer.width * scale, height: outer.height * scale)
        contentRect = CGRect(x: frameRect.minX + m.left * scale, y: frameRect.minY + m.top * scale,
                             width: size.width, height: size.height)
        let outAspect = output.width / output.height
        let contentAspect = size.width / size.height
        fullBleedSize = contentAspect > outAspect
            ? CGSize(width: size.height * outAspect, height: size.height)
            : CGSize(width: size.width, height: size.width / outAspect)
        let framedAspect = frameRect.width / frameRect.height
        let mismatch = max(framedAspect / outAspect, outAspect / framedAspect)
        isMismatched = mismatch > Self.mismatchLimit
        followsCursor = isMismatched
        // A framed device sits whole on the canvas at any aspect, as the 3D phone does: never cropped to fill. A screen
        // fitted whole does the same, so zooms are measured from all of it; so does one in a mockup, which cropping
        // would cut away.
        if shapedByAlpha || (isMismatched && (style.fitsScreen || mockup != nil)) {
            fullBleedSize = output
            followsCursor = false
        }
    }

    /// Past this, the recording is cropped to fill the frame unless it's fitted whole.
    public static let mismatchLimit: CGFloat = 1.4
    /// The recording's shape is far enough from the frame's that it's either cropped to fill or fitted whole.
    public private(set) var isMismatched = false

    public var fullView: CGRect { CGRect(origin: .zero, size: output) }

    public func zoomedView(scale: Double, focus: CGPoint) -> CGRect {
        let s = max(scale, 1)
        let w = fullBleedSize.width / s, h = fullBleedSize.height / s
        let cx = contentRect.minX + focus.x * contentRect.width
        let cy = contentRect.minY + focus.y * contentRect.height
        if shapedByAlpha {
            return CGRect(x: min(max(cx - w / 2, 0), output.width - w), y: min(max(cy - h / 2, 0), output.height - h),
                          width: w, height: h)
        }
        let c = contentRect
        return CGRect(x: Self.place(cx - w / 2, length: w, content: c.minX ... c.maxX, frame: output.width),
                      y: Self.place(cy - h / 2, length: h, content: c.minY ... c.maxY, frame: output.height),
                      width: w, height: h)
    }

    /// Keeps a view inside the content along one axis; one longer than the content (a fitted screen zoomed in only a
    /// little) keeps all of the content in view instead, without leaving the frame.
    static func place(_ origin: CGFloat, length: CGFloat, content: ClosedRange<CGFloat>, frame: CGFloat) -> CGFloat {
        let lo = content.lowerBound, hi = content.upperBound
        if length <= hi - lo + 0.001 { return min(max(origin, lo), hi - length) }
        return min(max(min(max(origin, hi - length), lo), 0), frame - length)
    }
}

public struct ViewRect: Interpolatable, Equatable {
    public var rect: CGRect

    public init(_ rect: CGRect) { self.rect = rect }

    public static func interpolate(_ a: ViewRect, _ b: ViewRect, _ t: Double) -> ViewRect {
        // Width in log space keeps zoom speed perceptually even. The centre moves in step with the width rather than
        // with time, so the point the two views share (where one is the other scaled) stays put on screen: a zoom
        // pushes straight in to its spot instead of drifting sideways first and catching up at the end. With no
        // change in size it's a plain pan.
        let w = exp(lerp(log(a.rect.width), log(b.rect.width), t))
        let h = w * a.rect.height / a.rect.width
        let dw = b.rect.width - a.rect.width
        let f = abs(dw) > a.rect.width * 1e-4 ? Double((w - a.rect.width) / dw) : t
        let cx = lerp(a.rect.midX, b.rect.midX, f)
        let cy = lerp(a.rect.midY, b.rect.midY, f)
        return ViewRect(CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h))
    }
}

struct CameraZoom: Interpolatable, Equatable {
    var log: Double

    static func interpolate(_ a: CameraZoom, _ b: CameraZoom, _ t: Double) -> CameraZoom {
        CameraZoom(log: lerp(a.log, b.log, t))
    }
}

func lerp(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
func lerp(_ a: CGRect, _ b: CGRect, _ t: Double) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
           width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}
