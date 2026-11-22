//
//  Exporter.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/8/26.
//

import AVFoundation
import CoreImage

public enum Exporter {
    public enum Failure: LocalizedError {
        case failed(String)
        public var errorDescription: String? { if case let .failed(m) = self { m } else { nil } }
    }

    public static func export(project: Project, bundle: ProjectBundle, cursor: CursorTrack, captions: [Caption] = [], to url: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        let settings = project.export
        if settings.format == .gif {
            return try await exportGIF(project: project, bundle: bundle, cursor: cursor, captions: captions, to: url,
                                       progress: progress)
        }
        let size = project.renderSize
        let built = try await build(project: project, bundle: bundle, cursor: cursor, captions: captions, size: size,
                                    fps: settings.fps)
        let total = max(project.duration, 0.001)

        let reader = try AVAssetReader(asset: built.composition)
        let videoOut = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await built.composition.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()])
        videoOut.videoComposition = built.videoComposition
        videoOut.alwaysCopiesSampleData = false
        reader.add(videoOut)
        let audioTracks = try await built.composition.loadTracks(withMediaType: .audio)
        var audioOut: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let out = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
            out.audioMix = built.audioMix
            // The limiter works on the samples in place, so they must be the output's own copy.
            out.alwaysCopiesSampleData = true
            reader.add(out)
            audioOut = out
        }

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitRate(for: size, duration: project.duration),
            AVVideoExpectedSourceFrameRateKey: settings.fps,
        ]
        if settings.hevc {
            // HEVC only takes the keyframe interval in frames; a duration raises from AVAssetWriterInput.
            compression[AVVideoMaxKeyFrameIntervalKey] = max(settings.fps * 2, 1)
        } else {
            compression[AVVideoMaxKeyFrameIntervalDurationKey] = 2
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)
        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: settings.audioBitRate,
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioIn = input
        }

        guard reader.startReading() else { throw reader.error ?? Failure.failed("Couldn't read the project's media.") }
        guard writer.startWriting() else { throw writer.error ?? Failure.failed("Couldn't write the movie file.") }
        writer.startSession(atSourceTime: .zero)

        let cancel = ReaderBox(reader: reader)
        await withTaskCancellationHandler {
            async let video: Void = pump(videoOut, into: videoIn, label: "export.video") { t in progress(min(t / total, 0.999)) }
            if let audioOut, let audioIn {
                var limiter = PeakLimiter(sampleRate: 48000)
                await pump(audioOut, into: audioIn, label: "export.audio", process: { limiter.limit($0) }) { _ in }
            }
            await video
        } onCancel: {
            cancel.reader.cancelReading()
        }
        if Task.isCancelled || reader.status == .cancelled {
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw reader.error ?? Failure.failed("Reading the project failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? Failure.failed("Writing the movie failed.") }
        progress(1)
    }

    static func build(project: Project, bundle: ProjectBundle, cursor: CursorTrack, captions: [Caption], size: CGSize,
                      fps: Int) async throws -> CompositionBuilder.Result {
        let state = RenderState(project: project, cursor: cursor)
        state.update(options: FrameRenderer.Options(accurateSegmentation: true))
        state.update(backgroundImage: bundle.backgroundImage(for: project))
        state.update(captions: captions)
        state.add(stills: await TransitionStills.load(project.transitionStills, project: project, bundle: bundle))
        return try await CompositionBuilder.build(project: project, bundle: bundle, state: state, renderSize: size, fps: fps)
    }

    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
                             process: ((CMSampleBuffer) -> Void)? = nil,
                             progress: @escaping @Sendable (Double) -> Void) async {
        let queue = DispatchQueue(label: label)
        let box = SendableBox(output: output, input: input, process: process)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            var finished = false
            box.input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while box.input.isReadyForMoreMediaData {
                    guard let sample = box.output.copyNextSampleBuffer() else {
                        box.input.markAsFinished()
                        finished = true
                        done.resume()
                        return
                    }
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    box.process?(sample)
                    guard box.input.append(sample) else {
                        finished = true
                        done.resume()
                        return
                    }
                    if t.isFinite { progress(t) }
                }
            }
        }
    }

    struct ReaderBox: @unchecked Sendable {
        let reader: AVAssetReader
    }

    private struct SendableBox: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let process: ((CMSampleBuffer) -> Void)?
    }
}

extension PeakLimiter {
    mutating func limit(_ sample: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        var contiguous = 0, total = 0
        var data: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &contiguous, totalLengthOut: &total,
                                          dataPointerOut: &data) == kCMBlockBufferNoErr,
              let data, contiguous == total else { return }
        let channels = 2
        data.withMemoryRebound(to: Float.self, capacity: total / 4) {
            process($0, frames: total / 4 / channels, channels: channels)
        }
    }
}
