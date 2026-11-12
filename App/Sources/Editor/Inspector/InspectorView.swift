//
//  InspectorView.swift
//  Slice
//
//  Created by rit3zh CX on 10/9/26.
//

import SliceCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var editor: EditorModel
    let tab: InspectorTab

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch tab {
                case .cursor: MouseSection(editor: editor)
                case .keyboard: KeystrokesSection(editor: editor)
                case .frame:
                    // Up top once there's an Android take to act on; out of the way of everyone else.
                    let hasAndroid = editor.project.clips.contains(where: \.isAndroid)
                    if hasAndroid {
                        AndroidFrameSection(editor: editor)
                        PanelDivider()
                    }
                    BackgroundSection(editor: editor)
                    if !hasAndroid {
                        PanelDivider()
                        AndroidFrameSection(editor: editor)
                    }
                case .camera: CameraSection(editor: editor)
                case .audio: AudioPanel(editor: editor)
                case .output: OutputSection(editor: editor)
                case .device3D: Device3DSection(editor: editor)
                case .transcript, .subtitles: EmptyView()
                }
            }
            .padding(18)
        }
        .scrollIndicators(.never)
    }
}

// MARK: - Selection

struct SelectionInspector: View {
    @ObservedObject var editor: EditorModel
    @State private var confirmDeleteTake = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.16)))
                    Text(title).font(.rounded(16, .semibold))
                    Spacer()
                    Button { withAnimation(Theme.swap) { editor.selection = nil } } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 26, iconSize: 11))
                        .help("Done")
                }
                content
            }
            .padding(18)
        }
        .scrollIndicators(.never)
    }

    private var title: String {
        switch editor.selection {
        case .zoom: "Zoom"
        case .camera: "Camera layout"
        case .section: editor.selectedSection.map { "Take \($0.clipIndex + 1)" } ?? "Section"
        case .music: "Music"
        case .transition: editor.selectedTransition?.transition.kind.name ?? "Transition"
        case .keyframe: "3D keyframe"
        case .redact: "Blur"
        case .spotlight: "Spotlight"
        case .annotation: "Drawing"
        case nil: ""
        }
    }

    private var symbol: String {
        switch editor.selection {
        case let .zoom(id):
            editor.project.zoomBlocks.first { $0.id == id }?.kind == .liquidGlass ? "drop" : "plus.magnifyingglass"
        case .camera: "person.crop.rectangle"
        case .music: "music.note"
        case .transition: editor.selectedTransition?.transition.kind.symbol ?? "rectangle.2.swap"
        case .keyframe: "diamond"
        case .redact: "eye.slash"
        case .spotlight: SpotlightLane.symbol
        case .annotation: AnnotationLane.symbol
        case .section, nil: "film"
        }
    }

    private var tint: Color {
        switch editor.selection {
        case .zoom: Theme.zoom
        case .camera: Theme.camera
        case .music: Theme.music
        case .transition: Color.white
        case .keyframe: Theme.phone
        case .redact: Theme.privacy
        case .spotlight: Theme.spotlight
        case .annotation: Theme.annotation
        case .section, nil: Theme.clip
        }
    }

    @ViewBuilder private var content: some View {
        switch editor.selection {
        case let .camera(id):
            if let block = editor.project.cameraBlocks.first(where: { $0.id == id }) {
                InfoRow(title: "Time", value: "\(format(block.start)) – \(format(block.end))")
                LayoutPicker(layout: Binding(get: { block.layout }, set: { editor.updateCamera(id, layout: $0) }))
                Button("Delete block") { editor.deleteSelection() }.buttonStyle(DestructiveButtonStyle())
            }
        case let .zoom(id):
            if let block = editor.project.zoomBlocks.first(where: { $0.id == id }) {
                ZoomInspector(editor: editor, block: block)
            }
        case .section:
            if let seg = editor.selectedSection {
                let clip = editor.project.clips[seg.clipIndex]
                PanelSection("Section") {
                    InfoRow(title: "From", value: format(seg.sourceStart))
                    InfoRow(title: "To", value: format(seg.sourceEnd))
                    InfoRow(title: "Length", value: format(seg.duration))
                    PanelNote("Drag the section's edges on the timeline to trim it. Split with ✂︎ at the playhead.")
                }
                SectionSpeedPicker(editor: editor, segment: seg)
                if editor.canDeleteSection {
                    Button("Delete this section") { editor.deleteSelectedSection() }
                        .buttonStyle(DestructiveButtonStyle())
                        .help("Removes just this part of the take (Delete key). ⌘Z undoes.")
                }
                PanelDivider()
                PanelSection("Take \(seg.clipIndex + 1)") {
                    InfoRow(title: "Recorded length", value: format(clip.duration))
                    InfoRow(title: "Screen", value: "\(Int(clip.screenPixelSize.width)) × \(Int(clip.screenPixelSize.height))")
                    InfoRow(title: "Camera", value: clip.cameraFile == nil ? "None" : "Yes")
                    InfoRow(title: "Microphone", value: clip.micFile == nil ? "None" : "Yes")
                    InfoRow(title: "Screen audio", value: clip.screenAudioFile == nil ? "None" : "Yes")
                    Button { editor.recordCamera(over: clip.id) } label: {
                        Label(clip.cameraFile == nil ? "Record camera over this take" : "Record the camera again",
                              systemImage: "video.badge.plus")
                    }
                    .buttonStyle(PillButtonStyle(fullWidth: true))
                    .help("Plays the take while your camera films, for a face cam over an imported video or a take recorded without one")
                }
                if editor.canDeleteClip {
                    Button("Delete whole take…") { confirmDeleteTake = true }
                        .buttonStyle(DestructiveButtonStyle())
                        .confirmationDialog("Delete take \(seg.clipIndex + 1)? It's removed when you close the project (⌘Z undoes until then).",
                                            isPresented: $confirmDeleteTake) {
                            Button("Delete take", role: .destructive) { editor.deleteClip(clip.id) }
                        }
                }
            }
        case .music:
            if let clip = editor.selectedMusic { MusicInspector(editor: editor, clip: clip) }
        case .transition:
            if let placed = editor.selectedTransition { TransitionInspector(editor: editor, placed: placed) }
        case .keyframe:
            if let key = editor.selectedKeyframe { KeyframeInspector(editor: editor, key: key) }
        case .redact:
            if let block = editor.selectedRedaction { RedactInspector(editor: editor, block: block) }
        case .spotlight:
            if let block = editor.selectedSpotlight { SpotlightInspector(editor: editor, block: block) }
        case .annotation:
            if let block = editor.selectedAnnotation { AnnotationInspector(editor: editor, block: block) }
        case nil:
            EmptyView()
        }
    }
}

private struct TransitionInspector: View {
    @ObservedObject var editor: EditorModel
    let placed: PlacedTransition

    var body: some View {
        let tr = placed.transition
        PanelSection("Effect") {
            TransitionPicker(selected: tr.kind, pick: { editor.setTransitionKind(tr.id, $0) }, width: nil)
        }
        PanelSection("Duration") {
            PanelSlider("Length", value: Binding(get: { tr.duration }, set: { v in editor.updateTransition(tr.id) { $0.duration = v } }),
                        in: ClipTransition.durationRange, default: tr.kind.defaultDuration) { String(format: "%.1fs", $0) }
            if placed.duration < tr.duration - 0.05 {
                PanelNote("Shortened to \(String(format: "%.1fs", placed.duration)) to fit the sections either side.")
            }
        }
        Button("Remove transition") { editor.removeTransition(tr.id) }
            .buttonStyle(DestructiveButtonStyle())
    }
}
