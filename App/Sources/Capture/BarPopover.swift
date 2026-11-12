//
//  BarPopover.swift
//  Slice
//
//  Created by rit3zh CX on 10/1/26.
//

import SwiftUI

/// `preferredColorScheme` doesn't reach a popover's own window, so its AppKit controls (segmented picker, switches)
/// still drew light: white selected segment under white text. Pinning the window's appearance fixes them and the glass.
/// The bar never takes focus, so its popovers opened unfocused and drew their controls grey until clicked; each one is
/// made key as it opens so they show the accent straight away.
struct BarPopoverWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.appearance = NSAppearance(named: .darkAqua)
            DispatchQueue.main.async { [weak window] in
                guard let window, window.isVisible, !window.isKeyWindow else { return }
                window.makeKey()
            }
        }
    }
}

struct PickerRow: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    var symbol: String?
    var icon: NSImage?
    var onHover: ((Bool) -> Void)?
    let action: () -> Void
    @State private var id = UUID()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else if let symbol {
                        Image(systemName: symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glideHover(id, cornerRadius: 8, opacity: 0.1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { onHover?($0) }
    }
}

struct BarWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            AppModel.captureBarWindow = window
            AppModel.shared.prewarmMainWindow()
            if AppModel.shared.launchedWithProject {
                window.alphaValue = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { window.alphaValue = 1 }
            }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = AnnotationController.shared.barLevel
            window.isMovableByWindowBackground = true
            window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.appearance = NSAppearance(named: .darkAqua)
            BarPosition.restore(window)
        }
    }
}

/// Where the bar was last dragged to, so it opens there again. Placed after SwiftUI's own placement has run, and always
/// with the whole bar on one display: a saved centre that's on screen could still leave the record button off its edge.
@MainActor
enum BarPosition {
    private static let key = "captureBar.center"
    private static let margin: CGFloat = 8
    private static var watch: NSObjectProtocol?
    private static var settle: Timer?

    static func restore(_ window: NSWindow) {
        DispatchQueue.main.async {
            let saved = UserDefaults.standard.string(forKey: key).map(NSPointFromString)
                .flatMap { p in NSScreen.screens.contains { $0.visibleFrame.contains(p) } ? p : nil }
            place(window, center: saved ?? home(for: window), animated: false)
            watch.map(NotificationCenter.default.removeObserver)
            // Only the user moves the bar; drags arrive as moves while it's on screen. Once one's let go, a bar left
            // hanging off a display slides back onto it.
            watch = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let w = note.object as? NSWindow, w.isVisible else { return }
                    UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: w.frame.midX, y: w.frame.midY)), forKey: key)
                    settleAfterDrag(w)
                }
            }
        }
    }

    /// Back to the top centre of the display it's on, where it first opens.
    static func reset() {
        guard let window = AppModel.captureBarWindow, window.isVisible else { return }
        place(window, center: home(for: window), animated: true)
    }

    private static func home(for window: NSWindow) -> NSPoint {
        let p = NSEvent.mouseLocation
        let screen = window.screen ?? NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return NSPoint(x: window.frame.midX, y: window.frame.midY) }
        // As the scene's default placement: 60pt under the menu bar.
        return NSPoint(x: area.midX, y: area.maxY - 60 - window.frame.height / 2)
    }

    private static func place(_ window: NSWindow, center: NSPoint, animated: Bool) {
        let f = window.frame
        set(window, CGRect(x: center.x - f.width / 2, y: center.y - f.height / 2, width: f.width, height: f.height), animated: animated)
        fit(window, animated: animated)
    }

    private static func settleAfterDrag(_ window: NSWindow) {
        guard settle == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak window] _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons == 0 else { return }
                settle?.invalidate()
                settle = nil
                if let window, window.isVisible, window.alphaValue == 1 { fit(window, animated: true) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        settle = t
    }

    /// Moves the window so all of the bar (not its shadow padding) is on the display most of it is on.
    private static func fit(_ window: NSWindow, animated: Bool) {
        let bar = surface(of: window)
        let overlap = { (area: CGRect) -> CGFloat in
            let i = area.intersection(bar)
            return i.isNull ? 0 : i.width * i.height
        }
        guard let area = NSScreen.screens.map(\.visibleFrame).max(by: { overlap($0) < overlap($1) }), overlap(area) > 0 else {
            let c = home(for: window)
            return set(window, window.frame.offsetBy(dx: c.x - window.frame.midX, dy: c.y - window.frame.midY), animated: animated)
        }
        let dx = shift(bar.minX, bar.maxX, into: area.minX + margin, area.maxX - margin)
        let dy = shift(bar.minY, bar.maxY, into: area.minY + margin, area.maxY - margin)
        guard dx != 0 || dy != 0 else { return }
        set(window, window.frame.offsetBy(dx: dx, dy: dy), animated: animated)
    }

    /// How far a span has to move to sit inside another, centred in it if it doesn't fit.
    private static func shift(_ lo: CGFloat, _ hi: CGFloat, into min: CGFloat, _ max: CGFloat) -> CGFloat {
        if hi - lo > max - min { return (min + max - lo - hi) / 2 }
        return Swift.max(min - lo, 0) + Swift.min(max - hi, 0)
    }

    /// The setup bar inside the window's padding, or the live bar in its middle while recording.
    private static func surface(of window: NSWindow) -> CGRect {
        let bar = window.frame.insetBy(dx: Bar.inset, dy: Bar.inset)
        let model = AppModel.shared
        guard let size = BarStage(phase: model.recordingPhase, annotating: model.annotating).surfaceSize else { return bar }
        return CGRect(x: bar.midX - size.width / 2, y: bar.midY - size.height / 2, width: size.width, height: size.height)
    }

    private static func set(_ window: NSWindow, _ frame: CGRect, animated: Bool) {
        guard frame != window.frame else { return }
        guard animated else { return window.setFrame(frame, display: true) }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
        }
    }
}

/// While recording, the bar's window stays as wide as the setup bar with the small live bar in its middle. Clicks on
/// the empty part go through to whatever is under it instead of landing on an invisible window.
@MainActor
enum BarClickThrough {
    /// The live surface's size, nil while setting up, when the whole window is the bar.
    private static var surface: CGSize?
    private static var timer: Timer?

    static func track(_ size: CGSize?) {
        surface = size
        guard size != nil else {
            timer?.invalidate()
            timer = nil
            if let bar = AppModel.captureBarWindow, bar.alphaValue == 1 { bar.ignoresMouseEvents = false }
            return
        }
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in MainActor.assumeIsolated { update() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        update()
    }

    private static func update() {
        // A press in progress (a drag, a held button) keeps the window it started on; a hidden bar is left to the morph.
        guard let size = surface, let bar = AppModel.captureBarWindow, bar.isVisible, bar.alphaValue == 1,
              NSEvent.pressedMouseButtons == 0 else { return }
        let f = bar.frame
        let rect = CGRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2, width: size.width, height: size.height)
        let outside = !rect.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if bar.ignoresMouseEvents != outside { bar.ignoresMouseEvents = outside }
    }
}

