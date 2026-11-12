//
//  CameraSection.swift
//  Slice
//
//  Created by rit3zh CX on 10/9/26.
//

import SliceCore
import SwiftUI

struct CameraSection: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        if let target = editor.overdubTarget, editor.project.clips[target.index].cameraFile == nil {
            PanelSection("Take \(target.index + 1) has no camera") {
                PanelNote("Film yourself over it: the take plays while your camera records.")
                Button { editor.recordCamera(over: target.id) } label: {
                    Label("Record camera over this take", systemImage: "video.badge.plus")
                }
                .buttonStyle(PillButtonStyle(fullWidth: true))
            }
            PanelDivider()
        }
        PanelSection("Default layout") {
            PanelNote("Used wherever no camera block is set on the timeline.")
            LayoutPicker(layout: $editor.project.defaultCamera)
        }
        PanelDivider()
        PanelSection("Style") {
            PanelToggle("Mirror camera", isOn: $editor.project.style.mirrorCamera)
            PanelSlider("Background blur", value: $editor.project.style.cameraBackgroundBlur, in: 0 ... 1, default: 0) {
                $0 < 0.01 ? "Off" : "\(Int($0 * 100))%"
            }
            PanelSlider("Corner radius", value: $editor.project.style.cameraCornerRadius, in: 0 ... 0.5,
                        default: FrameStyle().cameraCornerRadius) { percent($0, of: 0 ... 0.5) }
        }
        PanelDivider()
        PanelSection("Filter", trailing: AnyView(
            Text(editor.project.style.cameraFilter.label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.snappy, value: editor.project.style.cameraFilter)
        )) {
            CameraFilterPicker(filter: $editor.project.style.cameraFilter)
        }
        MoreOptions(id: "camera") {
            PanelSlider("Layout change speed", value: $editor.project.style.transitionDuration, in: 0.2 ... 1.5,
                        default: FrameStyle().transitionDuration) { String(format: "%.1fs", $0) }
                .help("How long the camera takes to move when a camera layout on the timeline starts or ends")
            PanelSlider("Size when zoomed in", value: $editor.project.style.cameraZoomScale, in: 0.5 ... 1.5,
                        default: FrameStyle().cameraZoomScale) { "\(Int(($0 * 100).rounded()))%" }
            PanelNote("The camera grows or shrinks with each zoom. 100% keeps it the same size.")
        }
    }
}

struct LayoutPicker: View {
    @Binding var layout: CameraLayout

    private enum Position: Hashable { case corner(Corner), centre, split(SplitSide), fullscreen, hidden }
    private enum Style: Hashable { case bubble, split, fullscreen }

    private var position: Position {
        switch layout {
        case .hidden: .hidden
        case .centre: .centre
        case let .corner(c, _, _): .corner(c)
        case let .split(side, _): .split(side)
        case .fullscreen: .fullscreen
        }
    }

    private var style: Style {
        switch layout {
        case .split: .split
        case .fullscreen: .fullscreen
        default: .bubble
        }
    }

    private var shape: CameraShape { if case let .corner(_, s, _) = layout { s } else { .square } }
    private var size: CameraSize { if case let .corner(_, _, z) = layout { z } else { .small } }
    private var coverage: Double { if case let .centre(c) = layout { c } else { 0.6 } }
    private var side: SplitSide { if case let .split(s, _) = layout { s } else { .right } }
    private var share: Double? { if case let .split(_, s) = layout { s } else { nil } }
    /// The camera's part of the split: fitted to the screen, then half, a third and a quarter.
    private static let shares: [Double?] = [nil, 1 / 2, 1 / 3, 1 / 4]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SegmentedControl(selection: Binding(get: { style }, set: { next in
                switch next {
                case .bubble: layout = .corner(.bottomRight, shape, size)
                case .split: layout = .split(side, share: share)
                case .fullscreen: layout = .fullscreen
                }
            }), options: [.bubble, .split, .fullscreen], title: { s in
                switch s {
                case .bubble: "Bubble"
                case .split: "Split"
                case .fullscreen: "Full"
                }
            }, symbol: { s in
                switch s {
                case .bubble: "pip"
                case .split: "rectangle.split.2x1"
                case .fullscreen: "person.crop.rectangle"
                }
            })
            .disabled(position == .hidden)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.04))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                GeometryReader { geo in
                    let w = geo.size.width, h = geo.size.height
                    switch style {
                    case .bubble:
                        ForEach(Corner.allCases, id: \.self) { c in
                            let x = (c == .topLeft || c == .bottomLeft) ? w * 0.2 : w * 0.8
                            let y = (c == .topLeft || c == .topRight) ? h * 0.24 : h * 0.76
                            ZoneButton(selected: position == .corner(c), width: w * 0.24, height: h * 0.3) {
                                layout = .corner(c, shape, size)
                            }
                            .position(x: x, y: y)
                            .help("Corner")
                        }
                        ZoneButton(selected: position == .centre, width: w * 0.36, height: h * 0.4) {
                            layout = .centre(coverage: coverage)
                        }
                        .position(x: w / 2, y: h / 2)
                        .help("Centre, large")
                    case .split:
                        // 4% margins and gap, the rest shared out as the split is.
                        let camera = w * 0.88 * (share ?? 0.32), screen = w * 0.88 - camera
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .frame(width: screen, height: h * 0.84)
                            .position(x: side == .left ? w * 0.96 - screen / 2 : w * 0.04 + screen / 2, y: h / 2)
                        ForEach(SplitSide.allCases, id: \.self) { s in
                            ZoneButton(selected: position == .split(s), width: camera, height: h * 0.84) {
                                layout = .split(s, share: share)
                            }
                            .position(x: s == .left ? w * 0.04 + camera / 2 : w * 0.96 - camera / 2, y: h / 2)
                            .opacity(position == .split(s) ? 1 : 0.7)
                            .help(s == .left ? "Camera on the left" : "Camera on the right")
                        }
                    case .fullscreen:
                        ZoneButton(selected: true, width: w * 0.92, height: h * 0.88) {}
                            .position(x: w / 2, y: h / 2)
                            .help("The camera fills the frame")
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .opacity(position == .hidden ? 0.4 : 1)

            PanelToggle("Hide camera", isOn: Binding(get: { position == .hidden }, set: { hide in
                layout = hide ? .hidden : .corner(.bottomRight, shape, size)
            }))

            switch position {
            case .corner(let c):
                SegmentedControl(selection: Binding(get: { shape }, set: { layout = .corner(c, $0, size) }),
                                 options: [.landscape, .portrait, .square], title: { $0.rawValue.capitalized },
                                 symbol: { s in
                                     switch s {
                                     case .landscape: "rectangle"
                                     case .portrait: "rectangle.portrait"
                                     case .square: "square"
                                     }
                                 })
                SegmentedControl(selection: Binding(get: { size }, set: { layout = .corner(c, shape, $0) }),
                                 options: [.small, .large], title: { $0 == .small ? "Small" : "Large" })
            case .centre:
                PanelSlider("Size", value: Binding(get: { coverage }, set: { layout = .centre(coverage: $0) }), in: 0.3 ... 1) {
                    "\(Int($0 * 100))% of width"
                }
            case let .split(s):
                SegmentedControl(selection: Binding(get: { share }, set: { layout = .split(s, share: $0) }),
                                 options: Self.shares, title: { share in
                                     share.map { "\(Int((100 * (1 - $0)).rounded())) / \(Int((100 * $0).rounded()))" } ?? "Auto"
                                 })
                    .help("How the frame is shared between the screen and the camera")
                PanelNote(share == nil
                    ? "The screen moves aside to share the frame. In a tall video the camera goes above or below it."
                    : "Screen / camera. The two stay this size whatever the screen's shape, with all of the screen showing.")
            case .fullscreen:
                PanelNote("The camera fills the whole frame, over the screen.")
            case .hidden:
                EmptyView()
            }
        }
        .animation(.snappy, value: layout)
    }
}

private struct ZoneButton: View {
    let selected: Bool
    let width: CGFloat
    let height: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(selected ? Theme.accent : Color.white.opacity(hovering ? 0.22 : 0.12))
                .frame(width: width, height: height)
                .scaleEffect(hovering && !selected ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
        .animation(Theme.hover, value: selected)
    }
}
