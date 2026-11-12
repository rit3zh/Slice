//
//  Device3DPoseOverlay.swift
//  Slice
//
//  Created by rit3zh CX on 10/15/26.
//

import AppKit
import SliceCore
import SwiftUI

struct Device3DPoseOverlay: NSViewRepresentable {
    let editor: EditorModel
    func makeNSView(context: Context) -> PoseCanvas {
        let view = PoseCanvas()
        view.editor = editor
        return view
    }

    func updateNSView(_ view: PoseCanvas, context: Context) { view.editor = editor }

    static let hint = "Drag to move the device, ⌥-drag to turn it, scroll to resize. Double-click resets."
}

final class PoseCanvas: NSView {
    weak var editor: EditorModel?

    private enum Mode { case move, orbit, spin }
    private var drag: (mode: Mode, start: CGPoint, placement: Device3DPlacement)?

    /// Degrees per point of drag when turning.
    private static let turnRate = 0.45

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: drag == nil ? .openHand : .closedHand)
    }

    /// The pose being handled: the selected keyframe's, or the phone's at the playhead.
    private var placement: Device3DPlacement? {
        get { MainActor.assumeIsolated { editor?.editedPlacement } }
        set {
            guard let newValue else { return }
            MainActor.assumeIsolated { editor?.setPlacement(newValue) }
        }
    }

    override func mouseDown(with event: NSEvent) { begin(event, right: false) }
    override func rightMouseDown(with event: NSEvent) { begin(event, right: true) }

    private func begin(_ event: NSEvent, right: Bool) {
        MainActor.assumeIsolated {
            // Keyframes go where the playhead stands, so it stands still while the phone is handled.
            if let editor, editor.isPlaying, !editor.project.device3D.keyframes.isEmpty { editor.pause() }
        }
        guard let current = placement else { return }
        if event.clickCount == 2 {
            var reset = MainActor.assumeIsolated { editor?.project.device3D.model.defaultPlacement } ?? .standard
            reset.position = .zero
            placement = reset
            return
        }
        let flags = event.modifierFlags
        let mode: Mode = right || flags.contains(.option) ? .orbit : flags.contains(.shift) ? .spin : .move
        drag = (mode, convert(event.locationInWindow, from: nil), current)
        NSCursor.closedHand.set()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) { dragged(event) }
    override func rightMouseDragged(with event: NSEvent) { dragged(event) }

    private func dragged(_ event: NSEvent) {
        guard let drag, bounds.width > 0, bounds.height > 0 else { return }
        let p = convert(event.locationInWindow, from: nil)
        let dx = Double(p.x - drag.start.x), dy = Double(p.y - drag.start.y)
        var s = drag.placement
        switch drag.mode {
        case .move:
            let r = Device3DSettings.positionRange
            s.position = CGPoint(x: min(max(drag.placement.position.x + dx / Double(bounds.width), r.lowerBound), r.upperBound),
                                 y: min(max(drag.placement.position.y + dy / Double(bounds.height), r.lowerBound), r.upperBound))
        case .orbit:
            // Like taking hold of the phone's face: dragging right turns its right edge away, up tips its top away.
            s.yaw = Self.wrapped(drag.placement.yaw + dx * Self.turnRate)
            s.pitch = Self.wrapped(drag.placement.pitch + dy * Self.turnRate)
        case .spin:
            s.rotation = Self.wrapped(drag.placement.rotation - dx * Self.turnRate)
        }
        placement = s
    }

    override func mouseUp(with event: NSEvent) { end() }
    override func rightMouseUp(with event: NSEvent) { end() }

    private func end() {
        drag = nil
        NSCursor.openHand.set()
        window?.invalidateCursorRects(for: self)
    }

    override func scrollWheel(with event: NSEvent) {
        guard var s = placement else { return }
        let delta = Double(event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8)
        s.scale = Self.clampedScale(s.scale * exp(delta * 0.006))
        placement = s
    }

    override func magnify(with event: NSEvent) {
        guard var s = placement else { return }
        s.scale = Self.clampedScale(s.scale * (1 + Double(event.magnification)))
        placement = s
    }

    override func rotate(with event: NSEvent) {
        guard var s = placement else { return }
        s.rotation = Self.wrapped(s.rotation + Double(event.rotation))
        placement = s
    }

    private static func clampedScale(_ v: Double) -> Double {
        min(max(v, Device3DSettings.scaleRange.lowerBound), Device3DSettings.scaleRange.upperBound)
    }

    /// An angle brought into -180…180°, so turning round and round never runs out.
    static func wrapped(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        return d
    }
}
