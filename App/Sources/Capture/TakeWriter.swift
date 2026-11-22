//
//  TakeWriter.swift
//  Slice
//
//  Created by rit3zh CX on 10/12/26.
//

import AppKit
import AVFoundation
import SliceCore
import VideoToolbox

final class TakeWriter {
    let id: UUID
    let relative: String
    let screenSize: CGSize
    private let screen: AVAssetWriter
    private let screenInput: AVAssetWriterInput
    private let camera: AVAssetWriter?
    private var cameraInput: AVAssetWriterInput?
    private let mic: AudioTrackWriter?
    private let screenAudio: AudioTrackWriter?
    private let fps: Int
    private var pacer: FramePacer?
    private let device: RecordedDevice?
    private(set) var startTime: CMTime?
    private var lastScreen: CMSampleBuffer?
    private var heldScreen: CMSampleBuffer?
    private var refusedFrames = 0
    private var cameraStarted = false
    /// Webcam frames are held one frame so a single bad frame (some USB cameras send them) can be spotted and dropped.
    private var pendingCamera: (sample: CMSampleBuffer, thumb: [Float])?
    private var previousCameraThumb: [Float]?
    let analysis: LiveTakeAnalyzer
    private let micLevels = LiveAudioLevels()
    private let screenAudioLevels = LiveAudioLevels()
    /// Whether the mic recorded only silence, known once the take is finished (nil without a mic).
    private(set) var micSilent: Bool?

    init(id: UUID, dir: URL, relative: String, screenSize: CGSize, fps: Int, pacer: FramePacer?, hasCamera: Bool,
         hasMic: Bool, hasScreenAudio: Bool, alpha: Bool = false, device: RecordedDevice? = nil, pointSize: CGSize) throws {
        self.id = id
        self.relative = relative
        self.screenSize = screenSize
        self.fps = fps
        self.pacer = pacer
        self.device = device
        screen = try AVAssetWriter(outputURL: dir.appendingPathComponent("screen.mov"), fileType: .mov)
        screen.movieFragmentInterval = ProjectBundle.fragmentInterval
        var compression: [String: Any] = [
            AVVideoQualityKey: 0.9,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoAllowFrameReorderingKey: false,
            // HEVC rejects a keyframe interval given as a duration: AVAssetWriterInput raises
            // "Compression property MaxKeyFrameIntervalDuration is not supported for video codec type hvc1"
            // straight out of its initialiser. Swift can't catch that, so the take died at the countdown.
            // A keyframe a second, counted in frames, is accepted.
            AVVideoMaxKeyFrameIntervalKey: max(fps, 1),
        ]
        if alpha { compression[kVTCompressionPropertyKey_TargetQualityForAlpha as String] = 0.9 }
        screenInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: alpha ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc,
            AVVideoWidthKey: screenSize.width, AVVideoHeightKey: screenSize.height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        screenInput.expectsMediaDataInRealTime = true
        screen.add(screenInput)
        camera = hasCamera ? try AVAssetWriter(outputURL: dir.appendingPathComponent("camera.mov"), fileType: .mov) : nil
        camera?.movieFragmentInterval = ProjectBundle.fragmentInterval
        mic = hasMic ? try AudioTrackWriter(url: dir.appendingPathComponent("mic.m4a"), channels: 1) : nil
        screenAudio = hasScreenAudio ? try AudioTrackWriter(url: dir.appendingPathComponent("screen-audio.m4a"), channels: 2) : nil
        analysis = LiveTakeAnalyzer(folder: dir, pointSize: pointSize)
        mic?.onWrite = { [micLevels] in micLevels.add($0) }
        screenAudio?.onWrite = { [screenAudioLevels] in screenAudioLevels.add($0) }
    }

    func begin(at time: CMTime, with frame: CMSampleBuffer?) {
        guard let frame, let copy = Self.retimed(frame, to: time) else { return }
        guard screen.startWriting() else { return }
        screen.startSession(atSourceTime: time)
        startTime = time
        analysis.start(at: time.seconds)
        if screenInput.isReadyForMoreMediaData, screenInput.append(copy), let buffer = CMSampleBufferGetImageBuffer(copy) {
            analysis.screenFrame(buffer, at: time.seconds)
        }
        lastScreen = copy
    }

    func appendScreen(_ sample: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        if let start = startTime {
            guard pts > start else { return }
        } else {
            guard screen.startWriting() else { return }
            screen.startSession(atSourceTime: pts)
            startTime = pts
            analysis.start(at: pts.seconds)
        }
        lastScreen = sample
        switch pacer?.offer(pts.seconds) ?? .keep {
        case .hold:
            heldScreen = sample
            return
        case .keepHeldAndThis:
            if let heldScreen { writeScreen(heldScreen) }
        case .keep:
            break
        }
        heldScreen = nil
        writeScreen(sample)
    }

    private func writeScreen(_ sample: CMSampleBuffer) {
        if screenInput.isReadyForMoreMediaData, screenInput.append(sample) {
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                analysis.screenFrame(buffer, at: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
            }
            return
        }
        refusedFrames += 1
    }

    private static func retimed(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &fmt)
        guard let fmt else { return nil }
        var copy: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: fmt,
                                                 sampleTiming: &timing, sampleBufferOut: &copy)
        return copy
    }

    func appendCamera(_ sample: CMSampleBuffer) {
        guard let start = startTime, camera != nil, CMSampleBufferGetPresentationTimeStamp(sample) >= start,
              let pb = CMSampleBufferGetImageBuffer(sample) else { return }
        let thumb = CameraGlitchDetector.thumbnail(pb)
        if let pending = pendingCamera {
            if let prev = previousCameraThumb, CameraGlitchDetector.isGlitch(previous: prev, frame: pending.thumb, next: thumb) {
            } else {
                writeCamera(pending.sample, thumb: pending.thumb)
                previousCameraThumb = pending.thumb
            }
        }
        pendingCamera = (sample, thumb)
    }

    private func writeCamera(_ sample: CMSampleBuffer, thumb: [Float]) {
        guard let start = startTime, let camera else { return }
        if !cameraStarted {
            guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return }
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            // macOS 26 rejects `AVVideoQualityKey` for H.264 ("Compression property Quality is not
            // supported for video codec type avc1") and raises it out of the initialiser, on the capture
            // queue, which takes the whole app down. A bitrate is accepted: ~3 bits per pixel per second.
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: dims.width, AVVideoHeightKey: dims.height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(dims.width) * Int(dims.height) * 3],
            ])
            input.expectsMediaDataInRealTime = true
            camera.add(input)
            guard camera.startWriting() else { return }
            camera.startSession(atSourceTime: start)
            cameraInput = input
            cameraStarted = true
        }
        if let input = cameraInput, input.isReadyForMoreMediaData, input.append(sample) {
            analysis.cameraFrame(thumb, at: CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
    }

    func appendMic(_ sample: CMSampleBuffer) {
        guard let start = startTime else { return }
        mic?.append(sample, start: start)
    }

    func appendScreenAudio(_ sample: CMSampleBuffer) {
        guard let start = startTime else { return }
        screenAudio?.append(sample, start: start)
    }

    var cursorURL: URL { screen.outputURL.deletingLastPathComponent().appendingPathComponent("cursor.json") }

    /// The clip this take becomes if every file is written: what a take cut off is put back as.
    func planned(captureRect: CGRect) -> Clip {
        var clip = Clip(id: id, screenFile: "\(relative)/screen.mov", cameraFile: camera == nil ? nil : "\(relative)/camera.mov",
                        micFile: mic == nil ? nil : "\(relative)/mic.m4a", cursorFile: "\(relative)/cursor.json", duration: 0,
                        screenPixelSize: screenSize, captureRect: captureRect, cursorInVideo: false)
            .withScreenAudio(screenAudio == nil ? nil : "\(relative)/screen-audio.m4a")
            .withFrameRate(fps)
        clip.device = device
        return clip
    }

    /// Stops every file without finishing it and removes the take's folder.
    func discard() {
        screen.cancelWriting()
        camera?.cancelWriting()
        mic?.cancel()
        screenAudio?.cancel()
        try? FileManager.default.removeItem(at: screen.outputURL.deletingLastPathComponent())
    }

    func finish(at stop: CMTime, captureRect: CGRect, cursor: CursorLogger.Result) async -> Clip? {
        guard let start = startTime, stop > start else {
            screen.cancelWriting()
            camera?.cancelWriting()
            mic?.cancel()
            screenAudio?.cancel()
            return nil
        }
        if let pending = pendingCamera { writeCamera(pending.sample, thumb: pending.thumb) }
        if let heldScreen { writeScreen(heldScreen) }
        if refusedFrames > 0 { log.warning("The encoder fell behind: \(self.refusedFrames) screen frames dropped") }
        // The screen only sends frames on change; repeat the last one at the end so the track spans the take.
        if let last = lastScreen, let buffer = CMSampleBufferGetImageBuffer(last) {
            let endPTS = CMTimeSubtract(stop, CMTime(value: 1, timescale: CMTimeScale(fps)))
            if endPTS > CMSampleBufferGetPresentationTimeStamp(last) {
                var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: endPTS, decodeTimeStamp: .invalid)
                var fmt: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &fmt)
                var copy: CMSampleBuffer?
                if let fmt {
                    CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: fmt,
                                                             sampleTiming: &timing, sampleBufferOut: &copy)
                }
                if let copy, screenInput.isReadyForMoreMediaData { screenInput.append(copy) }
            }
        }
        let micDone = await mic?.finish(at: stop) ?? false
        let screenAudioDone = await screenAudio?.finish(at: stop) ?? false
        for (writer, input) in [(screen, screenInput as AVAssetWriterInput?), (camera, cameraInput)] {
            guard let writer, writer.status == .writing else {
                writer?.cancelWriting()
                continue
            }
            input?.markAsFinished()
            writer.endSession(atSourceTime: stop)
            await writer.finishWriting()
        }
        try? JSONEncoder().encode(cursor.log(since: start.seconds)).write(to: cursorURL)
        guard screen.status == .completed else { return nil }

        var clip = planned(captureRect: captureRect)
        clip.duration = (stop - start).seconds
        if camera?.status != .completed { clip.cameraFile = nil }
        if !micDone { clip.micFile = nil }
        if !screenAudioDone { clip.screenAudioFile = nil }
        // Measured while recording, so the editor needn't scan the files again.
        let live = await analysis.finish(duration: (stop - start).seconds)
        if clip.hasEditableCursor { clip.hoverMoments = live.hoverMoments }
        if clip.cameraFile != nil { clip.cameraGlitches = live.cameraGlitches }
        if micDone {
            clip.speech = micLevels.speech
            micSilent = micLevels.isSilent
        } else if screenAudioDone {
            clip.speech = screenAudioLevels.speech
        }
        return clip
    }
}
