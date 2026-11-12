//
//  TimelineView.swift
//  Slice
//
//  Created by rit3zh CX on 10/12/26.
//

import SliceCore
import SwiftUI

struct TimelineView: View {
    @ObservedObject var editor: EditorModel
    @Binding var zoom: Double

    private let gutter: CGFloat = 48
    private let rulerHeight: CGFloat = 26
    private let clipHeight: CGFloat = 46
    private let rowHeight: CGFloat = 38
    private let spacing: CGFloat = 8
    private let inset = CutPin.width / 2 + 2

    @State private var trimDrag: TrimDrag?
    @State private var hoveringTakes = false
    @State private var pointer = Pointer()
    @State private var scroll = ScrollPosition()
    @State private var scrollX: CGFloat = 0
    @State private var pinchStart: Double?

    static let zoomRange: ClosedRange<Double> = 1 ... 10

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: spacing) {
                Color.clear.frame(height: rulerHeight)
                GutterButton(symbol: "film", hoverSymbol: "scissors", help: "Split the clip at the playhead (⌘B)") {
                    editor.splitAtPlayhead()
                }
                .frame(height: clipHeight)
                GutterButton(symbol: "person.crop.rectangle", hoverSymbol: "plus", help: "Add a camera layout at the playhead") {
                    editor.addCameraBlock(at: editor.time)
                }
                .frame(height: rowHeight)
                GutterButton(symbol: "plus.magnifyingglass", hoverSymbol: "plus", help: "Add a zoom at the playhead") {
                    editor.addZoomBlock(at: editor.time)
                }
                .frame(height: rowHeight)
                GutterButton(symbol: "eye.slash", hoverSymbol: "plus", help: "Blur part of the screen at the playhead") {
                    editor.addRedaction(at: editor.time)
                }
                .frame(height: rowHeight)
                GutterButton(symbol: SpotlightLane.symbol, hoverSymbol: "plus", help: "Add a spotlight at the playhead") {
                    editor.addSpotlight(at: editor.time)
                }
                .frame(height: rowHeight)
                if editor.hasAnnotations {
                    GutterButton(symbol: AnnotationLane.symbol, hoverSymbol: "cursorarrow.click", help: "Select the drawing at the playhead") {
                        editor.selectAnnotation(near: editor.time)
                    }
                    .frame(height: rowHeight)
                    .transition(.opacity)
                }
                if editor.shows3DTrack {
                    GutterButton(symbol: "cube", hoverSymbol: "plus", help: "Add a 3D keyframe at the playhead") {
                        withAnimation(Theme.hover) { editor.addKeyframe(at: editor.time) }
                    }
                    .frame(height: rowHeight)
                    .transition(.opacity)
                }
                GutterButton(symbol: "music.note", hoverSymbol: "plus", help: "Add music at the playhead") {
                    Task { await editor.addMusicClip(at: editor.time) }
                }
                .frame(height: rowHeight)
            }
            .frame(width: gutter)

            GeometryReader { geo in
                let width = max(geo.size.width * zoom - inset * 2, 10)
                let pps = width / max(editor.duration, 0.1)
                ScrollView(.horizontal) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: spacing) {
                            Ruler(duration: editor.duration, pps: pps)
                                .frame(height: rulerHeight)
                                .contentShape(Rectangle())
                                .gesture(scrub(pps: pps))
                            takesRow(pps: pps)
                            track(.camera, pps: pps, empty: editor.project.cameraBlocks.isEmpty) {
                                ForEach(editor.project.cameraBlocks) { b in
                                    BlockView(title: "Camera", color: Theme.camera, start: b.start, end: b.end, pps: pps, height: rowHeight,
                                              selected: editor.selection == .camera(b.id),
                                              select: { editor.selection = .camera(b.id) },
                                              setRange: { editor.setCameraBlockRange(b.id, start: $0, end: $1) }) {
                                        Label(label(for: b.layout), systemImage: "person.crop.rectangle")
                                    }
                                }
                            }
                            track(.zoom, pps: pps, empty: editor.project.zoomBlocks.isEmpty) {
                                ForEach(editor.project.zoomBlocks) { b in
                                    BlockView(title: "Zoom", color: Theme.zoom, start: b.start, end: b.end, pps: pps, height: rowHeight,
                                              selected: editor.selection == .zoom(b.id),
                                              select: { editor.selection = .zoom(b.id) },
                                              setRange: { editor.setZoomBlockRange(b.id, start: $0, end: $1) }) {
                                        HStack(spacing: 6) {
                                            HStack(spacing: 3) {
                                                Image(systemName: b.kind == .liquidGlass ? "drop" : "plus.magnifyingglass")
                                                if b.kind == .liquidGlass { Text("Glass") }
                                                Text(String(format: "%.1f×", b.scale))
                                                    .contentTransition(.numericText(value: b.scale))
                                                    .animation(.snappy, value: b.scale)
                                            }
                                            if b.isAuto {
                                                HStack(spacing: 3) {
                                                    Image(systemName: "cursorarrow.rays")
                                                    Text("Auto")
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            track(.blur, pps: pps, empty: editor.project.redactions.isEmpty) {
                                RedactLaneContent(editor: editor, pps: pps, height: rowHeight)
                            }
                            track(.spotlight, pps: pps, empty: editor.project.spotlights.isEmpty) {
                                SpotlightLane(editor: editor, pps: pps, height: rowHeight)
                            }
                            if editor.hasAnnotations {
                                track(.annotate, pps: pps, empty: false) {
                                    AnnotationLane(editor: editor, pps: pps, height: rowHeight)
                                }
                                .transition(.opacity)
                            }
                            if editor.shows3DTrack {
                                KeyframeLane(editor: editor, pps: pps, height: rowHeight)
                                    .transition(.opacity)
                            }
                            track(.music, pps: pps, empty: editor.project.music.isEmpty) {
                                MusicLaneContent(editor: editor, pps: pps, height: rowHeight)
                            }
                        }
                        GhostPlayhead(pointer: pointer, clock: editor.clock, pps: pps, height: geo.size.height)
                        PlayheadTrack(editor: editor, clock: editor.clock, pps: pps, height: geo.size.height)
                    }
                    .frame(width: width, alignment: .leading)
                    .onContinuousHover { phase in
                        switch phase {
                        case let .active(p): pointer.move(to: p.x)
                        case .ended: pointer.leave()
                        }
                    }
                    .padding(.horizontal, inset)
                }
                .scrollIndicators(.never)
                .scrollDisabled(zoom <= 1.01)
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scrollX = x }
                .simultaneousGesture(pinch(viewport: geo.size.width))
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 12)
        .padding(.trailing, 10)
        .background(Theme.window)
        .overlay(alignment: .top) { Rectangle().fill(Theme.stroke).frame(height: 1) }
    }

    private func pinch(viewport: CGFloat) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? zoom
                if pinchStart == nil { pinchStart = start }
                let next = min(max(start * value.magnification, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
                guard next != zoom else { return }
                let duration = max(editor.duration, 0.1)
                let pps = { (z: Double) in max(viewport * z - inset * 2, 10) / duration }
                let x = value.startLocation.x
                let t = (scrollX + x - inset) / pps(zoom)
                let offset = t * pps(next) + inset - x
                let maxOffset = max(viewport * next - viewport, 0)
                withTransaction(\.disablesAnimations, true) {
                    zoom = next
                    scroll.scrollTo(x: min(max(offset, 0), maxOffset))
                }
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func scrub(pps: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in editor.scrub(to: v.location.x / pps) }
            .onEnded { _ in editor.endScrub() }
    }

    private func takesRow(pps: CGFloat) -> some View {
        let segs = editor.project.segments
        let clips = editor.project.clips
        let selected = editor.selectedSection
        let tick = Ruler.step(pps: pps)
        let bundle = editor.bundle, project = editor.project
        let audio = clips.map { clip in
            ClipAudio(mic: bundle.voiceFile(for: clip, settings: project.voice).map(bundle.file),
                      screen: clip.screenAudioFile.map(bundle.file),
                      micGain: Float(project.micVolume), screenGain: Float(project.screenAudioVolume))
        }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.025))
            if let drag = trimDrag, let ghost = drag.removedRange {
                TrimGhost()
                    .frame(width: max((ghost.upperBound - ghost.lowerBound) * pps - 2, 0), height: clipHeight)
                    .offset(x: ghost.lowerBound * pps + 1)
                    .transition(.opacity)
            }
            ForEach(segs.indices.map { SectionKey(index: $0, clip: clips[segs[$0].clipIndex].id, start: segs[$0].sourceStart) }) { key in
                let i = key.index, seg = segs[i]
                let firstOfTake = i == 0 || segs[i - 1].clipIndex != seg.clipIndex
                SectionChip(label: firstOfTake ? "Take \(seg.clipIndex + 1)" : "Clip", segment: seg, pps: pps, height: clipHeight,
                            selected: selected == seg, dimmed: selected != nil && selected != seg, tick: tick,
                            clipDuration: clips[seg.clipIndex].duration, audio: audio[seg.clipIndex], drag: $trimDrag,
                            snapTime: { editor.time },
                            select: { editor.select(section: seg) },
                            preview: { editor.scrub(to: $0) },
                            trim: { start, end in editor.trim(seg, newStart: start, newEnd: end) })
                    .transition(.asymmetric(insertion: .identity, removal: .opacity))
            }
            if trimDrag == nil { transitionMarks(segs: segs, pps: pps).transition(.opacity) }
            if editor.isCutting {
                CutLayer(segments: segs, pps: pps, height: clipHeight, playhead: { editor.time },
                         cut: { editor.split(at: $0) })
                    .transition(.opacity)
            }
            if let flash = editor.cutFlash {
                CutFlashMark(height: clipHeight)
                    .offset(x: flash.time * pps - 1)
                    .id(flash.id)
                    .transition(.identity)
            }
        }
        .animation(.snappy(duration: 0.22), value: segs)
        .frame(height: clipHeight)
        .onHover { hoveringTakes = $0 }
        .onChange(of: trimDrag == nil) { _, ended in if ended { editor.endScrub() } }
        .overlay(alignment: .topLeading) {
            joinPins(pps: pps)
                .offset(y: -CutPin.height - 1)
        }
    }

    private func transitionMarks(segs: [Segment], pps: CGFloat) -> some View {
        let placed = editor.project.placedTransitions
        return ZStack(alignment: .topLeading) {
            ForEach(Array(segs.enumerated().dropFirst()), id: \.offset) { _, seg in
                if let p = placed.first(where: { $0.window.next == seg }) {
                    TransitionBlock(placed: p, pps: pps, selected: editor.selection == .transition(p.transition.id),
                                    select: {
                                        editor.selection = .transition(p.transition.id)
                                        editor.seek(to: p.window.time)
                                    },
                                    setDuration: { d in editor.updateTransition(p.transition.id) { $0.duration = d } },
                                    remove: { editor.removeTransition(p.transition.id) })
                        .offset(x: seg.editedStart * pps - TransitionBlock.width(p, pps: pps) / 2,
                                y: (clipHeight - TransitionBlock.height) / 2)
                } else {
                    AddTransitionButton(visible: hoveringTakes && !editor.isCutting) { kind in editor.setTransition(into: seg, kind: kind) }
                        .offset(x: seg.editedStart * pps - AddTransitionButton.size / 2, y: (clipHeight - AddTransitionButton.size) / 2)
                }
            }
        }
        .animation(Theme.hover, value: placed.map(\.transition))
    }

    private func joinPins(pps: CGFloat) -> some View {
        let joins = editor.project.joins
        let drag = trimDrag
        let dragged = drag.flatMap { d in joins.first { d.leading ? $0.next == d.segment : $0.previous == d.segment } }
        return ZStack(alignment: .topLeading) {
            ForEach(joins, id: \.time) { join in
                if drag == nil || join != dragged {
                    CutPin(removed: join.gaps.isEmpty ? nil : join.removed, live: false)
                        .offset(x: join.time * pps - CutPin.width / 2)
                        .onTapGesture { editor.seek(to: join.time) }
                        .contextMenu {
                            Button(join.gaps.isEmpty ? "Join Sections" : "Restore \(CutPin.label(join.removed, precise: true))") {
                                editor.heal(join)
                            }
                        }
                        .help(join.gaps.isEmpty ? "Split here. Right-click to join back up"
                            : "\(CutPin.label(join.removed, precise: true)) removed here. Right-click to restore")
                        .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
                }
            }
            if let d = drag {
                let removed = max((dragged?.removed ?? 0) + (d.leading ? d.delta : -d.delta), 0)
                CutPin(removed: removed, live: true)
                    .offset(x: d.edgeTime * pps - CutPin.width / 2)
                    .allowsHitTesting(false)
                    .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.22), value: joins.map(\.time))
        .animation(.snappy(duration: 0.22), value: drag == nil)
    }

    private func track<Content: View>(_ lane: EditorModel.TimelineLane, pps: CGFloat, empty: Bool,
                                      @ViewBuilder content: () -> Content) -> some View {
        LaneTrack(lane: lane, empty: empty, pps: pps, height: rowHeight,
                  propose: { editor.proposedRange(lane, at: $0) },
                  tap: { t in
                      if editor.proposedRange(lane, at: t) != nil {
                          editor.addBlock(lane, at: t)
                      } else {
                          editor.selection = nil
                          editor.seek(to: t)
                      }
                  },
                  content: content)
    }

    private func label(for layout: CameraLayout) -> String {
        switch layout {
        case .hidden: "Hidden"
        case let .centre(c): "Centre \(Int(c * 100))%"
        case let .split(side, share):
            (side == .left ? "Split ◧" : "Split ◨") + (share.map { " \(Int((100 * (1 - $0)).rounded()))/\(Int((100 * $0).rounded()))" } ?? "")
        case .fullscreen: "Full screen"
        case let .corner(corner, shape, size):
            "\(corner.short) \(shape.rawValue.capitalized) \(size == .small ? "S" : "L")"
        }
    }
}

private struct SectionKey: Identifiable {
    struct ID: Hashable {
        let clip: UUID
        let start: Double
    }

    let index: Int
    let id: ID

    init(index: Int, clip: UUID, start: Double) {
        self.index = index
        id = ID(clip: clip, start: start)
    }
}
