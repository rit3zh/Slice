//
//  CaptureBarControls.swift
//  Slice
//
//  Created by rit3zh CX on 10/1/26.
//

import AppKit
import SwiftUI

/// Dots at the leading edge saying the bar can be dragged; the drag itself works from any gap in the bar. A double-click
/// puts the bar back at the top centre.
struct BarGrip: View {
    @State private var hovering = false

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            ForEach(0 ..< 3, id: \.self) { _ in
                GridRow {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(.white.opacity(hovering ? 0.6 : 0.3))
        .frame(width: LiveBar.grip, height: 44)
        // On top, not behind: SwiftUI keeps presses on views it tracks the pointer over, so a drag view underneath
        // never heard of them.
        .overlay(BarDragArea(resetsOnDoubleClick: true, tooltip: "Drag to move, double-click to put back") { hovering = $0 })
        .animation(Bar.hover, value: hovering)
    }
}

extension View {
    /// Gaps between the bar's buttons move the window.
    func barDragBackground() -> some View {
        background(BarDragArea(resetsOnDoubleClick: false))
    }
}

/// Moves the bar's window from a press on it. It sees the mouse-down itself, so a drag starts on the first press
/// whether or not the bar is the active window. It shows the open hand and reports the pointer coming and going, as
/// SwiftUI's hover would.
struct BarDragArea: NSViewRepresentable {
    var resetsOnDoubleClick: Bool
    var tooltip: String?
    var onHover: ((Bool) -> Void)?

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.resetsOnDoubleClick = resetsOnDoubleClick
        view.toolTip = tooltip
        view.onHover = onHover
    }

    final class DragView: NSView {
        var resetsOnDoubleClick = false
        var onHover: ((Bool) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Where the press started on screen, and where the window was then.
        private var start: (mouse: NSPoint, origin: NSPoint)?

        // The window is moved here by hand: AppKit's own `performDrag` doesn't start on this SwiftUI window ("window move
        // completed without beginning"), and neither did SwiftUI's `WindowDragGesture`.
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                if resetsOnDoubleClick { BarPosition.reset() }
                return
            }
            guard let window else { return }
            start = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
            NSCursor.closedHand.push()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start, let window else { return }
            let p = window.convertPoint(toScreen: event.locationInWindow)
            window.setFrameOrigin(NSPoint(x: start.origin.x + p.x - start.mouse.x, y: start.origin.y + p.y - start.mouse.y))
        }

        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            start = nil
            NSCursor.pop()
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }
}

struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.2 : 0.1)))
                .overlay(Circle().strokeBorder(Color.white.opacity(hovering ? 0.2 : 0.08), lineWidth: 1))
                .rotationEffect(.degrees(hovering ? 90 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.86))
        .keyboardShortcut(.cancelAction)
        .help("Close (esc)")
        .onHover { hovering = $0 }
        .animation(Bar.hover, value: hovering)
    }
}

struct SourceTile: View {
    let kind: CaptureBar.Kind
    let selected: Bool
    let hasChoices: Bool
    let enabled: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @Environment(\.barGlide) private var glide

    private var hovering: Bool { GlideState(glide: glide).hovering(kind) && enabled }

    private var symbol: String {
        switch kind {
        case .display: "menubar.dock.rectangle"
        case .window: "macwindow"
        case .area: "rectangle.dashed"
        case .device: "iphone"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .regular))
                    .symbolEffect(.bounce.down, value: selected)
                    .frame(height: 24)
                HStack(spacing: 3) {
                    Text(kind.rawValue)
                    if selected && hasChoices {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7, weight: .heavy))
                            .opacity(0.6)
                            .transition(.opacity.combined(with: .scale(scale: 0.6)))
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .animation(Bar.hover, value: selected && hasChoices)
            }
            .foregroundStyle(.white.opacity(!enabled ? 0.25 : selected ? 1 : hovering ? 0.92 : 0.62))
            .frame(width: 70, height: 58)
            .background {
                ZStack {
                    if selected {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.14))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
            }
            .glideHover(kind, enabled: enabled)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.93))
        .disabled(!enabled)
        .animation(Bar.hover, value: hovering)
    }
}

struct BarPill<Label: View>: View {
    let id: String
    var width: CGFloat?
    let open: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.barGlide) private var glide

    private var hovering: Bool { GlideState(glide: glide).hovering(id) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                label
                if width != nil { Spacer(minLength: 0) }
            }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(open || hovering ? 0.96 : 0.72))
                .padding(.horizontal, 12)
                .frame(width: width, height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(open ? 0.1 : 0)))
                .glideHover(id)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.96))
        .animation(Bar.hover, value: hovering)
        .animation(Bar.hover, value: open)
    }
}

struct PillLabel: View {
    let caption: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(caption)
                .font(.system(size: 9.5, weight: .semibold))
                .opacity(0.55)
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

struct AreaPanel: View {
    @ObservedObject var overlay: AreaOverlay
    let redraw: () -> Void
    @State private var glide = HoverGlide()
    @Namespace private var hoverSpace
    @Namespace private var selection

    private var size: String? {
        guard case let .area(_, r) = overlay.area else { return nil }
        return "\(Int(r.width)) × \(Int(r.height))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle("Shape")
                    Spacer()
                    if let size {
                        Text(size)
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.2), value: size)
                    }
                }
                HStack(spacing: 4) {
                    ForEach(AreaOverlay.Shape.allCases) { shape in
                        ShapeChip(shape: shape, selected: overlay.shape == shape, namespace: selection) {
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { overlay.setShape(shape) }
                        }
                        .help(shape.help)
                    }
                }
            }
            Divider()
            VStack(spacing: 2) {
                PickerRow(title: "Draw a new area", selected: false, symbol: "rectangle.dashed", action: redraw)
                PickerRow(title: "Move to the middle", selected: false, symbol: "rectangle.center.inset.filled") { overlay.center() }
            }
            .padding(.horizontal, -8)
            Label("Drag the area on screen to move it, or drag its edges to resize it.", systemImage: "hand.draw")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12.5))
        .padding(14)
        .frame(width: 300)
        .environment(\.barGlide, BarGlide(tracker: glide, namespace: hoverSpace))
        .barPopoverAppearance()
    }
}

struct ShapeChip: View {
    let shape: AreaOverlay.Shape
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void
    @Environment(\.barGlide) private var glide

    private var hovering: Bool { GlideState(glide: glide).hovering(shape) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                glyph.frame(width: 26, height: 20)
                Text(shape.title).font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white.opacity(selected ? 1 : hovering ? 0.9 : 0.6))
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                        .matchedGeometryEffect(id: "shape", in: namespace)
                }
            }
            .glideHover(shape, cornerRadius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle(scale: 0.94))
        .animation(Bar.hover, value: hovering)
    }

    @ViewBuilder private var glyph: some View {
        if let ratio = shape.ratio {
            let w = min(24, 18 * ratio)
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(lineWidth: 1.5)
                .frame(width: w, height: w / ratio)
        } else {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                .frame(width: 22, height: 16)
        }
    }
}

struct LevelBars: View {
    let level: Float
    private var fraction: Double { Double(min(max((level + 55) / 50, 0), 1)) }

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0 ..< 4, id: \.self) { i in
                let lit = fraction > Double(i) / 4 + 0.04
                let peak: [CGFloat] = [8, 13, 10, 6]
                Capsule()
                    .fill(lit ? Color(red: 0.35, green: 0.9, blue: 0.5) : Color.white.opacity(0.2))
                    .frame(width: 3, height: lit ? peak[i] : 4)
            }
        }
        .frame(height: 14)
        .animation(.spring(response: 0.16, dampingFraction: 0.7), value: fraction)
    }
}

struct RecordButton: View {
    let title: String
    let ready: Bool
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    private var live: Bool { ready && enabled }

    private var fill: Color {
        if live { return hovering ? Color(red: 0.96, green: 0.3, blue: 0.29) : Color(red: 0.9, green: 0.22, blue: 0.22) }
        return Color.white.opacity(hovering && enabled ? 0.14 : 0.08)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if live {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(title)
                    .contentTransition(.interpolate)
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.white.opacity(enabled ? 1 : 0.4))
            .padding(.horizontal, 18)
            .frame(height: 40)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScaleStyle(scale: 0.94))
        .disabled(!enabled)
        .keyboardShortcut(.defaultAction)
        .onHover { hovering = $0 }
        .animation(Bar.hover, value: hovering)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: live)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: title)
    }
}

struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Bar.press, value: configuration.isPressed)
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

struct PickerList<Rows: View>: View {
    let title: String
    var scrolls = false
    @ViewBuilder let rows: Rows
    @State private var glide = HoverGlide()
    @Namespace private var hoverSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title).padding(.horizontal, 8).padding(.top, 4)
            if scrolls {
                ScrollView { VStack(spacing: 2) { rows } }
                    .scrollIndicators(.never)
                    .frame(height: 340)
            } else {
                VStack(spacing: 2) { rows }
            }
        }
        .padding(8)
        .frame(width: 300)
        .environment(\.barGlide, BarGlide(tracker: glide, namespace: hoverSpace))
        .barPopoverAppearance()
    }
}

extension View {
    /// Keeps a bar popover dark like the bar. A popover's glass follows the system appearance, not the bar's, so on a
    /// light system it came up light under the bar's white text.
    func barPopoverAppearance() -> some View {
        environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
            .background(BarPopoverWindow())
    }
}
