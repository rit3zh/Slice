//
//  Device3DTests+Island.swift
//  SliceCoreTests
//
//  Created by rit3zh CX on 10/29/26.
//

import CoreImage
@testable import SliceCore
import XCTest

extension Device3DTests {
    func testEveryPhonesDynamicIslandSwitchesOff() throws {
        XCTAssertTrue(try JSONDecoder().decode(Device3DSettings.self, from: Data("{}".utf8)).dynamicIsland, "on unless switched off")
        var off = Device3DSettings()
        off.dynamicIsland = false
        XCTAssertFalse(try JSONDecoder().decode(Device3DSettings.self, from: JSONEncoder().encode(off)).dynamicIsland)

        let size = CGSize(width: 450, height: 750), whole = CGRect(origin: .zero, size: size)
        let ctx = CIContext()
        for model in Device3DModel.models(.phone) {
            let aspect = try XCTUnwrap(Device3DRenderer.shared.displayAspect(for: model), model.label)
            let light = CIImage(color: CIColor(red: 0.85, green: 0.88, blue: 0.95)).cropped(to: CGRect(x: 0, y: 0, width: 1000 * aspect, height: 1000))
            func dark(_ island: Bool) throws -> Set<Int> {
                var s = Device3DSettings()
                s.model = model
                s.placement = Device3DPlacement(yaw: 0, pitch: 0)
                s.dynamicIsland = island
                let request = Device3DRequest(output: size, view: whole, fit: whole.insetBy(dx: 30, dy: 30), pose: s.pose(at: 0),
                                              settings: s, landscape: false, display: light)
                let image = try XCTUnwrap(Device3DRenderer.shared.render(request))
                let cg = try XCTUnwrap(ctx.createCGImage(image.composited(over: CIImage(color: .white).cropped(to: whole)), from: whole))
                let px = try XCTUnwrap(DeviceImportTests.pixels(cg))
                // The top middle of the phone, where an island is.
                var found = Set<Int>()
                for y in 20 ..< 160 { for x in 150 ..< 300 where px(x, y).x < 0.25 { found.insert(y * 1000 + x) } }
                return found
            }
            let on = try dark(true), gone = try dark(false)
            XCTAssertGreaterThan(on.subtracting(gone).count, 150, "\(model.label): switched off, the island's place shows the recording")
            XCTAssertLessThan(gone.subtracting(on).count, 20, "\(model.label): and nothing dark turns up in its place")
        }
    }

    func testIslandResizesAndMovesOverTheRecordingsOwn() throws {
        var custom = Device3DSettings()
        custom.islandSize = 1.4
        custom.islandOffset = 0.5
        let decoded = try JSONDecoder().decode(Device3DSettings.self, from: JSONEncoder().encode(custom))
        XCTAssertEqual(decoded.islandSize, 1.4)
        XCTAssertEqual(decoded.islandOffset, 0.5)

        let size = CGSize(width: 450, height: 750), whole = CGRect(origin: .zero, size: size)
        let ctx = CIContext()
        for model in Device3DModel.models(.phone) {
            let aspect = try XCTUnwrap(Device3DRenderer.shared.displayAspect(for: model), model.label)
            let light = CIImage(color: CIColor(red: 0.85, green: 0.88, blue: 0.95)).cropped(to: CGRect(x: 0, y: 0, width: 1000 * aspect, height: 1000))
            func dark(size islandSize: Double, offset: Double) throws -> (count: Int, lowest: Int) {
                var s = Device3DSettings()
                s.model = model
                s.placement = Device3DPlacement(yaw: 0, pitch: 0)
                s.islandSize = islandSize
                s.islandOffset = offset
                let request = Device3DRequest(output: size, view: whole, fit: whole.insetBy(dx: 30, dy: 30), pose: s.pose(at: 0),
                                              settings: s, landscape: false, display: light)
                let image = try XCTUnwrap(Device3DRenderer.shared.render(request))
                let cg = try XCTUnwrap(ctx.createCGImage(image.composited(over: CIImage(color: .white).cropped(to: whole)), from: whole))
                let px = try XCTUnwrap(DeviceImportTests.pixels(cg))
                var count = 0, lowest = 0
                // Below the bezel, in the top middle of the display.
                for y in 45 ..< 160 { for x in 150 ..< 300 where px(x, y).x < 0.25 { count += 1; lowest = max(lowest, y) } }
                return (count, lowest)
            }
            let standard = try dark(size: 1, offset: 0)
            XCTAssertGreaterThan(try dark(size: 1.4, offset: 0).count, standard.count + 100, "\(model.label): a bigger island covers more")
            XCTAssertGreaterThan(try dark(size: 1, offset: 1).lowest, standard.lowest + 3, "\(model.label): moved down, it sits lower")
        }
    }

    func testNoHairlineUnderTheBezel() throws {
        let size = CGSize(width: 1800, height: 3000), whole = CGRect(origin: .zero, size: size)
        let ctx = CIContext()
        for model in Device3DModel.models(.phone) {
            let aspect = try XCTUnwrap(Device3DRenderer.shared.displayAspect(for: model), model.label)
            let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 1000 * aspect, height: 1000))
            var s = Device3DSettings()
            s.model = model
            s.placement = Device3DPlacement(yaw: 0, pitch: 0)
            s.dynamicIsland = false
            let request = Device3DRequest(output: size, view: whole, fit: whole.insetBy(dx: 60, dy: 60), pose: s.pose(at: 0),
                                          settings: s, landscape: false, display: white)
            let image = try XCTUnwrap(Device3DRenderer.shared.render(request))
            let cg = try XCTUnwrap(ctx.createCGImage(image.composited(over: CIImage(color: .black).cropped(to: whole)), from: whole))
            let px = try XCTUnwrap(DeviceImportTests.pixels(cg))
            // Down the middle, from the first row of the recording: nothing but the recording (no earpiece sliver).
            for x in stride(from: 800, through: 1000, by: 50) {
                let first = try XCTUnwrap((30 ..< 300).first { px(x, $0).z > 0.97 && px(x, $0).y > 0.97 }, "\(model.label): the display shows")
                let dark = (first ..< first + 60).filter { px(x, $0).z < 0.9 }
                XCTAssertTrue(dark.isEmpty, "\(model.label): a dark line under the bezel at x \(x), rows \(dark)")
            }
        }
    }

    func testRecordingsOwnIslandUnderTheFramesIsPaintedOut() throws {
        // A Simulator recording in a frame: its own island, narrower and a few pixels taller, under the frame's.
        let canvas = CGRect(x: 0, y: 0, width: 1400, height: 2800)
        let light = CIImage(color: CIColor(red: 0.93, green: 0.93, blue: 0.93)).cropped(to: canvas)
        let frameIsland = CGRect(x: 515, y: 2580, width: 377, height: 110)
        let ownIsland = CGRect(x: 600, y: 2575, width: 200, height: 120)
        let picture = CIImage(color: .black).cropped(to: frameIsland)
            .composited(over: CIImage(color: .black).cropped(to: ownIsland))
            .composited(over: light)
        let painted = FrameRenderer().paintingOut(frameIsland, of: picture)
        let region = frameIsland.insetBy(dx: -30, dy: -30)
        let cg = try XCTUnwrap(CIContext().createCGImage(painted, from: region))
        let px = try XCTUnwrap(DeviceImportTests.pixels(cg))
        var dark = 0
        for y in 0 ..< Int(region.height) { for x in 0 ..< Int(region.width) where px(x, y).x < 0.8 { dark += 1 } }
        XCTAssertEqual(dark, 0, "nothing of either island is left")
    }
}
