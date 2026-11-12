//
//  MockupTests.swift
//  SliceCoreTests
//
//  Created by rit3zh CX on 11/12/26.
//

import CoreImage
import ImageIO
@testable import SliceCore
import XCTest

final class MockupTests: XCTestCase {
    private let out = CGSize(width: 1920, height: 1080)

    private func style(_ kind: MockupKind, dark: Bool = false, url: String = "") -> FrameStyle {
        var s = FrameStyle()
        s.mockup = ScreenMockup(kind: kind, dark: dark, url: url)
        return s
    }

    // MARK: - Geometry

    func testNoMockupLeavesTheGeometryAsItWas() {
        let g = ScreenGeometry(contentSize: CGSize(width: 2880, height: 1800), output: out, style: FrameStyle())
        XCTAssertNil(g.mockup)
        XCTAssertEqual(g.frameRect, g.contentRect)
        let inset = 1080 * FrameStyle().padding
        XCTAssertEqual(g.contentRect.height, 1080 - 2 * inset, accuracy: 0.001)
    }

    func testSafariSitsAboveTheRecordingAndBothFit() {
        let s = style(.safari)
        let g = ScreenGeometry(contentSize: CGSize(width: 2880, height: 1800), output: out, style: s)
        let c = g.contentRect, f = g.frameRect
        let u = max(c.width, c.height) / 1200
        XCTAssertEqual(c.minY - f.minY, 52 * u, accuracy: 0.01, "toolbar above")
        XCTAssertEqual(c.minX - f.minX, u, accuracy: 0.01)
        XCTAssertEqual(f.maxY - c.maxY, u, accuracy: 0.01)
        XCTAssertEqual(c.width / c.height, 2880 / 1800, accuracy: 0.001, "the recording keeps its shape")
        let inset = 1080 * s.padding
        XCTAssertEqual(f.height, 1080 - 2 * inset, accuracy: 0.01, "the window, not the page, fills the height")
        XCTAssertEqual(f.midX, out.width / 2, accuracy: 0.01)
        XCTAssertEqual(f.midY, out.height / 2, accuracy: 0.01)
    }

    func testMockupsAreNeverDrawnAroundAFramedDevice() {
        let g = ScreenGeometry(contentSize: CGSize(width: 1400, height: 2900), output: out, style: style(.safari), shapedByAlpha: true)
        XCTAssertNil(g.mockup)
        XCTAssertEqual(g.frameRect, g.contentRect)
    }

    func testAMockedUpRecordingFarFromTheFramesShapeIsShownWhole() {
        // A tall recording in a wide frame would otherwise be cropped to fill it, cutting the mockup off.
        let g = ScreenGeometry(contentSize: CGSize(width: 1080, height: 1920), output: out, style: style(.safariMinimal))
        XCTAssertTrue(g.isMismatched)
        XCTAssertFalse(g.followsCursor)
        XCTAssertEqual(g.fullBleedSize, out)
    }

    // MARK: - Toolbar

    func testToolbarAtItsDrawnWidthMatchesTheDrawing() {
        let bar = SafariToolbar.bar(width: 1202, minimal: false)
        XCTAssertEqual(bar, SafariToolbar.Bar(minX: 286, maxX: 952, icons: true))
        XCTAssertEqual(SafariToolbar.bar(width: 1202, minimal: true)?.icons, false)
    }

    func testNarrowToolbarDropsItsIconsAndKeepsTheBarCentred() throws {
        let bar = try XCTUnwrap(SafariToolbar.bar(width: 677, minimal: false))
        XCTAssertFalse(bar.icons)
        XCTAssertEqual((bar.minX + bar.maxX) / 2, 677 / 2, accuracy: 0.01)
        XCTAssertNil(SafariToolbar.bar(width: 200, minimal: false), "too narrow for an address bar")
    }

    func testWideToolbarCapsTheAddressBar() throws {
        let bar = try XCTUnwrap(SafariToolbar.bar(width: 2400, minimal: false))
        XCTAssertEqual(bar.maxX - bar.minX, 2400 * 0.554, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(bar.minX, 286)
        XCTAssertLessThanOrEqual(bar.maxX, 2400 - 250)
    }

    func testSVGPathReadsTheLock() {
        let box = SafariToolbar.Icons.lock.boundingBoxOfPath
        XCTAssertEqual(box.minX, 565, accuracy: 0.01)
        XCTAssertEqual(box.maxX, 573.696, accuracy: 0.01)
        XCTAssertEqual(box.minY, 19.5105, accuracy: 0.05)
        XCTAssertEqual(box.maxY, 32.0852, accuracy: 0.01)
    }

    func testSVGPathReadsRelativeCommands() {
        let box = SVGPath.parse("M10 10h20v5l-20 5z").boundingBoxOfPath
        XCTAssertEqual(box, CGRect(x: 10, y: 10, width: 20, height: 10))
    }

    // MARK: - Saving

    func testOlderProjectsOpenWithoutAMockupOrFilter() throws {
        let decoded = try JSONDecoder().decode(FrameStyle.self, from: Data(#"{"padding": 0.08}"#.utf8))
        XCTAssertEqual(decoded.mockup, ScreenMockup())
        XCTAssertEqual(decoded.cameraFilter, .none)
        XCTAssertEqual(decoded.padding, 0.08)
    }

    func testMockupAndFilterSurviveASave() throws {
        var s = style(.safari, dark: true, url: "slice.app")
        s.cameraFilter = .noir
        let back = try JSONDecoder().decode(FrameStyle.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testTheRetiredPhoneMockupOpensAsNone() throws {
        let decoded = try JSONDecoder().decode(FrameStyle.self, from: Data(#"{"mockup": {"kind": "iPhone", "dark": true}}"#.utf8))
        XCTAssertEqual(decoded.mockup.kind, .none)
    }

    func testAnUnknownFilterFromANewerVersionFallsBackToNone() throws {
        let decoded = try JSONDecoder().decode(FrameStyle.self, from: Data(#"{"cameraFilter": "glitter"}"#.utf8))
        XCTAssertEqual(decoded.cameraFilter, .none)
    }

    // MARK: - Rendering

    private func render(_ s: FrameStyle, content: CGSize = CGSize(width: 1600, height: 1000)) -> (pixel: (CGFloat, CGFloat) -> [UInt8], geometry: ScreenGeometry) {
        var p = Project(name: "Mockup")
        p.clips = [Clip(screenFile: "s.mov", duration: 5, screenPixelSize: content, captureRect: .zero)]
        p.defaultCamera = .hidden
        p.style = s
        p.style.backgroundImage = nil
        p.style.backgroundTop = RGBA(1, 0, 0)
        p.style.backgroundBottom = RGBA(1, 0, 0)
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        let renderer = FrameRenderer()
        let screen = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(origin: .zero, size: content))
        let image = renderer.render(scene: scene, time: 1, screen: screen, camera: nil)
        let height = out.height
        return ({ x, y in
            var px = [UInt8](repeating: 0, count: 4)
            renderer.context.render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: height - y - 1, width: 1, height: 1),
                                    format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return px
        }, scene.geometry(at: 1))
    }

    private func assertNear(_ px: [UInt8], _ rgb: [Int], tolerance: Int = 6, _ message: String = "", line: UInt = #line) {
        for i in 0 ..< 3 { XCTAssertEqual(Int(px[i]), rgb[i], accuracy: tolerance, "\(message) \(px)", line: line) }
    }

    func testSafariDrawsItsToolbarAboveThePage() {
        for dark in [false, true] {
            let (pixel, g) = render(style(.safari, dark: dark, url: "slice.app"))
            let c = g.contentRect, f = g.frameRect
            let u = max(c.width, c.height) / 1200
            // The toolbar between the traffic lights and the address bar, in the window's own units.
            let toolbar = pixel(f.minX + 230 * u, f.minY + 45 * u)
            assertNear(toolbar, dark ? [0x26, 0x26, 0x26] : [255, 255, 255], "toolbar")
            assertNear(pixel(f.minX + 27 * u, f.minY + 25 * u), dark ? [0x40, 0x40, 0x40] : [0xE5, 0xE5, 0xE5], "traffic light")
            assertNear(pixel(c.midX, c.midY), [0, 0, 255], "the page")
            assertNear(pixel(c.midX, c.minY + 2), [0, 0, 255], "the page meets the toolbar")
        }
    }

    func testSafariRoundsOnlyThePagesBottomCorners() {
        let (pixel, g) = render(style(.safari))
        let c = g.contentRect
        assertNear(pixel(c.minX + 3, c.minY + 3), [0, 0, 255], "square under the toolbar")
        XCTAssertLessThan(pixel(c.minX + 3, c.maxY - 3)[2], 240, "rounded at the bottom")
    }

    /// Set RENDER_OUT to a directory to also write PNGs for eyeballing.
    func testRenderMockupSamples() throws {
        let outDir = ProcessInfo.processInfo.environment["RENDER_OUT"].map { URL(fileURLWithPath: $0) }
        let samples: [(name: String, mockup: ScreenMockup, content: CGSize, aspect: OutputAspect, zoom: Double?)] = [
            ("safari", ScreenMockup(kind: .safari, url: "slice.app/download"), CGSize(width: 3024, height: 1964), .landscape16x9, nil),
            ("safari-dark", ScreenMockup(kind: .safari, dark: true, url: "slice.app"), CGSize(width: 3024, height: 1964), .landscape16x9, nil),
            ("safari-zoomed", ScreenMockup(kind: .safari, url: "slice.app"), CGSize(width: 3024, height: 1964), .landscape16x9, 1.6),
            ("minimal-tall", ScreenMockup(kind: .safariMinimal, url: "a-very-long-address.example.com/with/a/path"),
             CGSize(width: 1080, height: 1920), .landscape16x9, nil),
        ]
        for sample in samples {
            var p = Project(name: sample.name)
            p.clips = [Clip(screenFile: "s.mov", duration: 10, screenPixelSize: sample.content, captureRect: .zero)]
            p.defaultCamera = .hidden
            p.style.mockup = sample.mockup
            p.export.aspect = sample.aspect
            if let zoom = sample.zoom { p.zoomBlocks = [ZoomBlock(start: 1, end: 9, scale: zoom, focus: CGPoint(x: 0.2, y: 0.1))] }
            let output = p.outputSize(shortSide: 1080)
            let scene = RenderScene(project: p, output: output, cursor: CursorTrack(project: p, logs: [:]))
            let renderer = FrameRenderer()
            let image = renderer.render(scene: scene, time: 5, screen: RenderTests.fakeScreen(size: sample.content), camera: nil)
            let cg = try XCTUnwrap(renderer.context.createCGImage(image, from: CGRect(origin: .zero, size: output)))
            if let outDir {
                let url = outDir.appendingPathComponent("mockup-\(sample.name).png")
                let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
                CGImageDestinationAddImage(dest, cg, nil)
                XCTAssertTrue(CGImageDestinationFinalize(dest))
            }
        }
    }

    // MARK: - Camera filters

    private func colour(after filter: CameraFilter, of rgb: (CGFloat, CGFloat, CGFloat)) -> [UInt8] {
        let image = filter.apply(to: CIImage(color: CIColor(red: rgb.0, green: rgb.1, blue: rgb.2)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8)))
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: 8, height: 8))
        var px = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 4, y: 4, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return px
    }

    func testMonoAndNoirAreGrey() {
        for f in [CameraFilter.mono, .noir] {
            let px = colour(after: f, of: (0.9, 0.4, 0.2))
            XCTAssertEqual(Int(px[0]), Int(px[1]), accuracy: 2, "\(f)")
            XCTAssertEqual(Int(px[1]), Int(px[2]), accuracy: 2, "\(f)")
        }
    }

    func testWarmIsWarmerThanCool() {
        let grey = (CGFloat(0.5), CGFloat(0.5), CGFloat(0.5))
        let warm = colour(after: .warm, of: grey), cool = colour(after: .cool, of: grey)
        XCTAssertGreaterThan(Int(warm[0]), Int(warm[2]) + 10, "warm is redder than blue \(warm)")
        XCTAssertGreaterThan(Int(cool[2]), Int(cool[0]) + 10, "cool is bluer than red \(cool)")
    }

    func testEveryFilterChangesTheColourButNone() {
        let skin = (CGFloat(0.85), CGFloat(0.62), CGFloat(0.5))
        let plain = colour(after: .none, of: skin)
        for f in CameraFilter.allCases where f != .none {
            let px = colour(after: f, of: skin)
            XCTAssertGreaterThan((0 ..< 3).map { abs(Int(px[$0]) - Int(plain[$0])) }.max()!, 6, "\(f) \(px)")
        }
    }

    func testFilterIsDrawnOnTheCamera() {
        var p = Project(name: "Camera")
        p.clips = [Clip(screenFile: "s.mov", cameraFile: "c.mov", duration: 5, screenPixelSize: CGSize(width: 1600, height: 1000),
                        captureRect: .zero)]
        p.defaultCamera = .fullscreen
        p.style.cameraFilter = .mono
        let scene = RenderScene(project: p, output: out, cursor: CursorTrack(project: p, logs: [:]))
        let renderer = FrameRenderer()
        let camera = CIImage(color: CIColor(red: 0.9, green: 0.2, blue: 0.1)).cropped(to: CGRect(origin: .zero, size: out))
        let image = renderer.render(scene: scene, time: 1, screen: nil, camera: camera)
        var px = [UInt8](repeating: 0, count: 4)
        renderer.context.render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 960, y: 540, width: 1, height: 1),
                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        XCTAssertEqual(Int(px[0]), Int(px[2]), accuracy: 2, "\(px)")
    }
}
