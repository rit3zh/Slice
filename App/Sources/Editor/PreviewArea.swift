//
//  PreviewArea.swift
//  Slice
//
//  Created by rit3zh CX on 10/9/26.
//

import SliceCore
import SwiftUI

struct PreviewHeader: View {
    @ObservedObject var editor: EditorModel
    @AppStorage("sidePanel.tab") private var inspectorTab = InspectorTab.frame.rawValue

    var body: some View {
        let aspect = editor.project.export.aspect
        HStack(spacing: 8) {
            Menu {
                Picker("Aspect", selection: $editor.project.export.aspect.animation(.snappy)) {
                    ForEach(OutputAspect.allCases, id: \.self) { a in
                        Label(a.menuTitle, systemImage: a.symbol).tag(a)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: aspect.symbol)
                    Text(aspect.name)
                    if aspect != .auto { Text(aspect.rawValue).font(.rounded(12)).foregroundStyle(.secondary) }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(PillButtonStyle())
            .fixedSize()
            .help("Output shape. Auto matches the recording, so with no padding the screen fills the frame exactly.")
            if canFit { fitMenu.transition(.opacity.combined(with: .scale(scale: 0.96))) }
            PreviewQualityMenu()
            if editor.smartZoomProgress != nil || editor.smartZoomNote != nil {
                SmartZoomStatus(editor: editor)
            }
            if let p = editor.deviceImportProgress { DeviceImportStatus(progress: p) }
            Spacer()
            Text(hint)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .id(hint)
                .transition(.opacity.combined(with: .offset(y: 4)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .animation(Theme.swap, value: hint)
        .animation(Theme.swap, value: editor.smartZoomProgress == nil)
        .animation(Theme.swap, value: editor.deviceImportProgress == nil)
        .animation(Theme.swap, value: editor.smartZoomNote)
        .animation(Theme.swap, value: canFit)
    }

    /// A recording far from the frame's shape, which is either cropped to fill it or fitted whole.
    private var canFit: Bool {
        let p = editor.project
        // A mockup always shows the whole recording.
        guard p.style.mockup.kind == .none else { return false }
        return p.clips.contains { clip in
            clip.device == nil
                && ScreenGeometry(contentSize: clip.screenPixelSize, output: p.renderSize, style: p.style).isMismatched
        }
    }

    private var fitMenu: some View {
        let fits = editor.project.style.fitsScreen
        return Menu {
            Picker("Recording", selection: $editor.project.style.fitsScreen.animation(.snappy)) {
                Label("Fill the frame, following the pointer", systemImage: "arrow.up.left.and.arrow.down.right").tag(false)
                Label("Fit the whole recording", systemImage: "arrow.down.right.and.arrow.up.left").tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: fits ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                Text(fits ? "Fit" : "Fill")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PillButtonStyle())
        .fixedSize()
        .help("The recording's shape doesn't match the frame. Fill crops it and follows the pointer; Fit shows all of it, "
            + "with the background around it, and zooms start from there.")
    }

    private var hint: String {
        switch editor.selection {
        case .zoom: editor.selectedZoom?.followsCursor == true ? "The zoom follows the pointer."
            : editor.aimsOnCanvas ? "Drag the box to aim the zoom." : "Drag the picture to aim the zoom."
        case .camera: "Choose a layout on the right."
        case .section: "Delete removes this section. Drag its edges to trim."
        case .music: "Drag to move the music, its edges to trim. Delete removes it."
        case .transition: "Drag its edges to change the length. Delete removes it."
        case .keyframe: "Pose the phone in the preview. Drag the keyframe to retime it. Delete removes it."
        case .redact: "Drag the box over what to hide. Delete removes it."
        case .annotation: "Drag the drawing to move it, its corners to resize. Delete removes it."
        case .spotlight: editor.selectedSpotlight?.followsPointer == true ? "The spotlight follows the pointer. Delete removes it."
            : "Drag the circle onto what to light, its edge to resize. Delete removes it."
        case nil: editor.wordSelection != nil ? "Delete cuts the selected words. ⌘Z undoes."
            : editor.handlesPhoneInPreview(tab: inspectorTab) ? Device3DPoseOverlay.hint
            : "Double-click a track to add a block. Space plays."
        }
    }
}

// MARK: - Preview

struct PreviewArea: View {
    @ObservedObject var editor: EditorModel
    @AppStorage("preview.quality") private var quality = PreviewQuality.full.rawValue
    @AppStorage("sidePanel.tab") private var inspectorTab = InspectorTab.frame.rawValue

    var body: some View {
        let size = editor.previewSize
        PreviewSurface(driver: editor.previewDriver, quality: quality)
            .aspectRatio(size, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    // Underneath the other overlays, so their own drags and taps come first.
                    if editor.hasAnnotations, editor.selection == nil || editor.selectedAnnotation != nil {
                        AnnotationTapCatcher(editor: editor, viewSize: geo.size)
                    }
                    if editor.isEditingAnnotation, let block = editor.selectedAnnotation {
                        AnnotationBoxOverlay(editor: editor, block: block, viewSize: geo.size)
                    }
                    if editor.handlesPhoneInPreview(tab: inspectorTab) {
                        Device3DPoseOverlay(editor: editor)
                    }
                    if editor.isEditingRedaction, let block = editor.selectedRedaction {
                        RedactBoxOverlay(editor: editor, block: block, viewSize: geo.size)
                    }
                    if editor.isEditingSpotlight, let block = editor.selectedSpotlight {
                        SpotlightOverlay(editor: editor, block: block, viewSize: geo.size)
                    }
                    if editor.isEditingZoomFocus, case let .zoom(id) = editor.selection,
                       let block = editor.project.zoomBlocks.first(where: { $0.id == id }) {
                        if block.kind == .liquidGlass || editor.aimsOnCanvas {
                            ZoomFocusOverlay(editor: editor, block: block, viewSize: geo.size)
                        } else if !block.followsCursor {
                            ZoomPanOverlay(editor: editor, block: block, viewSize: geo.size)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
            .animation(Theme.move, value: size)
    }
}

struct ZoomFocusOverlay: View {
    @ObservedObject var editor: EditorModel
    let block: ZoomBlock
    let viewSize: CGSize
    @State private var dragOrigin: CGPoint?

    private enum End { case start, end }

    private var geometry: ScreenGeometry {
        let project = editor.project
        let i = project.clipStarts.lastIndex { $0 <= block.start } ?? 0
        let clip = project.clips.indices.contains(i) ? project.clips[i] : nil
        return ScreenGeometry(contentSize: clip?.screenPixelSize ?? editor.previewSize, output: editor.previewSize,
                              style: project.style, shapedByAlpha: clip?.device != nil)
    }

    private var k: CGFloat { viewSize.width / editor.previewSize.width }
    private var isLens: Bool { block.kind == .liquidGlass }

    var body: some View {
        let g = geometry
        ZStack(alignment: .topLeading) {
            if !block.followsCursor {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { set(.start, center: $0, geometry: g) }
                handle(.start, geometry: g)
                if block.endFocus != nil { handle(.end, geometry: g) }
            }
        }
    }

    private func point(_ p: CGPoint, _ g: ScreenGeometry) -> CGPoint {
        let c = g.contentRect
        return CGPoint(x: (c.minX + p.x * c.width) * k, y: (c.minY + p.y * c.height) * k)
    }

    private func boxRect(_ focus: CGPoint, _ g: ScreenGeometry) -> CGRect {
        let r = g.zoomedView(scale: block.scale, focus: focus)
        return CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k)
    }

    private func lensRect(_ focus: CGPoint, _ g: ScreenGeometry) -> CGRect {
        let ry = min(editor.previewSize.width, editor.previewSize.height) * block.lens.size / 2 * k
        let rx = block.lens.shape == .pill ? ry * 1.8 : ry
        let c = point(focus, g)
        return CGRect(x: c.x - rx, y: c.y - ry, width: 2 * rx, height: 2 * ry)
    }

    @ViewBuilder private func handle(_ which: End, geometry g: ScreenGeometry) -> some View {
        let focus = which == .start ? block.focus : (block.endFocus ?? block.focus)
        let rect = isLens ? lensRect(focus, g) : boxRect(focus, g)
        let shape: AnyShape = isLens
            ? (block.lens.shape == .squircle ? AnyShape(RoundedRectangle(cornerRadius: rect.height * 0.32, style: .continuous))
                : AnyShape(Capsule()))
            : AnyShape(RoundedRectangle(cornerRadius: 4))
        shape
            .fill(Color.white.opacity(0.001))
            .overlay {
                if !isLens {
                    let color = which == .start ? Theme.accent : Color.white
                    ZStack {
                        shape.fill(color.opacity(0.1))
                        shape.stroke(color, style: StrokeStyle(lineWidth: 2, dash: which == .start ? [] : [6, 4]))
                        Image(systemName: "plus").font(.system(size: 14, weight: .semibold)).foregroundStyle(color)
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .gesture(DragGesture(coordinateSpace: .global)
                .onChanged { v in
                    let start = dragOrigin ?? CGPoint(x: rect.midX, y: rect.midY)
                    if dragOrigin == nil { dragOrigin = start }
                    set(which, center: CGPoint(x: start.x + v.translation.width, y: start.y + v.translation.height), geometry: g)
                }
                .onEnded { _ in dragOrigin = nil })
    }

    private func set(_ which: End, center: CGPoint, geometry g: ScreenGeometry) {
        let c = g.contentRect
        let focus = CGPoint(x: (center.x / k - c.minX) / c.width, y: (center.y / k - c.minY) / c.height)
        if which == .start { editor.updateZoom(block.id, focus: focus) } else { editor.updateZoom(block.id, endFocus: focus) }
    }
}

struct ZoomPanOverlay: View {
    @ObservedObject var editor: EditorModel
    let block: ZoomBlock
    let viewSize: CGSize
    @State private var origin: (focus: CGPoint, end: Bool)?

    private var geometry: ScreenGeometry {
        let project = editor.project
        let i = project.clipStarts.lastIndex { $0 <= block.start } ?? 0
        let clip = project.clips.indices.contains(i) ? project.clips[i] : nil
        return ScreenGeometry(contentSize: clip?.screenPixelSize ?? editor.previewSize, output: editor.previewSize,
                              style: project.style, shapedByAlpha: clip?.device != nil)
    }

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .pointerStyle(origin == nil ? .grabIdle : .grabActive)
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { v in
                    let g = geometry, c = g.contentRect
                    let end = origin?.end ?? (block.endFocus != nil && editor.time > (block.start + block.end) / 2)
                    let view = g.zoomedView(scale: block.scale, focus: end ? (block.endFocus ?? block.focus) : block.focus)
                    let start = origin?.focus ?? CGPoint(x: (view.midX - c.minX) / c.width, y: (view.midY - c.minY) / c.height)
                    if origin == nil { origin = (start, end) }
                    let k = viewSize.width / view.width
                    let lo = CGPoint(x: min(view.width / 2 / c.width, 0.5), y: min(view.height / 2 / c.height, 0.5))
                    let focus = CGPoint(x: min(max(start.x - v.translation.width / k / c.width, lo.x), 1 - lo.x),
                                        y: min(max(start.y - v.translation.height / k / c.height, lo.y), 1 - lo.y))
                    if end { editor.updateZoom(block.id, endFocus: focus) } else { editor.updateZoom(block.id, focus: focus) }
                }
                .onEnded { _ in origin = nil })
            .accessibilityLabel("Zoom framing")
    }
}
