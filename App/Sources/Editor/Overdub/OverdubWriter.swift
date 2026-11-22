//
//  OverdubWriter.swift
//  Slice
//
//  Created by rit3zh CX on 10/24/26.
//

import AVFoundation
import SliceCore

/// Writes a camera (and optionally a mic) recorded over a take that's already there, on the take's own clock: file
/// time zero is the take's start, though recording began at `from` into it. Samples come in on the host clock.
final class OverdubWriter {
    let cameraURL: URL
    let micURL: URL?
    /// Host time of the take's start, where both files begin.
    private let origin: CMTime
    /// Host time playback reached `from`; nothing earlier is kept.
    private let begin: CMTime
    private let camera: AVAssetWriter
    private var cameraInput: AVAssetWriterInput?
    private let mic: AudioTrackWriter?

    init(cameraURL: URL, micURL: URL?, begin: CMTime, from: Double) throws {
        self.cameraURL = cameraURL
        self.micURL = micURL
        self.begin = begin
        origin = begin - CMTime(seconds: from, preferredTimescale: 600)
        camera = try AVAssetWriter(outputURL: cameraURL, fileType: .mov)
        camera.movieFragmentInterval = ProjectBundle.fragmentInterval
        mic = try micURL.map { try AudioTrackWriter(url: $0, channels: 1) }
    }

    func appendCamera(_ sample: CMSampleBuffer) {
        guard CMSampleBufferGetPresentationTimeStamp(sample) >= begin else { return }
        if cameraInput == nil {
            guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            // macOS 26 rejects `AVVideoQualityKey` for H.264 (it raises from AVAssetWriterInput), so the
            // camera track asks for a bitrate instead: ~3 bits per pixel per second.
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: dims.width, AVVideoHeightKey: dims.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(dims.width) * Int(dims.height) * 3],
            ])
            input.expectsMediaDataInRealTime = true
            camera.add(input)
            guard camera.startWriting() else { return }
            camera.startSession(atSourceTime: origin)
            cameraInput = input
            // The first frame also stands at the take's start, so the track spans the take from zero (the part
            // before `from` is trimmed off the timeline anyway).
            if let held = Self.retimed(sample, to: origin) { append(held) }
        }
        append(sample)
    }

    func appendMic(_ sample: CMSampleBuffer) {
        guard CMSampleBufferGetPresentationTimeStamp(sample) >= begin else { return }
        mic?.append(sample, start: origin)
    }

    private func append(_ sample: CMSampleBuffer) {
        guard let input = cameraInput, input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    /// Whether each file was written; a failed one is removed.
    func finish(at stop: CMTime) async -> (camera: Bool, mic: Bool) {
        let micDone = await mic?.finish(at: stop) ?? false
        var cameraDone = false
        if let input = cameraInput, camera.status == .writing {
            input.markAsFinished()
            camera.endSession(atSourceTime: stop)
            await camera.finishWriting()
            cameraDone = camera.status == .completed
        } else {
            camera.cancelWriting()
        }
        if !cameraDone { try? FileManager.default.removeItem(at: cameraURL) }
        if !micDone, let micURL { try? FileManager.default.removeItem(at: micURL) }
        return (cameraDone, micDone)
    }

    func discard() {
        camera.cancelWriting()
        mic?.cancel()
        try? FileManager.default.removeItem(at: cameraURL)
        if let micURL { try? FileManager.default.removeItem(at: micURL) }
    }

    private static func retimed(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        guard let buffer = CMSampleBufferGetImageBuffer(sample), let fmt = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &copy)
        return copy
    }
}
