//
//  LiveBar.swift
//  Slice
//
//  Created by rit3zh CX on 10/20/26.
//

import SliceCore
import SwiftUI

/// The bar while recording: finish with the time, then pause, restart and delete, then draw, opening out into the
/// drawing tools after it while drawing is on.
struct LiveBar: View {
    @ObservedObject var recording: RecordingController
    let drawing: Bool
    let session: AnnotationSession?

    static let pad: CGFloat = 12
    static let grip: CGFloat = 18
    static let finish: CGFloat = 104
    static let icon: CGFloat = 40
    static let round: CGFloat = 44
    static let item: CGFloat = 32
    static let swatch: CGFloat = 22
    static let size: CGFloat = 24
    static let dividerPad: CGFloat = 8
    static var divider: CGFloat { 1 + dividerPad * 2 }
    /// The bar opening into the tools and closing again: no overshoot, so the surface, the buttons riding its edges
    /// and the tools fading in all move as one.
    static let expand = Animation.spring(duration: 0.46, bounce: 0)

    static var plainWidth: CGFloat { pad * 1.5 + grip + finish + divider + icon * 3 }
    static var liveWidth: CGFloat { plainWidth + divider + icon }
    static var drawingWidth: CGFloat {
        let tools = CGFloat(Annotation.Tool.allCases.count) * item
        let colors = CGFloat(AnnotationSession.colors.count) * swatch
        let widths = CGFloat(AnnotationSession.widths.count) * size
        return liveWidth + 4 * divider + tools + colors + widths + 2 * item
    }

    var body: some View {
        let paused = recording.phase == .paused
        HStack(spacing: 0) {
            BarGrip()
            FinishButton(elapsed: recording.elapsed, paused: paused) { recording.stop() }
            ToolDivider()
            PauseButton(paused: paused) { recording.togglePause() }
            LiveIcon(symbol: "arrow.counterclockwise", help: "Restart: delete this recording and start again") { recording.restart() }
            LiveIcon(symbol: "trash", help: "Delete this recording") { recording.delete() }
            if let session {
                ToolDivider()
                LiveDrawButton(session: session)
                if drawing {
                    AnnotationTools(session: session, trailingDivider: false)
                        .transition(.toolsReveal)
                }
            }
        }
        .padding(.leading, Self.pad / 2)
        .padding(.trailing, Self.pad)
        .frame(height: 72)
        // Anywhere that isn't a button moves the bar, so it can be taken out of the way mid-recording.
        .barDragBackground()
        .animation(Self.expand, value: drawing)
    }
}

extension AnyTransition {
    /// In once the bar has started opening; out quickly, before the bar closes over it.
    static var toolsReveal: AnyTransition {
        .asymmetric(insertion: .modifier(active: SoftFocus(amount: 1), identity: SoftFocus(amount: 0))
                        .animation(.smooth(duration: 0.34).delay(0.1)),
                    removal: .modifier(active: SoftFocus(amount: 1), identity: SoftFocus(amount: 0))
                        .animation(.easeOut(duration: 0.12)))
    }
}

private struct SoftFocus: ViewModifier {
    let amount: Double

    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .scaleEffect(1 - 0.03 * amount)
    }
}

struct DrawToggle: View {
    @ObservedObject var session: AnnotationSession
    @State private var hovering = false

    var body: some View {
        let on = session.isActive
        Button { AnnotationController.shared.toggleDrawing() } label: {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.white.opacity(on || hovering ? 1 : 0.85))
                .frame(width: LiveBar.round, height: LiveBar.round)
                .background(Circle().fill(on ? Theme.accent.opacity(hovering ? 0.95 : 0.85)
                    : Color.white.opacity(hovering ? 0.16 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.88))
        .help(on ? "Stop drawing (esc)" : "Draw on screen (\(AnnotationController.toggleLabel))")
        .onHover { hovering = $0 }
        .animation(Bar.hover, value: hovering)
        .animation(Bar.hover, value: on)
    }
}

struct AnnotationTools: View {
    @ObservedObject var session: AnnotationSession
    var trailingDivider = true
    @Namespace private var picked

    var body: some View {
        HStack(spacing: 0) {
            ToolDivider()
            ForEach(Annotation.Tool.allCases, id: \.self) { tool in
                ToolButton(tool: tool, selected: session.tool == tool, namespace: picked) { session.tool = tool }
            }
            ToolDivider()
            ForEach(AnnotationSession.colors.indices, id: \.self) { i in
                Swatch(color: AnnotationSession.colors[i], selected: session.colorIndex == i) { session.colorIndex = i }
            }
            ToolDivider()
            ForEach(AnnotationSession.widths.indices, id: \.self) { i in
                WidthDot(index: i, selected: session.widthIndex == i) { session.widthIndex = i }
            }
            ToolDivider()
            BarIcon(symbol: "arrow.uturn.backward", help: "Undo  ⌘Z") { session.undo() }
                .disabled(!session.canUndo)
            BarIcon(symbol: "trash", help: "Clear all  ⌘⌫") { session.clear() }
                .disabled(!session.canUndo)
            if trailingDivider { ToolDivider() }
        }
    }
}

private struct ToolDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 22)
            .padding(.horizontal, LiveBar.dividerPad)
    }
}

private struct BarIcon: View {
    let symbol: String
    var selected = false
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(!isEnabled ? 0.25 : selected || hovering ? 1 : 0.62))
                .frame(width: LiveBar.item, height: LiveBar.item)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.16 : hovering && isEnabled ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.9))
        .help(help)
        .onHover { hovering = $0 }
        .animation(Bar.hover, value: hovering)
        .animation(Bar.hover, value: selected)
    }
}

/// A drawing tool; the picked one sits on a highlight that slides from tool to tool.
private struct ToolButton: View {
    let tool: Annotation.Tool
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(selected || hovering ? 1 : 0.62))
                .frame(width: LiveBar.item, height: LiveBar.item)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.18))
                            .matchedGeometryEffect(id: "tool", in: namespace)
                    } else if hovering {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.08))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.9))
        .help("\(tool.title)  \(tool.key.uppercased())")
        .onHover { hovering = $0 }
        .animation(Bar.hover, value: hovering)
        .animation(.spring(duration: 0.3, bounce: 0), value: selected)
    }
}

private struct Swatch: View {
    let color: RGBA
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(.sRGB, red: color.r, green: color.g, blue: color.b))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
                .frame(width: 14, height: 14)
                .scaleEffect(hovering && !selected ? 1.12 : 1)
                .padding(3)
                .overlay(Circle().strokeBorder(Color.white.opacity(selected ? 0.95 : 0), lineWidth: 1.5))
                .frame(width: LiveBar.swatch, height: LiveBar.item)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.88))
        .onHover { hovering = $0 }
        .animation(Bar.hover, value: hovering)
        .animation(Bar.hover, value: selected)
    }
}

private struct WidthDot: View {
    let index: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let d: CGFloat = [4, 7, 11][min(index, 2)]
        Button(action: action) {
            Circle()
                .fill(Color.white.opacity(selected ? 1 : hovering ? 0.75 : 0.4))
                .frame(width: d, height: d)
                .frame(width: LiveBar.size, height: LiveBar.item)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.88))
        .help(["Thin", "Medium", "Thick"][min(index, 2)])
        .onHover { hovering = $0 }
        .animation(Bar.hover, value: hovering)
        .animation(Bar.hover, value: selected)
    }
}

extension Annotation.Tool {
    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        }
    }

    /// Picks the tool while drawing, alongside its number.
    var key: String {
        switch self {
        case .pen: "p"
        case .highlighter: "h"
        case .line: "l"
        case .arrow: "a"
        case .rectangle: "r"
        case .ellipse: "o"
        case .text: "t"
        }
    }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .line: "Line"
        case .arrow: "Arrow"
        case .rectangle: "Rectangle"
        case .ellipse: "Oval"
        case .text: "Text"
        }
    }
}
