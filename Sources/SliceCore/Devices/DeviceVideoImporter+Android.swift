//
//  DeviceVideoImporter+Android.swift
//  SliceCore
//
//  Created by rit3zh CX on 11/12/26.
//

import AVFoundation
import CoreGraphics
import Foundation

extension DeviceModel {
    /// An Android phone, known only by its screen.
    public static func android(screenPixels: CGSize) -> DeviceModel {
        let portrait = CGSize(width: min(screenPixels.width, screenPixels.height), height: max(screenPixels.width, screenPixels.height))
        return DeviceModel(identifier: RecordedDevice.androidIdentifier, name: "Android phone", screenPixels: portrait, pointScale: 3)
    }
}

extension RecordedDevice {
    public static let androidIdentifier = "android"
    public var isAndroid: Bool { identifier == Self.androidIdentifier }
}

extension Clip {
    public var isAndroid: Bool { device?.isAndroid == true }
}

extension Project {
    /// Gives a take the framing `framed` has, keeping what's placed on its picture over the same part of the display:
    /// those are fractions of the whole picture, and the display sits elsewhere in it with another frame or none.
    public mutating func applyFraming(of framed: Clip) {
        guard let i = clips.firstIndex(where: { $0.id == framed.id }) else { return }
        if let old = clips[i].device?.screen, let new = framed.device?.screen, old != new, old.width > 0, old.height > 0 {
            let start = clipStarts[i]
            let take = start ..< start + clipEditedDurations[i]
            func moved(_ p: CGPoint) -> CGPoint {
                CGPoint(x: min(max(new.minX + (p.x - old.minX) / old.width * new.width, 0), 1),
                        y: min(max(new.minY + (p.y - old.minY) / old.height * new.height, 0), 1))
            }
            for j in redactions.indices where take.contains(redactions[j].start) {
                let r = redactions[j].rect
                let a = moved(CGPoint(x: r.minX, y: r.minY)), b = moved(CGPoint(x: r.maxX, y: r.maxY))
                redactions[j].rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            }
            for j in spotlights.indices where take.contains(spotlights[j].start) { spotlights[j].center = moved(spotlights[j].center) }
            for j in zoomBlocks.indices where take.contains(zoomBlocks[j].start) {
                zoomBlocks[j].focus = moved(zoomBlocks[j].focus)
                zoomBlocks[j].endFocus = zoomBlocks[j].endFocus.map(moved)
            }
        }
        clips[i].screenFile = framed.screenFile
        clips[i].screenPixelSize = framed.screenPixelSize
        clips[i].device = framed.device
    }
}

extension DeviceVideoImporter {
    /// How far a recording known to be from Android can be from a frame's screen and still go in it, the difference
    /// cropped. Covers the common 19.5:9 and 19:9 phones, which lose under 3% off each side; 16:9 video isn't near.
    public static let androidAspectTolerance: CGFloat = 0.06

    /// The Android phone `source` is a screen recording of, or nil if it doesn't look like one.
    public static func androidPhone(forVideo source: URL, size: CGSize, catalog: DeviceFrameCatalog) async -> DeviceModel? {
        androidPhone(size: size, tagged: await isTaggedAndroid(source), catalog: catalog)
    }

    /// Android's own tag settles it. Without one it's the shape: a phone's that no iPhone has (20:9, usually), since
    /// an iPhone's own recording of the same size is by far the likelier.
    static func androidPhone(size: CGSize, tagged: Bool, catalog: DeviceFrameCatalog) -> DeviceModel? {
        guard size.width > 0, size.height > 0, tagged || phone(forVideo: size) == nil else { return nil }
        let phone = DeviceModel.android(screenPixels: size)
        let tolerance = tagged ? androidAspectTolerance : DeviceFrameCatalog.standInAspectTolerance
        return catalog.frame(for: phone, aspectTolerance: tolerance) == nil ? nil : phone
    }

    /// Whether the file carries the `com.android.*` metadata Android's recorders write.
    static func isTaggedAndroid(_ source: URL) async -> Bool {
        guard let items = try? await AVURLAsset(url: source).load(.metadata) else { return false }
        return items.contains { ($0.key as? String)?.hasPrefix("com.android.") == true }
    }

    /// Takes in `source` as a recording of an Android `phone`, keeping it as it came so its frame can change later.
    public static func importAndroidVideo(_ source: URL, into bundle: ProjectBundle, phone: DeviceModel, frame: DeviceFrameDefinition?,
                                          progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Clip {
        var clip = try await ClipImporter.importVideo(source, into: bundle)
        clip.device = RecordedDevice(name: phone.name, identifier: phone.identifier, frame: nil, color: nil,
                                     screen: CGRect(x: 0, y: 0, width: 1, height: 1), unframedFile: clip.screenFile)
        do {
            return try await reframed(clip, in: bundle, frame: frame, progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: bundle.file(clip.screenFile).deletingLastPathComponent())
            throw error
        }
    }

    /// `clip` in `frame`, or as it came with none. Each framing is kept in the take's folder, so undo still finds it
    /// and going back to it is immediate.
    public static func reframed(_ clip: Clip, in bundle: ProjectBundle, frame: DeviceFrameDefinition?,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Clip {
        guard var device = clip.device, let unframed = device.unframedFile else { return clip }
        var clip = clip
        let source = bundle.file(unframed)
        guard let frame, !frame.isFrameless else {
            clip.screenFile = unframed
            clip.screenPixelSize = try await ClipImporter.videoSize(of: source)
            device.frame = nil
            device.color = nil
            device.screen = CGRect(x: 0, y: 0, width: 1, height: 1)
            device.cutout = nil
            clip.device = device
            return clip
        }
        let framing = try await Framing(source, in: frame)
        let name = "framed \(frame.model) - \(frame.color.rawValue).mov"
        let folder = source.deletingLastPathComponent()
        let target = folder.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: target.path) {
            // Finished files only under the real name, so a cancelled framing is never taken for one.
            let partial = folder.appendingPathComponent("framing-\(UUID().uuidString).mov")
            do {
                try await framing.write(to: partial, progress: progress)
                try FileManager.default.moveItem(at: partial, to: target)
            } catch {
                try? FileManager.default.removeItem(at: partial)
                throw error is CancellationError ? error : Failure.unreadable(source.lastPathComponent)
            }
        }
        clip.screenFile = (unframed as NSString).deletingLastPathComponent + "/" + name
        clip.screenPixelSize = framing.size
        device.frame = frame.model
        device.color = frame.color.rawValue
        device.screen = framing.layout.screenRect
        device.cutout = framing.cutout
        clip.device = device
        return clip
    }
}
