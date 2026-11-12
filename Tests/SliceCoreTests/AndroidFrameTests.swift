//
//  AndroidFrameTests.swift
//  SliceCoreTests
//
//  Created by rit3zh CX on 11/12/26.
//

import AVFoundation
import CoreImage
@testable import SliceCore
import XCTest

final class AndroidFrameTests: XCTestCase {
    static let catalog = DeviceFrameCatalog(directory: DeviceTests.framesDirectory.deletingLastPathComponent().appendingPathComponent("AndroidFrames"))
    var catalog: DeviceFrameCatalog { Self.catalog }

    /// The opening each frame was published with, in the frame image's pixels.
    private static let published: [String: CGRect] = [
        "Pixel 8": CGRect(x: 183, y: 169, width: 1145, height: 2549),
        "Pixel 8 Pro": CGRect(x: 183, y: 169, width: 1255, height: 2792),
        "Pixel 9 Pro": CGRect(x: 170, y: 142, width: 1280, height: 2856),
        "Pixel 9 Pro XL": CGRect(x: 170, y: 140, width: 1344, height: 2992),
        "Samsung Galaxy S21": CGRect(x: 200, y: 200, width: 1080, height: 2400),
    ]

    func testEveryFrameHasTheOpeningItWasPublishedWith() throws {
        XCTAssertEqual(Set(catalog.models), Set(Self.published.keys))
        for model in catalog.models {
            let expected = try XCTUnwrap(Self.published[model])
            for color in catalog.colors(for: model) {
                let d = try XCTUnwrap(try catalog.definition(model: model, color: color), "\(model) \(color.rawValue)")
                XCTAssertEqual(d.screenRect.minX, expected.minX, accuracy: 6, "\(model) \(color.rawValue)")
                XCTAssertEqual(d.screenRect.minY, expected.minY, accuracy: 6, "\(model) \(color.rawValue)")
                XCTAssertEqual(d.screenRect.width, expected.width, accuracy: 12, "\(model) \(color.rawValue)")
                XCTAssertEqual(d.screenRect.height, expected.height, accuracy: 12, "\(model) \(color.rawValue)")
                XCTAssertNotNil(d.screen.cutout, "\(model) \(color.rawValue) has a camera over the display")
                XCTAssertGreaterThan(d.screenCornerRadius, 0, "\(model) \(color.rawValue)")
            }
        }
    }

    func testRecordingsAreKnownAsAndroidByShapeOrTag() {
        func android(_ w: CGFloat, _ h: CGFloat, tagged: Bool = false) -> Bool {
            DeviceVideoImporter.androidPhone(size: CGSize(width: w, height: h), tagged: tagged, catalog: catalog) != nil
        }
        XCTAssertTrue(android(1080, 2400), "20:9")
        XCTAssertTrue(android(2400, 1080), "on its side")
        XCTAssertTrue(android(1344, 2992), "Pixel 9 Pro XL")
        XCTAssertTrue(android(720, 1600), "saved smaller than the screen")
        XCTAssertFalse(android(1179, 2556), "an iPhone's")
        XCTAssertFalse(android(1080, 2340), "an iPhone mini's size, untagged")
        XCTAssertTrue(android(1080, 2340, tagged: true), "the same size is a Galaxy's when Android says so")
        XCTAssertFalse(android(1080, 1920), "a 9:16 video")
        XCTAssertFalse(android(1080, 1920, tagged: true), "an Android phone's camera video")
        XCTAssertFalse(android(3024, 1964), "a Mac recording")
        XCTAssertFalse(android(2560, 1600), "16:10 could as well be a Mac")
    }

    func testAndroidsTagIsRead() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("android-tag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = dir.appendingPathComponent("plain.mov"), tagged = dir.appendingPathComponent("tagged.mov")
        try await ExportTests.makeMovie(url: plain, image: Device3DTests.display(CGSize(width: 108, height: 234)), duration: 0.2)
        let export = try XCTUnwrap(AVAssetExportSession(asset: AVURLAsset(url: plain), presetName: AVAssetExportPresetPassthrough))
        let item = AVMutableMetadataItem()
        item.keySpace = .quickTimeMetadata
        item.key = "com.android.version" as NSString
        item.value = "14" as NSString
        export.metadata = [item]
        try await export.export(to: tagged, as: .mov)
        let plainIsTagged = await DeviceVideoImporter.isTaggedAndroid(plain)
        let taggedIsTagged = await DeviceVideoImporter.isTaggedAndroid(tagged)
        XCTAssertFalse(plainIsTagged)
        XCTAssertTrue(taggedIsTagged)
    }

    func testFramingCanBeTurnedOffAndBackOn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("android-import-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (bundle, _) = try ProjectBundle.create(name: "Android", in: dir)
        let size = CGSize(width: 540, height: 1200)
        let source = dir.appendingPathComponent("screen-20261108.mp4")
        try await ExportTests.makeMovie(url: source, image: Device3DTests.display(size), duration: 0.5)

        let frame = try XCTUnwrap(try catalog.definition(model: "Pixel 8", color: DeviceColor("Hazel")))
        let phone = DeviceModel.android(screenPixels: size)
        let clip = try await DeviceVideoImporter.importAndroidVideo(source, into: bundle, phone: phone, frame: frame)

        let layout = DeviceLayout(frame: frame, streamSize: size)
        XCTAssertEqual(clip.device?.frame, "Pixel 8")
        XCTAssertEqual(clip.device?.color, "Hazel")
        XCTAssertEqual(clip.device?.screen, layout.screenRect)
        XCTAssertTrue(clip.isAndroid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.file(clip.screenFile).path))
        XCTAssertEqual(clip.screenPixelSize.width, (layout.canvas.width / 2).rounded(.up) * 2)

        var project = Project(name: "Android")
        project.clips = [clip]
        // On the display's own centre, and at 90% across and down it.
        let s = layout.screenRect
        project.redactions = [RedactBlock(start: 0.1, end: 0.2, rect: CGRect(x: s.midX, y: s.midY, width: s.width * 0.4, height: s.height * 0.4))]
        project.applyFraming(of: try await DeviceVideoImporter.reframed(clip, in: bundle, frame: nil))
        let off = project.clips[0]
        XCTAssertNil(off.device?.frame)
        XCTAssertEqual(off.device?.screen, CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(off.screenPixelSize, size)
        XCTAssertEqual(off.screenFile, clip.device?.unframedFile)
        XCTAssertEqual(project.redactions[0].rect.minX, 0.5, accuracy: 0.0001, "a blur stays on what it covered")
        XCTAssertEqual(project.redactions[0].rect.maxX, 0.9, accuracy: 0.0001)
        XCTAssertEqual(project.redactions[0].rect.minY, 0.5, accuracy: 0.0001)

        // Written once: going back on finds the framing already there.
        let written = try FileManager.default.attributesOfItem(atPath: bundle.file(clip.screenFile).path)[.modificationDate] as? Date
        project.applyFraming(of: try await DeviceVideoImporter.reframed(off, in: bundle, frame: frame))
        XCTAssertEqual(project.clips[0], clip)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: bundle.file(clip.screenFile).path)[.modificationDate] as? Date, written)
        XCTAssertEqual(project.redactions[0].rect.minX, s.midX, accuracy: 0.0001)
    }

    func testAndroidTakesStayOffTheThreeDIPhone() throws {
        var clip = Clip(screenFile: "a.mov", duration: 1, screenPixelSize: CGSize(width: 10, height: 20), captureRect: .zero)
        clip.device = RecordedDevice(name: "Android phone", identifier: RecordedDevice.androidIdentifier, frame: "Pixel 8", color: "Hazel")
        var settings = Device3DSettings()
        settings.model = Device3DModel.models(.phone)[0]
        XCTAssertFalse(settings.applies(to: clip))
        settings.model = Device3DModel.models(.laptop)[0]
        XCTAssertFalse(settings.applies(to: clip))
        var project = Project(name: "Android")
        project.clips = [clip]
        XCTAssertFalse(project.hasTakes(for: .phone))
    }
}
