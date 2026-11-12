//
//  SceneTests.swift
//  SliceCoreTests
//
//  Created by rit3zh CX on 10/13/26.
//

import CoreGraphics
import Foundation
@testable import SliceCore
import XCTest

final class SceneTests: XCTestCase {
    let out = CGSize(width: 1920, height: 1080)

    func project(duration: Double = 20, content: CGSize = CGSize(width: 3840, height: 2160)) -> Project {
        var p = Project(name: "Test")
        p.clips = [Clip(screenFile: "s.mov", duration: duration, screenPixelSize: content,
                        captureRect: CGRect(x: 0, y: 0, width: 1920, height: 1080))]
        return p
    }

    func testCornerLayoutsStayInsideFrame() {
        for aspect in OutputAspect.allCases {
            let size = aspect.size(shortSide: 1080)
            for c in Corner.allCases { for s in CameraShape.allCases { for z in CameraSize.allCases {
                let st = CameraLayoutResolver.state(for: .corner(c, s, z), output: size, style: FrameStyle())
                XCTAssertTrue(CGRect(origin: .zero, size: size).contains(st.rect), "\(aspect) \(c) \(s) \(z)")
            } } }
        }
    }

    func testSplitSharesKeepTheirRatioAndTheWholeScreen() {
        for aspect in OutputAspect.allCases {
            let size = aspect.size(shortSide: 1080), wide = size.width >= size.height
            for side in SplitSide.allCases { for share in [0.5, 1.0 / 3, 0.25] {
                let st = CameraLayoutResolver.state(for: .split(side, share: share), output: size, style: FrameStyle(),
                                                    contentAspect: 16 / 10)
                let screen = ScreenSlot.rect(st.screenSlot, in: size)
                let camera = wide ? st.rect.width : st.rect.height, rest = wide ? screen.width : screen.height
                XCTAssertEqual(camera / (camera + rest), share, accuracy: 0.001, "\(aspect) \(side) \(share)")
                XCTAssertEqual(screen.width / screen.height, 16 / 10, accuracy: 0.001, "\(aspect) \(side) \(share)")
                XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(st.rect.union(screen)))
            } }
        }
    }

    func testSplitFromBeforeSharesStillOpens() throws {
        let old = try JSONDecoder().decode(CameraLayout.self, from: Data(#"{"split": {"_0": "left"}}"#.utf8))
        XCTAssertEqual(old, .split(.left))
    }

    func testCameraTransitionIsContinuousAndSettles() {
        var p = project()
        p.defaultCamera = .corner(.bottomRight, .square, .small)
        p.cameraBlocks = [CameraBlock(start: 5, end: 10, layout: .centre(coverage: 0.7))]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        let before = scene.cameraState(at: 4.99)
        let atStart = scene.cameraState(at: 5.0)
        XCTAssertEqual(before.rect.minX, atStart.rect.minX, accuracy: 0.5)
        let settled = scene.cameraState(at: 7)
        XCTAssertEqual(settled, CameraLayoutResolver.state(for: .centre(coverage: 0.7), output: out, style: p.style))
        let mid = scene.cameraState(at: 5.3)
        XCTAssertTrue(mid.rect.width > before.rect.width && mid.rect.width < settled.rect.width)
    }

    func testHiddenFadesOut() {
        var p = project()
        p.cameraBlocks = [CameraBlock(start: 5, end: 10, layout: .hidden)]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        XCTAssertEqual(scene.cameraState(at: 4.9).opacity, 1)
        let mid = scene.cameraState(at: 5.3).opacity
        XCTAssertTrue(mid > 0 && mid < 1)
        XCTAssertTrue(scene.cameraState(at: 6).isHidden)
        XCTAssertEqual(scene.cameraState(at: 11).opacity, 1)
    }

    func testShortBlockChainHasNoJump() {
        var p = project()
        p.cameraBlocks = [
            CameraBlock(start: 5, end: 5.2, layout: .corner(.topLeft, .square, .large)),
            CameraBlock(start: 5.2, end: 9, layout: .corner(.topRight, .landscape, .small)),
        ]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        for boundary in [5.0, 5.2] {
            let a = scene.cameraState(at: boundary - 1e-4).rect, b = scene.cameraState(at: boundary + 1e-4).rect
            XCTAssertLessThan(abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width), 2, "jump at \(boundary)")
        }
    }

    func testCameraScalesWithTheZoomAndBack() {
        var p = project()
        p.defaultCamera = .corner(.bottomRight, .square, .small)
        p.zoomBlocks = [ZoomBlock(start: 4, end: 9, scale: 2, focus: CGPoint(x: 0.5, y: 0.5))]
        p.style.cameraZoomScale = 0.7
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        let normal = CameraLayoutResolver.state(for: p.defaultCamera, output: out, style: p.style)
        XCTAssertEqual(scene.cameraState(at: 3), normal)
        let zoomed = scene.cameraState(at: 6.5)
        XCTAssertEqual(zoomed.rect.width, normal.rect.width * 0.7, accuracy: 0.01)
        XCTAssertEqual(zoomed.cornerRadius, normal.cornerRadius * 0.7, accuracy: 0.01)
        XCTAssertEqual(zoomed.rect.maxX, normal.rect.maxX, accuracy: normal.rect.width * 0.05)
        XCTAssertEqual(zoomed.rect.maxY, normal.rect.maxY, accuracy: normal.rect.height * 0.05)
        XCTAssertTrue(CGRect(origin: .zero, size: out).contains(zoomed.rect))
        XCTAssertEqual(scene.cameraState(at: 6.5, followingZoom: false), normal)
        XCTAssertEqual(scene.cameraState(at: 11), normal)

        let unzoomed = scene.view(at: 3).width, full = scene.view(at: 6.5).width
        let zoomOf: (Double) -> Double = { t in log(unzoomed / scene.view(at: t).width) / log(unzoomed / full) }
        let scaleOf: (Double) -> Double = { t in log(scene.cameraState(at: t).rect.width / normal.rect.width) / log(0.7) }
        for t in stride(from: 3.5, through: 10.5, by: 0.05) {
            XCTAssertEqual(scaleOf(t), zoomOf(t), accuracy: 0.01, "at \(t)")
        }
        var last = scene.cameraState(at: 3).rect
        for t in stride(from: 3.0, through: 11, by: 1.0 / 120) {
            let r = scene.cameraState(at: t).rect
            XCTAssertLessThan(abs(r.minX - last.minX) + abs(r.width - last.width), 8, "jump at \(t)")
            last = r
        }
    }

    func testCameraIsBlurredOnlyWhileItMoves() {
        var p = project()
        p.defaultCamera = .corner(.bottomRight, .square, .small)
        p.cameraBlocks = [CameraBlock(start: 5, end: 10, layout: .corner(.topLeft, .landscape, .large))]
        p.zoomBlocks = [ZoomBlock(start: 12, end: 16, scale: 2, focus: CGPoint(x: 0.5, y: 0.5))]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        XCTAssertEqual(scene.cameraSamples(at: 4).count, 1)
        XCTAssertEqual(scene.cameraSamples(at: 8).count, 1)
        XCTAssertEqual(scene.cameraSamples(at: 14).count, 1)
        let moving = scene.cameraSamples(at: 5.3)
        XCTAssertGreaterThan(moving.count, 3)
        XCTAssertEqual(moving[0], scene.cameraState(at: 5.3))
        let streak = hypot(moving[0].rect.minX - moving.last!.rect.minX, moving[0].rect.minY - moving.last!.rect.minY)
        XCTAssertGreaterThan(streak, 5)
        XCTAssertLessThanOrEqual(streak, 1080 * RenderScene.cameraMaxStreak * 1.5)
        XCTAssertGreaterThan(scene.cameraSamples(at: 12.5).count, 1)
        p.style.motionBlur = false
        let still = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        XCTAssertEqual(still.cameraSamples(at: 5.3).count, 1)
    }

    func testZoomViewStaysInsideContentAndHasOutputAspect() {
        var p = project()
        p.zoomBlocks = [ZoomBlock(start: 2, end: 6, scale: 2.5, focus: CGPoint(x: 0.98, y: 0.02))]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        XCTAssertEqual(scene.view(at: 1), CGRect(origin: .zero, size: out))
        let v = scene.view(at: 4)
        let g = scene.geometry(at: 4)
        XCTAssertTrue(g.contentRect.insetBy(dx: -0.01, dy: -0.01).contains(v))
        XCTAssertEqual(v.width / v.height, 16.0 / 9.0, accuracy: 0.001)
        XCTAssertEqual(v.width, g.fullBleedSize.width / 2.5, accuracy: 0.01)
        XCTAssertEqual(scene.view(at: 8), CGRect(origin: .zero, size: out))
        XCTAssertNotEqual(scene.view(at: 6.5), CGRect(origin: .zero, size: out))
    }

    func testMotionBlurOnlyWhileMoving() {
        var p = project()
        p.zoomBlocks = [ZoomBlock(start: 2, end: 6, scale: 2)]
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        XCTAssertEqual(scene.viewSamples(at: 1).count, 1)
        XCTAssertGreaterThan(scene.viewSamples(at: 2.4).count, 2)
        XCTAssertEqual(scene.viewSamples(at: 4).count, 1)
    }

    func testPortraitFollowsCursor() {
        let p = project()
        let log = CursorLog(samples: (0 ... 200).map { i in
            CursorLog.Sample(t: Double(i) * 0.1, x: i < 100 ? 0.1 : 0.9, y: 0.5)
        })
        let track = CursorTrack(project: p, logs: [p.clips[0].id: log])
        let portrait = OutputAspect.portrait9x16.size(shortSide: 1080)
        let scene = RenderScene(project: p, output: portrait, cursor: track)
        XCTAssertTrue(scene.geometry(at: 0).followsCursor)
        let left = scene.view(at: 3).midX, right = scene.view(at: 17).midX
        XCTAssertLessThan(left, right)
        XCTAssertLessThan(abs(scene.view(at: 10.0).midX - scene.view(at: 10.034).midX), 60)
    }

    func testPortraitFitsWholeRecording() {
        var p = project()
        p.style.fitsScreen = true
        let portrait = OutputAspect.portrait9x16.size(shortSide: 1080)
        let scene = RenderScene(project: p, output: portrait, cursor: CursorTrack(project: p, logs: [:]))
        let g = scene.geometry(at: 0)
        XCTAssertTrue(g.isMismatched)
        XCTAssertFalse(g.followsCursor)
        XCTAssertEqual(scene.view(at: 3), g.fullView)
        // Zooms are measured from the whole frame and keep all of the screen in view until they're closer than it.
        let near = g.zoomedView(scale: 1.5, focus: CGPoint(x: 0.1, y: 0.1))
        XCTAssertEqual(near.width, portrait.width / 1.5, accuracy: 0.01)
        XCTAssertLessThanOrEqual(near.minY, g.contentRect.minY)
        XCTAssertGreaterThanOrEqual(near.maxY, g.contentRect.maxY)
        let close = g.zoomedView(scale: 4, focus: CGPoint(x: 0.1, y: 0.1))
        XCTAssertGreaterThanOrEqual(close.minX, g.contentRect.minX - 0.01)
        XCTAssertGreaterThanOrEqual(close.minY, g.contentRect.minY - 0.01)
    }

    func testUltrawideFitsInLandscape() {
        let g = ScreenGeometry(contentSize: CGSize(width: 3440, height: 1440), output: out, style: FrameStyle())
        XCTAssertFalse(g.followsCursor)
    }

    func testAutoZoomClustersClicks() {
        let clicks: [(t: Double, point: CGPoint)] = [
            (3, CGPoint(x: 0.2, y: 0.2)), (4, CGPoint(x: 0.22, y: 0.25)), (5.5, CGPoint(x: 0.25, y: 0.2)),
            (15, CGPoint(x: 0.8, y: 0.8)),
            (15.5, CGPoint(x: 0.1, y: 0.9)),
            (25, CGPoint(x: 0.5, y: 0.5)),
        ]
        let blocks = AutoZoom.suggest(clicks: clicks, duration: 30)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1].focus.x, 0.8, accuracy: 0.001)
        XCTAssertEqual(blocks[0].start, 2.2, accuracy: 0.001)
        XCTAssertEqual(blocks[0].end, 7.3, accuracy: 0.001)
        XCTAssertEqual(blocks[0].focus.x, 0.2233, accuracy: 0.001)
        XCTAssertTrue(blocks.allSatisfy(\.isAuto))
        for (a, b) in zip(blocks, blocks.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start) }
    }

    func testProjectRoundTrips() throws {
        var p = project()
        p.cameraBlocks = [CameraBlock(start: 1, end: 2, layout: .centre(coverage: 0.6)),
                          CameraBlock(start: 3, end: 4, layout: .corner(.topLeft, .portrait, .large))]
        p.zoomBlocks = [ZoomBlock(start: 1, end: 3)]
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data), p)
    }

    func testStyleDecodesWithMissingKeys() throws {
        let style = try JSONDecoder().decode(FrameStyle.self, from: Data(#"{"padding": 0.1}"#.utf8))
        XCTAssertEqual(style.padding, 0.1)
        XCTAssertEqual(style.zoomTransitionDuration, FrameStyle().zoomTransitionDuration)
    }

    // MARK: - Framing

    func testNoPaddingFillsTheFrameExactlyWithAutoAspect() {
        let content = CGSize(width: 3456, height: 2234)
        let output = OutputAspect.auto.size(shortSide: 1080, source: content)
        XCTAssertEqual(output.height, 1080)
        XCTAssertEqual(Int(output.width) % 2, 0)
        XCTAssertEqual(output.width / output.height, content.width / content.height, accuracy: 0.002)
        var style = FrameStyle()
        style.padding = 0
        let g = ScreenGeometry(contentSize: content, output: output, style: style)
        XCTAssertEqual(g.contentRect.minX, 0, accuracy: 1)
        XCTAssertEqual(g.contentRect.minY, 0, accuracy: 1)
        XCTAssertEqual(g.contentRect.width, output.width, accuracy: 1)
        XCTAssertEqual(g.contentRect.height, output.height, accuracy: 1)
        XCTAssertEqual(style.effectiveScreenCornerRadius, 0)
        XCTAssertEqual(style.effectiveShadow, 0)
    }

    func testNoPaddingInAnotherAspectFitsWithoutCropping() {
        var style = FrameStyle()
        style.padding = 0
        let g = ScreenGeometry(contentSize: CGSize(width: 3456, height: 2234), output: out, style: style)
        XCTAssertTrue(CGRect(origin: .zero, size: out).insetBy(dx: -0.5, dy: -0.5).contains(g.contentRect))
        XCTAssertEqual(g.contentRect.height, out.height, accuracy: 0.5)
    }

    func testPaddingChangesMoveTheFrameContinuously() {
        var style = FrameStyle()
        var last: CGRect?
        for i in 0 ... 300 {
            style.padding = 0.15 * Double(i) / 300
            let r = ScreenGeometry(contentSize: CGSize(width: 3456, height: 2234), output: out, style: style).contentRect
            if let last {
                XCTAssertLessThan(abs(r.width - last.width), 8, "padding \(style.padding)")
                XCTAssertLessThan(abs(r.minY - last.minY), 8, "padding \(style.padding)")
            }
            last = r
        }
    }

    func testOldFullScreenProjectsOpenWithNoPadding() throws {
        let style = try JSONDecoder().decode(FrameStyle.self, from: Data(#"{"padding": 0.1, "fullScreen": true}"#.utf8))
        XCTAssertEqual(style.padding, 0)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as! [String: Any]
        XCTAssertNil(saved["fullScreen"])
    }
}
