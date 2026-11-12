//
//  DeviceVideoImporter.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/29/26.
//

import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

/// Screen recordings made outside Slice (the Simulator's, an iPhone's own) taken in as device takes: the frame drawn
/// around every frame of the video just as recording a device does, so the flat mockup, the 3D phone and export treat
/// them like any take recorded through Slice.
public enum DeviceVideoImporter {
    public enum Failure: LocalizedError {
        case unreadable(String)
        case noFrame

        public var errorDescription: String? {
            switch self {
            case let .unreadable(name): "\(name) couldn't be read."
            case .noFrame: "The device frame couldn't be drawn."
            }
        }
    }

    /// How far a video's shape can be from a screen's and still be taken for it: iPhones save their own screen
    /// recordings a little smaller than the screen, rounded to even pixels.
    static let aspectTolerance: CGFloat = 0.012

    /// The iPhone a video is a screen recording of, going by its shape: its exact screen size, or else the newest
    /// iPhone whose screen has the same shape. Nil for anything else (a Mac recording, a camera video).
    public static func phone(forVideo size: CGSize) -> DeviceModel? {
        guard size.width > 0, size.height > 0 else { return nil }
        let portrait = CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
        if let exact = DeviceRegistry.known.last(where: { $0.screenPixels == portrait }) { return exact }
        let aspect = portrait.width / portrait.height
        // A 16:9 iPhone SE screen is every portrait phone video's shape: it counts only at its exact size.
        let shaped = DeviceRegistry.known.filter { $0.pointScale > 2 }.map { m -> (DeviceModel, CGFloat) in
            (m, abs(log(m.screenPixels.width / m.screenPixels.height / aspect)))
        }
        guard let best = shaped.filter({ $0.1 < aspectTolerance }).min(by: { $0.1 < $1.1 })?.1 else { return nil }
        return shaped.last { abs($0.1 - best) < 1e-4 }?.0
    }

    /// Takes in `source` as a recording of `phone`: drawn in `frame`, or as it is without one.
    public static func importVideo(_ source: URL, into bundle: ProjectBundle, phone: DeviceModel, frame: DeviceFrameDefinition?,
                                   progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Clip {
        guard let frame, !frame.isFrameless else {
            var clip = try await ClipImporter.importVideo(source, into: bundle)
            clip.device = RecordedDevice(name: phone.name, identifier: phone.identifier, frame: nil, color: nil,
                                         screen: CGRect(x: 0, y: 0, width: 1, height: 1))
            return clip
        }
        let framing = try await Framing(source, in: frame)

        let id = UUID()
        let (dir, rel) = try bundle.makeClipFolder(id: id)
        do {
            try await framing.write(to: dir.appendingPathComponent("screen.mov"), progress: progress)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error is CancellationError ? error : Failure.unreadable(source.lastPathComponent)
        }
        var clip = Clip(id: id, screenFile: "\(rel)/screen.mov", micFile: nil, duration: framing.duration, screenPixelSize: framing.size,
                        captureRect: .zero)
            .withScreenAudio(try await ClipImporter.audio(of: framing.asset, into: dir, relative: rel))
        clip.device = RecordedDevice(name: phone.name, identifier: phone.identifier, frame: frame.model, color: frame.color.rawValue,
                                     screen: framing.layout.screenRect, cutout: framing.cutout)
        return clip
    }

    /// A video made ready to draw into a frame.
    struct Framing {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let duration: Double
        let layout: DeviceLayout
        let textures: DeviceFrameTextures
        let renderer: DeviceSurfaceRenderer
        /// The frame's island or notch, unless the recording has its own there.
        let cutout: CGRect?

        var size: CGSize { renderer.size }

        init(_ source: URL, in frame: DeviceFrameDefinition) async throws {
            asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ClipImporter.Failure.noVideo(source.lastPathComponent)
            }
            self.track = track
            duration = try await asset.load(.duration).seconds
            layout = DeviceLayout(frame: frame, streamSize: try await ClipImporter.videoSize(of: source))
            // A recording with an island of its own (an app that animates it, say) keeps it: the frame's would cover it for
            // good, and the 3D phone would paint it out.
            let ownIsland = await hasOwnIsland(asset, duration: duration, layout: layout)
            cutout = ownIsland ? nil : layout.cutoutRect
            guard let compositor = DeviceCompositor.shared,
                  let textures = try? compositor.textures(for: frame, withoutCutout: ownIsland) else { throw Failure.noFrame }
            self.textures = textures
            guard let renderer = DeviceSurfaceRenderer(compositor: compositor, size: layout.canvas) else { throw Failure.noFrame }
            self.renderer = renderer
        }

        func write(to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
            let (renderer, textures, layout) = (renderer, textures, layout)
            try await bake(asset, track: track, duration: duration, into: url,
                           draw: { renderer.renderNow(screen: $0, frame: textures, layout: layout) }, size: renderer.size,
                           progress: progress)
        }
    }

    /// Whether the recording shows an island of its own where the frame draws one, going by a few frames through it.
    static func hasOwnIsland(_ asset: AVURLAsset, duration: Double, layout: DeviceLayout) async -> Bool {
        guard layout.cutoutRect != nil, duration > 0 else { return false }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        var votes: [Bool] = []
        for k in 0 ..< 5 {
            let t = CMTime(seconds: duration * (Double(k) + 0.5) / 5, preferredTimescale: 600)
            guard let image = try? await generator.image(at: t).image, let vote = showsIsland(image, layout: layout) else { continue }
            votes.append(vote)
        }
        return votes.filter { $0 }.count * 2 > votes.count
    }

    /// One frame's say: dark in the middle of where the frame's island goes, with a lighter status bar either side.
    /// Nil when it can't tell (a dark status bar, or something across it).
    static func showsIsland(_ image: CGImage, layout: DeviceLayout) -> Bool? {
        guard let c = layout.cutoutRect, let stream = layout.streamSize, stream.width > 0, stream.height > 0 else { return nil }
        let k = CGSize(width: CGFloat(image.width) / stream.width, height: CGFloat(image.height) / stream.height)
        // A patch of the canvas (fractions) in the image's pixels, top-left origin.
        func brightness(around p: CGPoint, _ w: CGFloat, _ h: CGFloat) -> Double? {
            guard let a = layout.streamPixel(canvas: CGPoint(x: p.x - w / 2, y: p.y - h / 2)),
                  let b = layout.streamPixel(canvas: CGPoint(x: p.x + w / 2, y: p.y + h / 2)) else { return nil }
            let r = CGRect(x: min(a.x, b.x) * k.width, y: min(a.y, b.y) * k.height,
                           width: abs(b.x - a.x) * k.width, height: abs(b.y - a.y) * k.height).integral
            return meanBrightness(image, in: r)
        }
        // Lengthwise along the island, whichever way the phone is held; one island-height out either side.
        let across = c.width >= c.height
        let reach = across ? c.height : c.width
        let side = reach * 0.4
        let offset = across ? CGPoint(x: c.width / 2 + reach, y: 0) : CGPoint(x: 0, y: c.height / 2 + reach)
        let mid = CGPoint(x: c.midX, y: c.midY)
        guard let centre = brightness(around: mid, c.width * 0.4, c.height * 0.4),
              let before = brightness(around: CGPoint(x: mid.x - offset.x, y: mid.y - offset.y), side, side),
              let after = brightness(around: CGPoint(x: mid.x + offset.x, y: mid.y + offset.y), side, side),
              before > 0.3, after > 0.3 else { return nil }
        return centre < 0.12
    }

    /// Average brightness of `rect` (pixels, top-left origin) of `image`, 0 to 1.
    private static func meanBrightness(_ image: CGImage, in rect: CGRect) -> Double? {
        let r = rect.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width >= 1, r.height >= 1, let crop = image.cropping(to: r) else { return nil }
        let w = crop.width, h = crop.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var sum = 0.0
        for i in 0 ..< w * h { sum += 0.2126 * Double(data[i * 4]) + 0.7152 * Double(data[i * 4 + 1]) + 0.0722 * Double(data[i * 4 + 2]) }
        return sum / Double(w * h) / 255
    }

    /// Reads every frame of `track`, draws it, and writes the result with its see-through surround, at the times the
    /// frames had (a Simulator recording only has frames where the screen changed).
    private static func bake(_ asset: AVURLAsset, track: AVAssetTrack, duration: Double, into url: URL,
                             draw: @escaping (CVPixelBuffer) -> CVPixelBuffer?, size: CGSize,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let reader = try AVAssetReader(asset: asset)
        let pixels: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        let output: AVAssetReaderOutput
        if try await track.load(.preferredTransform).isIdentity {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: pixels)
        } else {
            // Turned as it plays: read through a composition, which stands it the way it shows.
            let composed = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: pixels)
            composed.videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: asset)
            output = composed
        }
        output.alwaysCopiesSampleData = false
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let fps = try await track.load(.nominalFrameRate)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoQualityKey: 0.9,
                kVTCompressionPropertyKey_TargetQualityForAlpha as String: 0.9,
                AVVideoExpectedSourceFrameRateKey: fps > 0 ? Int(fps.rounded()) : 60,
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? Failure.noFrame }
        writer.startSession(atSourceTime: .zero)

        let pump = Pump(input: input, output: output, adaptor: adaptor, draw: draw)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "Slice.deviceImport")) {
                pump.run(duration: duration, progress: progress) { done.resume() }
            }
        }
        if pump.failed || reader.status == .failed {
            reader.cancelReading()
            writer.cancelWriting()
            throw reader.error ?? writer.error ?? Failure.noFrame
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.noFrame }
    }
}

/// Moves frames from the reader, through the frame, to the writer, on the writer's queue only.
private final class Pump: @unchecked Sendable {
    let input: AVAssetWriterInput
    let output: AVAssetReaderOutput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let draw: (CVPixelBuffer) -> CVPixelBuffer?
    private(set) var failed = false
    private var finished = false

    init(input: AVAssetWriterInput, output: AVAssetReaderOutput, adaptor: AVAssetWriterInputPixelBufferAdaptor,
         draw: @escaping (CVPixelBuffer) -> CVPixelBuffer?) {
        self.input = input
        self.output = output
        self.adaptor = adaptor
        self.draw = draw
    }

    func run(duration: Double, progress: (Double) -> Void, done: () -> Void) {
        while !finished, input.isReadyForMoreMediaData {
            guard !failed, let sample = output.copyNextSampleBuffer() else {
                finished = true
                input.markAsFinished()
                done()
                return
            }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let framed = draw(buffer), adaptor.append(framed, withPresentationTime: pts) else {
                failed = true
                continue
            }
            if duration > 0 { progress(min(max(pts.seconds / duration, 0), 1)) }
        }
    }
}
