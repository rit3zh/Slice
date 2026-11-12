//
//  Scene.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/9/26.
//

import CoreGraphics
import Foundation

public struct CursorPose: Equatable {
    public var position: CGPoint
    public var angle: Double

    public init(position: CGPoint, angle: Double = 0) {
        self.position = position
        self.angle = angle
    }
}

public struct CursorPointer: Equatable {
    public var pose: CursorPose
    public var screenPoints: CGSize
    public var type: CursorType = .arrow
    public var previousType: CursorType?
    public var fade: Double = 1
    public var trail: [CursorPose] = []
    public var shutter: Double = 0
    public var opacity: Double = 1

    public var position: CGPoint { pose.position }
}

public struct LensState: Equatable {
    public var center: CGPoint
    public var magnification: Double
    public var appear: Double
    public var settings: LensSettings
    public var shapes: [LensShape: Double]

    public init(center: CGPoint, magnification: Double, appear: Double, settings: LensSettings) {
        self.center = center
        self.magnification = magnification
        self.appear = appear
        self.settings = settings
        shapes = [settings.shape: 1]
    }

    static func interpolate(_ a: LensState, _ b: LensState, _ f: Double) -> LensState {
        var out = b
        out.center = CGPoint(x: lerp(a.center.x, b.center.x, f), y: lerp(a.center.y, b.center.y, f))
        out.magnification = exp(lerp(log(max(a.magnification, 1e-6)), log(max(b.magnification, 1e-6)), f))
        out.appear = lerp(a.appear, b.appear, f)
        out.settings = .interpolate(a.settings, b.settings, f)
        out.shapes = a.shapes.mapValues { $0 * (1 - f) }.merging(b.shapes.mapValues { $0 * f }, uniquingKeysWith: +)
            .filter { $0.value > 1e-9 }
        return out
    }
}

extension LensSettings {
    static func interpolate(_ a: LensSettings, _ b: LensSettings, _ f: Double) -> LensSettings {
        var s = f < 0.5 ? a : b
        s.size = lerp(a.size, b.size, f)
        s.refraction = lerp(a.refraction, b.refraction, f)
        s.thickness = lerp(a.thickness, b.thickness, f)
        s.dispersion = lerp(a.dispersion, b.dispersion, f)
        s.blur = lerp(a.blur, b.blur, f)
        s.rim = lerp(a.rim, b.rim, f)
        s.shadow = lerp(a.shadow, b.shadow, f)
        s.opacity = lerp(a.opacity, b.opacity, f)
        return s
    }
}

public struct RenderScene {
    public let project: Project
    public let output: CGSize
    public let cursor: CursorTrack
    public let geometries: [ScreenGeometry]
    let clipStarts: [Double]
    let segments: [Segment]
    let camera: SegmentTimeline<CameraState>
    let cameraZoom: SegmentTimeline<CameraZoom>
    var zoom: SegmentTimeline<ViewRect>!
    /// The 3D phone's camera: the whole frame between zooms (never the flat frame's crop that follows the pointer
    /// when the shapes differ), and each zoom's scale of it.
    var phoneZoom: SegmentTimeline<ViewRect>?
    let turn: SegmentTimeline<ScreenTilt>
    let lensBlocks: [ZoomBlock]
    public let keystrokes: KeystrokeTimeline
    public let transitions: [PlacedTransition]
    /// The 3D phone's display surfaces, made on first use and kept as long as this scene.
    let displaySurfaces = DisplaySurfaces()

    public init(project: Project, output: CGSize, cursor: CursorTrack) {
        self.project = project
        self.output = output
        self.cursor = cursor
        transitions = project.placedTransitions
        keystrokes = KeystrokeTimeline(presses: cursor.keys, settings: project.keystrokes)
        clipStarts = project.clipStarts
        segments = project.segments
        let geometries = project.clips.map { clip in
            ScreenGeometry(contentSize: clip.screenPixelSize, output: output, style: project.style, shapedByAlpha: clip.device != nil)
        }
        self.geometries = geometries
        let style = project.style
        let duration = project.duration

        let starts = clipStarts
        let aspects = geometries.map { $0.frameRect.width / max($0.frameRect.height, 1) }
        func cameraStates(_ layout: CameraLayout) -> (Double) -> CameraState {
            let states = (aspects.isEmpty ? [nil] : aspects.map(Optional.some)).map {
                CameraLayoutResolver.state(for: layout, output: output, style: style, contentAspect: $0)
            }
            return { t in states[min(starts.lastIndex { $0 <= t } ?? 0, states.count - 1)] }
        }
        camera = SegmentTimeline(
            blocks: project.cameraBlocks.map { b in (b.start, b.end, AnyHashable(b.layout), cameraStates(b.layout)) },
            gapKey: AnyHashable(project.defaultCamera), gap: cameraStates(project.defaultCamera),
            duration: duration, transition: style.transitionDuration)

        let standardZooms = project.zoomBlocks.filter { $0.kind == .standard }
        let zoomedLog = log(min(max(style.cameraZoomScale, 0.25), 2))
        cameraZoom = SegmentTimeline(
            blocks: standardZooms.map { b in
                let s = CameraZoom(log: zoomedLog * min(max((b.scale - 1) / 0.5, 0), 1))
                let block: SegmentTimeline<CameraZoom>.Block = (b.start, b.end, AnyHashable(b.id), { _ in s })
                return (block, b.transition, b.ease)
            },
            gapKey: AnyHashable("none"), gap: { _ in CameraZoom(log: 0) },
            duration: duration, transition: style.zoomTransitionDuration)

        turn = SegmentTimeline(
            blocks: standardZooms.map { b in
                let pose = b.tilt.pose
                let block: SegmentTimeline<ScreenTilt>.Block = (b.start, b.end, AnyHashable(b.id), { _ in pose })
                return (block, b.transition, b.ease)
            },
            gapKey: AnyHashable("none"), gap: { _ in .flat },
            duration: duration, transition: style.zoomTransitionDuration)

        let fallback = ScreenGeometry(contentSize: output, output: output, style: style)
        let geometryAt: (Double) -> ScreenGeometry = { t in
            let i = starts.lastIndex { $0 <= t } ?? 0
            return i < geometries.count ? geometries[i] : fallback
        }
        let cursorTrack = cursor
        lensBlocks = project.zoomBlocks.filter { $0.kind == .liquidGlass }.sorted { $0.start < $1.start }
        zoom = SegmentTimeline(
            blocks: standardZooms.map { b in
                let block: SegmentTimeline<ViewRect>.Block = (b.start, b.end, AnyHashable(b.id), { t in
                    ViewRect(geometryAt(t).zoomedView(scale: b.scale, focus: Self.aim(of: b, at: t, cursor: cursorTrack)))
                })
                return (block, b.transition, b.ease)
            },
            gapKey: AnyHashable("none"),
            gap: { t in
                let g = geometryAt(t)
                guard g.followsCursor else { return ViewRect(g.fullView) }
                let p = cursorTrack.position(at: t) ?? CGPoint(x: 0.5, y: 0.5)
                return ViewRect(g.zoomedView(scale: 1, focus: p))
            },
            duration: duration, transition: style.zoomTransitionDuration)

        if project.shows3D {
            let whole = CGRect(origin: .zero, size: output)
            phoneZoom = SegmentTimeline(
                blocks: standardZooms.map { b in
                    let block: SegmentTimeline<ViewRect>.Block = (b.start, b.end, AnyHashable(b.id), { t in
                        ViewRect(Self.phoneView(scale: b.scale, focus: Self.aim(of: b, at: t, cursor: cursorTrack),
                                                content: geometryAt(t).contentRect, output: output))
                    })
                    return (block, b.transition, b.ease)
                },
                gapKey: AnyHashable("none"), gap: { _ in ViewRect(whole) },
                duration: duration, transition: style.zoomTransitionDuration)
        }
    }

    /// `scale` times closer on the frame, centred on `focus` in the content and kept inside the frame.
    static func phoneView(scale: Double, focus: CGPoint, content: CGRect, output: CGSize) -> CGRect {
        let s = max(scale, 1)
        let w = output.width / s, h = output.height / s
        let cx = content.minX + focus.x * content.width, cy = content.minY + focus.y * content.height
        return CGRect(x: min(max(cx - w / 2, 0), output.width - w), y: min(max(cy - h / 2, 0), output.height - h),
                      width: w, height: h)
    }

    /// The part of the frame the 3D phone's camera shows at `t`.
    public func phoneView(at t: Double) -> CGRect { phoneZoom?.value(at: t).rect ?? CGRect(origin: .zero, size: output) }

    public func clipIndex(at t: Double) -> Int { clipStarts.lastIndex { $0 <= t } ?? 0 }

    static func aim(of b: ZoomBlock, at t: Double, cursor: CursorTrack, settle: Double = 0) -> CGPoint {
        if b.followsCursor, let p = cursor.position(at: t) { return p }
        let span = b.end - b.start - 2 * settle
        let progress = span > 0.001 ? (t - b.start - settle) / span : 1
        return b.target(progress: b.ease(progress))
    }

    public func lens(at t: Double) -> LensState? {
        guard let i = lensBlocks.lastIndex(where: { $0.start <= t && t < $0.end }) else { return nil }
        return lens(index: i, at: t)
    }

    func lens(index i: Int, at t: Double) -> LensState? {
        let b = lensBlocks[i]
        let joinedBefore = i > 0 && Self.attached(lensBlocks[i - 1], b)
        let joinedAfter = i + 1 < lensBlocks.count && Self.attached(b, lensBlocks[i + 1])
        let transition = lensTransition(b)
        let fromStart = joinedBefore ? Double.infinity : t - b.start
        let fromEnd = joinedAfter ? Double.infinity : b.end - t
        let p = transition > 0.001 ? min(max(min(fromStart, fromEnd) / transition, 0), 1) : 1
        guard p > 0 else { return nil }
        let zoom = b.ease(p)
        let glass = b.ease(min(p / Self.lensGlassPart, 1))
        let center = Self.aim(of: b, at: t, cursor: cursor, settle: transition)
        let own = LensState(center: center, magnification: pow(max(b.scale, 1), zoom), appear: glass, settings: b.lens)
        guard joinedBefore, transition > 0.001, t - b.start < transition,
              let from = lens(index: i - 1, at: max(t, lensBlocks[i - 1].end)) else { return own }
        return .interpolate(from, own, b.ease((t - b.start) / transition))
    }

    func lensTransition(_ b: ZoomBlock) -> Double {
        min(max(b.transition ?? project.style.zoomTransitionDuration, 0), (b.end - b.start) / 2)
    }

    static func attached(_ a: ZoomBlock, _ b: ZoomBlock) -> Bool { b.start - a.end < lensJoinTolerance }

    static let lensJoinTolerance = 0.04

    static let lensGlassPart = 0.8

    public func clicks(at t: Double, lasting: Double) -> [(age: Double, point: CGPoint)] {
        guard lasting > 0 else { return [] }
        return cursor.clicks.lazy.filter { $0.t <= t && t - $0.t < lasting }.map { (t - $0.t, $0.point) }
    }

    public func geometry(at t: Double) -> ScreenGeometry {
        let i = clipIndex(at: t)
        return i < geometries.count ? geometries[i] : ScreenGeometry(contentSize: output, output: output, style: project.style)
    }

    public func cameraState(at t: Double, followingZoom: Bool = true) -> CameraState {
        let state = camera.value(at: t)
        guard followingZoom else { return state }
        return state.scaled(by: exp(cameraZoom.value(at: t).log * state.zoomFollow), in: output)
    }

    public func cameraSamples(at t: Double, followingZoom: Bool = true) -> [CameraState] {
        let now = cameraState(at: t, followingZoom: followingZoom)
        var shutter = project.style.motionBlurAmount / 60 * Self.cameraShutterBoost
        guard project.style.motionBlur, shutter > 0, !now.isHidden else { return [now] }
        func spread(_ dt: Double) -> CGFloat {
            let before = cameraState(at: t - dt, followingZoom: followingZoom)
            guard !before.isHidden else { return 0 }
            let a = now.rect, b = before.rect
            return [abs(a.minX - b.minX), abs(a.maxX - b.maxX), abs(a.minY - b.minY), abs(a.maxY - b.maxY)].max()!
        }
        var travel = spread(shutter)
        let longest = min(output.width, output.height) * Self.cameraMaxStreak
        if travel > longest {
            shutter *= Double(longest / travel)
            travel = spread(shutter)
        }
        guard travel > 1.5 else { return [now] }
        let count = min(max(Int((travel / 1.5).rounded(.up)), 3), 48)
        return (0 ..< count).map { i in
            let s = cameraState(at: t - shutter * Double(i) / Double(count - 1), followingZoom: followingZoom)
            return s.isHidden ? now : s
        }
    }

    static let cameraShutterBoost = 2.0
    static let cameraMaxStreak = 0.06

    public func view(at t: Double) -> CGRect { zoom.value(at: t).rect }

    public func tilt(at t: Double) -> ScreenTilt { turn.value(at: t) }

    public func viewSamples(at t: Double) -> [CGRect] {
        let now = view(at: t)
        let shutter = project.style.motionBlurAmount / 60
        guard project.style.motionBlur, shutter > 0 else { return [now] }
        let before = view(at: t - shutter)
        let k = output.width / now.width
        let edges = [abs(now.minX - before.minX), abs(now.maxX - before.maxX),
                     abs(now.minY - before.minY), abs(now.maxY - before.maxY)]
        let spread = (edges.max() ?? 0) * k
        guard spread > 1.5 else { return [now] }
        let count = min(max(Int((spread / 2.5).rounded(.up)), 3), 24)
        return (0 ..< count).map { view(at: t - shutter * Double($0) / Double(count - 1)) }
    }
}

func smoothstep(_ x: Double) -> Double {
    let f = min(max(x, 0), 1)
    return f * f * (3 - 2 * f)
}
