//
//  CameraBubble.swift
//  Slice
//
//  Created by rit3zh CX on 10/24/26.
//

import AppKit
import AVFoundation

/// The camera on screen while setting up and recording, so you can see yourself. It's one of Slice's own windows,
/// which recordings leave out; the camera itself is recorded on its own and laid out in the editor. Drag it anywhere,
/// double-click to change its size; both are kept for next time.
@MainActor
final class CameraBubble {
    static let shared = CameraBubble()

    private static let sizes: [CGFloat] = [168, 248]
    private static let margin: CGFloat = 24
    private var panel: NSPanel?
    private var moveWatch: NSObjectProtocol?

    private var large: Bool {
        get { UserDefaults.standard.bool(forKey: "cameraBubble.large") }
        set { UserDefaults.standard.set(newValue, forKey: "cameraBubble.large") }
    }

    /// Bottom-left corner, in screen coordinates, where it was last left.
    private var savedOrigin: NSPoint? {
        get { UserDefaults.standard.string(forKey: "cameraBubble.origin").map(NSPointFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromPoint), forKey: "cameraBubble.origin") }
    }

    /// Showing it again with another session, as Record hands the setup preview's camera to the recorder's, swaps
    /// the picture in place.
    func show(session: AVCaptureSession) {
        if let view = panel?.contentView as? CameraBubbleView {
            view.attach(session)
            return
        }
        hide(animated: false)
        let side = Self.sizes[large ? 1 : 0]
        let panel = NSPanel(contentRect: frame(side: side), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = CameraBubbleView(session: session)
        view.onDoubleClick = { [weak self] in self?.toggleSize() }
        panel.contentView = view
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        moveWatch = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel,
                                                           queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated { self?.savedOrigin = window.frame.origin }
        }
        self.panel = panel
    }

    func hide(animated: Bool = true) {
        if let moveWatch { NotificationCenter.default.removeObserver(moveWatch) }
        moveWatch = nil
        guard let panel else { return }
        self.panel = nil
        guard animated else {
            panel.close()
            return
        }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) { panel.close() }
    }

    private func toggleSize() {
        guard let panel else { return }
        large.toggle()
        let side = Self.sizes[large ? 1 : 0]
        let old = panel.frame
        // Grows and shrinks about its centre, kept on the screen it's on.
        var next = NSRect(x: old.midX - side / 2, y: old.midY - side / 2, width: side, height: side)
        if let visible = panel.screen?.visibleFrame {
            next.origin.x = min(max(next.minX, visible.minX), visible.maxX - side)
            next.origin.y = min(max(next.minY, visible.minY), visible.maxY - side)
        }
        panel.animator().setFrame(next, display: true)
    }

    private func frame(side: CGFloat) -> NSRect {
        if let origin = savedOrigin {
            let rect = NSRect(origin: origin, size: NSSize(width: side, height: side))
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect.insetBy(dx: side / 3, dy: side / 3)) }) { return rect }
        }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        return NSRect(x: visible.minX + Self.margin, y: visible.minY + Self.margin, width: side, height: side)
    }
}

/// A round, mirrored camera picture that drags its window.
private final class CameraBubbleView: NSView {
    var onDoubleClick: (() -> Void)?
    private let preview: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        preview.videoGravity = .resizeAspectFill
        preview.masksToBounds = true
        preview.borderWidth = 1.5
        preview.borderColor = NSColor.white.withAlphaComponent(0.3).cgColor
        preview.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(preview)
        mirror()
    }

    func attach(_ session: AVCaptureSession) {
        guard preview.session !== session else { return }
        preview.session = session
        mirror()
    }

    private func mirror() {
        // Setting mirroring on a connection that doesn't support it raises an exception.
        if let c = preview.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        preview.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}
