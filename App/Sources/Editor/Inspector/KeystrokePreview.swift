//
//  KeystrokePreview.swift
//  Slice
//
//  Created by rit3zh CX on 11/12/26.
//

import SliceCore
import SwiftUI

/// A small frame showing presses as the video will: in the chosen style and layout, at the chosen spot. Drag the
/// press to one of the six spots, or click one, to move it there.
struct KeystrokePreview: View {
    @Binding var settings: KeystrokeSettings
    let captions: Bool
    @State private var shown: [Shown] = []
    @State private var next = 0
    @State private var typed = 0
    @State private var drag: CGSize = .zero
    @State private var target: Spot?

    private enum Sample: Equatable {
        case keys([String])
        case text(String)
    }

    private struct Shown: Identifiable, Equatable {
        let id: Int
        let sample: Sample
    }

    private var samples: [Sample] {
        let shortcuts: [Sample] = [.keys(["⌘", "K"]), .keys(["⇧", "⌘", "P"]), .keys(["⌘", "Z"]), .keys(["⌥", "⌘", "←"])]
        switch settings.show {
        case .shortcuts: return shortcuts
        case .keys: return [shortcuts[0], .keys(["esc"]), shortcuts[1], .keys(["↩"])]
        case .typing: return [.text("Typing fast slides the oldest words away"), shortcuts[0], .text("Ship it"), .keys(["↩"])]
        }
    }

    private var spot: Spot { Spot(position: settings.position, alignment: settings.alignment) }
    private var stacked: Bool { settings.layout == .stack }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        GeometryReader { geo in
            ZStack {
                shape.fill(Color.white.opacity(0.025))
                page
                if drag != .zero { spots(in: geo.size) }
                if settings.visible || captions {
                    VStack(alignment: horizontal, spacing: 6) {
                        if captions && settings.position == .top { caption }
                        if settings.visible { presses }
                        if captions && settings.position == .bottom { caption }
                    }
                    .fixedSize()
                    .offset(drag)
                    .padding(14)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: spot.frameAlignment)
                    .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard settings.visible else { return }
                    drag = v.translation
                    target = Spot(at: v.location, in: geo.size)
                }
                .onEnded { v in
                    guard settings.visible else { return }
                    let landed = Spot(at: v.location, in: geo.size)
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
                        settings.position = landed.position
                        settings.alignment = landed.alignment
                        drag = .zero
                    }
                    target = nil
                })
            .pointerStyle(settings.visible ? (drag == .zero ? .grabIdle : .grabActive) : .default)
        }
        .frame(height: 124)
        .overlay(shape.strokeBorder(Theme.stroke))
        .animation(Theme.slide, value: captions)
        .task(id: "\(settings.visible)\(settings.show)\(settings.layout)") { await play() }
        .help(settings.visible ? "Drag to move where keystrokes appear" : "")
    }

    private var horizontal: HorizontalAlignment {
        switch settings.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    // MARK: - Playing

    /// Shows the samples one after another, typing lines out a letter at a time. Stacked, the last few stay up.
    private func play() async {
        shown = []
        typed = 0
        while settings.visible && !Task.isCancelled {
            let sample = samples[next % samples.count]
            next += 1
            withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
                shown = stacked ? Array((shown + [Shown(id: next, sample: sample)]).suffix(3)) : [Shown(id: next, sample: sample)]
            }
            typed = 0
            if case let .text(line) = sample {
                for n in 1 ... line.count {
                    withAnimation(.easeOut(duration: 0.22)) { typed = n }
                    try? await Task.sleep(for: .milliseconds(Int.random(in: 45 ... 95)))
                    if Task.isCancelled { return }
                }
                try? await Task.sleep(for: .seconds(1.2))
            } else {
                try? await Task.sleep(for: .seconds(stacked ? 1.0 : 1.6))
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder private var presses: some View {
        let order = settings.position == .bottom ? shown : shown.reversed()
        VStack(alignment: horizontal, spacing: 5) {
            ForEach(order) { item in
                let age = shown.count - 1 - (shown.firstIndex(of: item) ?? 0)
                chip(item.sample, newest: age == 0)
                    .opacity(age == 0 ? 1 : age == 1 ? 0.7 : 0.4)
                    .transition(.keycap)
            }
        }
    }

    @ViewBuilder private func chip(_ sample: Sample, newest: Bool) -> some View {
        switch sample {
        case let .keys(keys):
            if settings.style == .keycaps {
                HStack(spacing: 4) { ForEach(Array(keys.enumerated()), id: \.offset) { _, key in Keycap(label: key) } }
            } else {
                Plate(style: settings.style) {
                    Text(keys.count > 1 ? keys.dropLast().joined() + " " + keys.last! : keys[0]).fontWeight(.semibold)
                }
            }
        case let .text(line):
            Plate(style: settings.style == .keycaps ? .dark : settings.style) {
                TypedLine(text: newest ? String(line.prefix(max(typed, 1))) : line)
            }
        }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 7) {
            Capsule().frame(width: 92, height: 5)
            Capsule().frame(width: 140, height: 5)
            Capsule().frame(width: 64, height: 5)
        }
        .foregroundStyle(Color.white.opacity(0.05))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 18)
    }

    /// The six places it can go, shown while dragging, the one under the pointer lit.
    private func spots(in size: CGSize) -> some View {
        ForEach(Spot.all, id: \.self) { s in
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.accent.opacity(s == target ? 0.14 : 0))
                .strokeBorder(s == target ? Theme.accent.opacity(0.7) : Color.white.opacity(0.12),
                              style: StrokeStyle(lineWidth: 1, dash: s == target ? [] : [3, 3]))
                .frame(width: size.width / 3 - 8, height: size.height / 2 - 8)
                .position(x: size.width * (CGFloat(s.column) + 0.5) / 3, y: size.height * (s.position == .top ? 0.25 : 0.75))
                .animation(Theme.hover, value: target)
        }
        .transition(.opacity)
    }

    private var caption: some View {
        HStack(spacing: 5) {
            ForEach([26, 18, 34, 22], id: \.self) { w in
                Capsule().fill(Color.white.opacity(0.45)).frame(width: CGFloat(w), height: 5)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.09)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .transition(.opacity)
    }
}

/// A typed line whose newest letters come into focus, out of a blur, as they do in the video. Past a set width it
/// slides along, its oldest letters fading off the front.
private struct TypedLine: View {
    let text: String
    @State private var natural: CGFloat = 0

    private static let window: CGFloat = 150

    var body: some View {
        let scrolls = natural > Self.window
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { _, c in
                Text(String(c)).transition(.letter)
            }
        }
        .fontWeight(.medium)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { natural = $0 }
        .frame(width: min(natural, Self.window), alignment: .trailing)
        .clipped()
        .mask {
            LinearGradient(stops: [.init(color: .black.opacity(scrolls ? 0 : 1), location: 0), .init(color: .black, location: 0.24)],
                           startPoint: .leading, endPoint: .trailing)
        }
        .animation(.easeOut(duration: 0.18), value: natural)
    }
}

/// One of the six places keystrokes can sit.
private struct Spot: Hashable {
    var position: KeystrokeSettings.Position
    var alignment: KeystrokeSettings.Alignment

    static let all = KeystrokeSettings.Position.allCases.flatMap { p in
        KeystrokeSettings.Alignment.allCases.map { Spot(position: p, alignment: $0) }
    }

    init(position: KeystrokeSettings.Position, alignment: KeystrokeSettings.Alignment) {
        self.position = position
        self.alignment = alignment
    }

    /// The spot under a point in a frame `size` big.
    init(at p: CGPoint, in size: CGSize) {
        let column = min(max(Int(p.x / max(size.width, 1) * 3), 0), 2)
        position = p.y < size.height / 2 ? .top : .bottom
        alignment = KeystrokeSettings.Alignment.allCases[column]
    }

    var column: Int { KeystrokeSettings.Alignment.allCases.firstIndex(of: alignment)! }

    var frameAlignment: Alignment {
        switch (position, alignment) {
        case (.top, .leading): .topLeading
        case (.top, .center): .top
        case (.top, .trailing): .topTrailing
        case (.bottom, .leading): .bottomLeading
        case (.bottom, .center): .bottom
        case (.bottom, .trailing): .bottomTrailing
        }
    }
}

/// A press on a plate, dark or light, or as bare text for the minimal style.
private struct Plate<Content: View>: View {
    let style: KeystrokeSettings.Style
    @ViewBuilder var content: Content

    var body: some View {
        let light = style == .light
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        content
            .font(.system(size: 12.5))
            .foregroundStyle(light ? Color.black.opacity(0.85) : Color.white.opacity(0.95))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, style == .minimal ? 0 : 9)
            .frame(minWidth: style == .minimal ? 0 : 28, minHeight: 26)
            .background {
                if style != .minimal {
                    shape.fill(light ? AnyShapeStyle(LinearGradient(colors: [Color(white: 0.93), .white], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(LinearGradient(colors: [Color(red: 0.03, green: 0.02, blue: 0.045),
                                                                Color(red: 0.11, green: 0.09, blue: 0.14)],
                                                       startPoint: .top, endPoint: .bottom)))
                        .overlay(shape.strokeBorder(light ? Color.black.opacity(0.08) : Color.white.opacity(0.09)))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1.5)
                }
            }
            .shadow(color: style == .minimal ? .black.opacity(0.8) : .clear, radius: 3, y: 1)
    }
}

/// A key seen from the front, as the keycaps style draws it.
private struct Keycap: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 7)
            .frame(minWidth: 26, minHeight: 23)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.27), Color(white: 0.17)], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.white.opacity(0.1))))
            .padding(.horizontal, 1.5)
            .padding(.top, 1)
            .padding(.bottom, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(white: 0.05)))
            .shadow(color: .black.opacity(0.4), radius: 2.5, y: 1.5)
    }
}

private struct KeycapFocus: ViewModifier {
    let blur: CGFloat
    let opacity: Double
    let scale: CGFloat
    let drop: CGFloat

    func body(content: Content) -> some View {
        content.blur(radius: blur).scaleEffect(scale).offset(y: drop).opacity(opacity)
    }
}

private extension AnyTransition {
    static var keycap: AnyTransition {
        let sharp = KeycapFocus(blur: 0, opacity: 1, scale: 1, drop: 0)
        return .asymmetric(
            insertion: .modifier(active: KeycapFocus(blur: 8, opacity: 0, scale: 0.92, drop: 6), identity: sharp)
                .animation(.timingCurve(0.215, 0.61, 0.355, 1, duration: 0.32).delay(0.05)),
            removal: .modifier(active: KeycapFocus(blur: 8, opacity: 0, scale: 0.95, drop: 0), identity: sharp)
                .animation(.easeIn(duration: 0.12)))
    }

    /// A letter coming into focus from a little below, as typed letters do in the video.
    static var letter: AnyTransition {
        .asymmetric(insertion: .modifier(active: KeycapFocus(blur: 4, opacity: 0, scale: 1, drop: 3),
                                         identity: KeycapFocus(blur: 0, opacity: 1, scale: 1, drop: 0)),
                    removal: .opacity)
    }
}
