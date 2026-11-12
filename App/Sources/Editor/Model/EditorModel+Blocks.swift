//
//  EditorModel+Blocks.swift
//  Slice
//
//  Created by rit3zh CX on 10/15/26.
//

import Combine
import SliceCore
import SwiftUI

extension EditorModel {
    enum TimelineLane { case camera, zoom, blur, spotlight, annotate, music }

    func gap(around t: Double, in ranges: [(id: UUID, start: Double, end: Double)], excluding: UUID? = nil) -> ClosedRange<Double> {
        let others = ranges.filter { $0.id != excluding }
        let lo = others.filter { $0.end <= t }.map(\.end).max() ?? 0
        let hi = others.filter { $0.start >= t }.map(\.start).min() ?? duration
        return lo ... max(lo, hi)
    }

    var cameraRanges: [(id: UUID, start: Double, end: Double)] { project.cameraBlocks.map { ($0.id, $0.start, $0.end) } }
    var zoomRanges: [(id: UUID, start: Double, end: Double)] { project.zoomBlocks.map { ($0.id, $0.start, $0.end) } }

    func proposedRange(_ lane: TimelineLane, at t: Double) -> ClosedRange<Double>? {
        let t = min(max(t, 0), duration)
        switch lane {
        case .camera, .zoom, .blur, .spotlight:
            let ranges = switch lane {
            case .camera: cameraRanges
            case .zoom: zoomRanges
            case .spotlight: spotlightRanges
            default: redactRanges
            }
            guard !ranges.contains(where: { $0.start <= t && t < $0.end }) else { return nil }
            let space = gap(around: t, in: ranges)
            let length = min(lane == .camera ? 5 : 3, space.upperBound - space.lowerBound)
            guard length >= Self.minBlock else { return nil }
            let start = max(min(t, space.upperBound - length), space.lowerBound)
            return start ... start + length
        case .annotate:
            return nil
        case .music:
            guard focusedMusic != nil || !Self.libraryTracks.isEmpty,
                  !project.music.contains(where: { $0.timelineRange(duration: duration)?.contains(t + 0.001) ?? false })
            else { return nil }
            let space = project.musicGap(around: t)
            let start = max(t, space.lowerBound)
            guard space.upperBound - start >= MusicClip.minLength else { return nil }
            return start ... space.upperBound
        }
    }

    func addBlock(_ lane: TimelineLane, at t: Double) {
        switch lane {
        case .camera: addCameraBlock(at: t)
        case .zoom: addZoomBlock(at: t)
        case .blur: addRedaction(at: t)
        case .spotlight: addSpotlight(at: t)
        case .annotate: selectAnnotation(near: t)
        case .music: Task { await addMusicClip(at: t) }
        }
    }

    func addCameraBlock(at t: Double) {
        guard let range = proposedRange(.camera, at: t) else { return }
        let layout: CameraLayout = if case .centre = project.defaultCamera { .corner(.bottomRight, .square, .small) } else { .centre(coverage: 0.6) }
        let block = CameraBlock(start: range.lowerBound, end: range.upperBound, layout: layout)
        project.cameraBlocks.append(block)
        selection = .camera(block.id)
        seek(to: range.lowerBound)
    }

    func addZoomBlock(at t: Double) {
        guard let range = proposedRange(.zoom, at: t) else { return }
        let focus = cursorTrack.position(at: range.lowerBound) ?? CGPoint(x: 0.5, y: 0.5)
        let block = ZoomBlock(start: range.lowerBound, end: range.upperBound, scale: 2, focus: focus)
        project.zoomBlocks.append(block)
        selection = .zoom(block.id)
        seek(to: range.lowerBound)
    }

    func setCameraBlockRange(_ id: UUID, start: Double, end: Double) {
        guard let i = project.cameraBlocks.firstIndex(where: { $0.id == id }) else { return }
        let r = clamp(start: start, end: end, current: project.cameraBlocks[i].start ..< project.cameraBlocks[i].end,
                      ranges: cameraRanges, id: id)
        project.cameraBlocks[i].start = r.lowerBound
        project.cameraBlocks[i].end = r.upperBound
    }

    func setZoomBlockRange(_ id: UUID, start: Double, end: Double) {
        guard let i = project.zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        let r = clamp(start: start, end: end, current: project.zoomBlocks[i].start ..< project.zoomBlocks[i].end,
                      ranges: zoomRanges, id: id)
        project.zoomBlocks[i].start = r.lowerBound
        project.zoomBlocks[i].end = r.upperBound
        project.zoomBlocks[i].isAuto = false
    }

    func clamp(start: Double, end: Double, current: Range<Double>, ranges: [(id: UUID, start: Double, end: Double)],
               id: UUID) -> ClosedRange<Double> {
        let space = gap(around: (current.lowerBound + current.upperBound) / 2, in: ranges, excluding: id)
        let length = end - start
        if abs(length - (current.upperBound - current.lowerBound)) < 1e-9 {
            let s = min(max(start, space.lowerBound), space.upperBound - length)
            return max(s, space.lowerBound) ... min(max(s, space.lowerBound) + length, space.upperBound)
        }
        let s = min(max(start, space.lowerBound), end - Self.minBlock)
        let e = max(min(end, space.upperBound), s + Self.minBlock)
        return max(s, space.lowerBound) ... min(e, space.upperBound)
    }

    func updateCamera(_ id: UUID, layout: CameraLayout) {
        guard let i = project.cameraBlocks.firstIndex(where: { $0.id == id }) else { return }
        project.cameraBlocks[i].layout = layout
    }

    func updateZoomBlock(_ id: UUID, _ change: (inout ZoomBlock) -> Void) {
        guard let i = project.zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        var z = project.zoomBlocks[i]
        let kind = z.kind, tilt = z.tilt
        change(&z)
        z.isAuto = false
        project.zoomBlocks[i] = z
        if z.kind != kind { revealSelectedLens() }
        if z.tilt != tilt, z.tilt.enabled, !(z.start ... z.end).contains(time) { seek(to: (z.start + z.end) / 2) }
    }

    func updateZoom(_ id: UUID, scale: Double? = nil, focus: CGPoint? = nil, endFocus: CGPoint? = nil) {
        guard let i = project.zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        func clamped(_ p: CGPoint) -> CGPoint { CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1)) }
        if let endFocus { project.zoomBlocks[i].endFocus = clamped(endFocus) }
        guard let i = project.zoomBlocks.firstIndex(where: { $0.id == id }) else { return }
        if let scale { project.zoomBlocks[i].scale = scale }
        if let focus { project.zoomBlocks[i].focus = clamped(focus) }
        project.zoomBlocks[i].isAuto = false
    }

    func deleteSelection() {
        if wordSelection != nil {
            deleteSelectedWords()
            return
        }
        switch selection {
        case let .camera(id): project.cameraBlocks.removeAll { $0.id == id }
        case let .zoom(id): project.zoomBlocks.removeAll { $0.id == id }
        case .section:
            guard canDeleteSection else { return }
            deleteSelectedSection()
        case let .music(id): project.music.removeAll { $0.id == id }
        case let .transition(id): project.transitions.removeAll { $0.id == id }
        case let .keyframe(id): project.device3D.keyframes.removeAll { $0.id == id }
        case let .redact(id): project.redactions.removeAll { $0.id == id }
        case let .spotlight(id): project.spotlights.removeAll { $0.id == id }
        case let .annotation(id): project.annotations.removeAll { $0.id == id }
        case nil: return
        }
        selection = nil
    }

    func autoZoom() { runSmartZoom() }

    var hasClicks: Bool { !cursorTrack.clicks.isEmpty }
    var hasPointerLog: Bool { project.clips.contains { cursorLogs[$0.id] != nil } }
    var hasKeystrokes: Bool { !cursorTrack.keys.isEmpty }
    /// Takes recorded with typed text, which can show what was typed.
    var hasTypedKeys: Bool { cursorTrack.keys.contains(where: \.isTyped) }
    /// Every word typed in the takes, for choosing which to hide.
    var typedWords: [String] { KeystrokeTimeline.typedWords(in: cursorTrack.keys, hold: project.keystrokes.hold) }
    var hasKeyHits: Bool { !cursorTrack.keyHits.isEmpty }

    // MARK: - Sections

    var selectedSection: Segment? {
        guard case let .section(clipID, start) = selection,
              let ci = project.clips.firstIndex(where: { $0.id == clipID }) else { return nil }
        return project.segments.first { $0.clipIndex == ci && abs($0.sourceStart - start) < 0.001 }
    }

    func select(section seg: Segment) {
        selection = .section(clipID: project.clips[seg.clipIndex].id, start: seg.sourceStart)
    }

    var canDeleteSection: Bool { project.segments.count > 1 }

    var canDeleteClip: Bool { project.clips.count > 1 }

    func deleteSelectedSection() {
        guard canDeleteSection, let seg = selectedSection else { return }
        project.delete(segment: seg)
        selection = nil
    }

    func heal(_ join: Join) {
        project.heal(join)
    }

    func trim(_ seg: Segment, newStart: Double? = nil, newEnd: Double? = nil) {
        let id = project.clips[seg.clipIndex].id
        project.trim(segment: seg, newStart: newStart, newEnd: newEnd)
        let start = newStart.map { max($0, 0) } ?? seg.sourceStart
        if let ci = project.clips.firstIndex(where: { $0.id == id }),
           let s = project.segments.first(where: { $0.clipIndex == ci && abs($0.sourceStart - start) < 0.05 }) {
            select(section: s)
        }
    }
}
