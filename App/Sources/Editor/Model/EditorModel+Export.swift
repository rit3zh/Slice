//
//  EditorModel+Export.swift
//  Slice
//
//  Created by rit3zh CX on 10/15/26.
//

import Combine
import SliceCore
import SwiftUI

extension EditorModel {
    func importClips(_ urls: [URL], onto3D: Bool = false) async {
        var added: [Clip] = []
        for url in urls {
            do {
                added.append(try await importTake(url, onto3D: onto3D))
            } catch {
                transcribeError = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        guard !added.isEmpty else { return }
        project.clips += added
        saveNow()
        scanSpeech()
    }

    func deleteClip(_ id: UUID) {
        guard canDeleteClip, let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var p = project
        let start = p.clipStarts[i]
        let len = p.clipEditedDurations[i]
        let end = start + len
        func shift(_ s: Double, _ e: Double) -> (Double, Double)? {
            if e <= start { return (s, e) }
            if s >= end { return (s - len, e - len) }
            let ns = s < start ? s : start
            let ne = e > end ? e - len : start
            return ne - ns >= Self.minBlock ? (ns, ne) : nil
        }
        p.cameraBlocks = p.cameraBlocks.compactMap { b in shift(b.start, b.end).map { var b = b; (b.start, b.end) = $0; return b } }
        p.zoomBlocks = p.zoomBlocks.compactMap { b in shift(b.start, b.end).map { var b = b; (b.start, b.end) = $0; return b } }
        p.redactions = p.redactions.compactMap { b in shift(b.start, b.end).map { var b = b; (b.start, b.end) = $0; return b } }
        p.spotlights = p.spotlights.compactMap { b in shift(b.start, b.end).map { var b = b; (b.start, b.end) = $0; return b } }
        p.annotations = p.annotations.filter { $0.clipID != id }
            .compactMap { b in shift(b.start, b.end).map { var b = b; (b.start, b.end) = $0; return b } }
        p.cuts.removeAll { $0.clipID == id }
        p.speeds.removeAll { $0.clipID == id }
        p.clips.remove(at: i)
        project = p
        saveNow()
    }

    func close() {
        stopExport()
        cancelTranscription()
        cancelSmartZoom()
        cancelSensitiveTextScan()
        cancelVoice()
        cleanUpVoices()
        pause()
        audition.stop()
        saveNow()
        // Aiming a zoom shows the frame unzoomed, which a fresh open wouldn't: that frame isn't kept.
        let preview = PreviewNSView.current.flatMap { $0.driver === previewDriver && !renderState.current().options.ignoreZoom ? $0 : nil }
        ProjectPreviews.shared.keep(preview?.snapshot(), at: time, project: project, bundle: bundle)
        bundle.removeOrphanedClips(keeping: project)
        bundle.removeOrphanedAudio(keeping: project)
    }

    // MARK: - Export

    func startExport(to url: URL) {
        startExport([(url, project.export.aspect)])
    }

    /// One file per shape (16:9, 9:16 and 1:1) into `folder`, named after the project and the shape.
    func startBatchExport(in folder: URL) {
        let ext = project.export.format.fileExtension
        var taken = Set<URL>()
        let items = OutputAspect.batchShapes.map { aspect in
            let url = Self.freeURL(in: folder, name: "\(project.name) \(aspect.fileTag)", ext: ext, taken: taken)
            taken.insert(url)
            return (url: url, aspect: aspect)
        }
        startExport(items)
    }

    private func startExport(_ items: [(url: URL, aspect: OutputAspect)]) {
        guard exportJob?.isRunning != true, let first = items.first else { return }
        ExportDefaults.remember(project.export)
        pause()
        let p = exporting(first.aspect), settings = p.export
        let job = ExportJob(url: first.url, format: settings.format, size: p.exportSize, fps: settings.outputFPS, hevc: settings.hevc,
                            bitRate: p.exportBitRate, duration: p.duration, outputs: items.map(\.url),
                            shape: items.count > 1 ? first.aspect : nil,
                            byteLimit: settings.format == .video ? p.exportByteLimit : nil)
        exportJob = job
        exportTask = Task { [weak self] in await self?.runExport(items, job: job.id) }
    }

    private func exporting(_ aspect: OutputAspect) -> Project {
        var p = project
        p.export.aspect = aspect
        return p
    }

    static func freeURL(in folder: URL, name: String, ext: String, taken: Set<URL>) -> URL {
        var n = 1
        while true {
            let url = folder.appendingPathComponent(n == 1 ? name : "\(name) \(n)").appendingPathExtension(ext)
            if !taken.contains(url), !FileManager.default.fileExists(atPath: url.path) { return url }
            n += 1
        }
    }

    func stopExport() {
        exportTask?.cancel()
        exportTask = nil
        exportJob = nil
    }

    func dismissExport() {
        guard exportJob?.isRunning != true else { return }
        exportJob = nil
    }

    func runExport(_ items: [(url: URL, aspect: OutputAspect)], job id: UUID) async {
        scanCameraGlitches()
        scanHoverMoments()
        scanSpeech()
        if glitchScan != nil || hoverScan != nil || speechScan != nil {
            update(id) { $0.note = "Looking through the recording…" }
        }
        await glitchScan?.value
        await hoverScan?.value
        await speechScan?.value
        guard !Task.isCancelled else { return }
        saveNow()
        do {
            try await prepareVoiceForExport { [weak self] p in
                self?.update(id) { $0.note = "Enhancing voice… \(Int((p * 100).rounded(.down)))%" }
            }
            update(id) { $0.note = nil }
            var bytes: Int64 = 0
            for (step, item) in items.enumerated() {
                let p = exporting(item.aspect)
                update(id) { job in
                    job.step = step
                    job.url = item.url
                    job.size = p.exportSize
                    job.bitRate = p.exportBitRate
                    if items.count > 1 { job.shape = item.aspect }
                }
                let throttle = ProgressThrottle()
                let count = Double(items.count)
                try await Exporter.export(project: p, bundle: bundle, cursor: cursorTrack, captions: captions, to: item.url) { v in
                    let overall = (Double(step) + v) / count
                    guard throttle.shouldReport(overall) else { return }
                    Task { @MainActor [weak self] in self?.exportProgressed(overall, job: id) }
                }
                try Task.checkCancellation()
                bytes += Int64((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            update(id) { $0.progress = 1; $0.phase = .done(bytes: bytes) }
        } catch {
            if Task.isCancelled || error is CancellationError {
                for item in items { try? FileManager.default.removeItem(at: item.url) }
                return
            }
            update(id) { $0.phase = .failed(error.localizedDescription) }
        }
    }

    func exportProgressed(_ p: Double, job id: UUID) {
        update(id) { job in
            guard job.isRunning else { return }
            if job.phase == .preparing { job.renderStarted = Date() }
            job.progress = max(job.progress, p)
            job.phase = p >= 0.99 ? .finishing : .rendering
        }
    }

    func update(_ id: UUID, _ change: (inout ExportJob) -> Void) {
        guard var job = exportJob, job.id == id else { return }
        change(&job)
        exportJob = job
    }
}
