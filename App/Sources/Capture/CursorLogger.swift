//
//  CursorLogger.swift
//  Slice
//
//  Created by rit3zh CX on 10/12/26.
//

import AppKit
import AVFoundation
import Carbon.HIToolbox
import SliceCore
import VideoToolbox

final class CursorLogger {
    struct Result {
        var samples: [CursorLog.Sample] = []
        var clicks: [CursorLog.Sample] = []
        var types: [CursorLog.TypeChange] = []
        var keys: [KeyPress] = []
        var scrolls: [CursorLog.Sample] = []
        var typing: [Double] = []
        var hits: [KeyHit] = []
        var annotations: [Annotation] = []

        /// The log as saved with a take, timed from its start (host-clock seconds).
        func log(since start: Double) -> CursorLog {
            CursorLog(samples: samples.sorted { $0.t < $1.t }.map { .init(t: $0.t - start, x: $0.x, y: $0.y) },
                      clicks: clicks.map { .init(t: $0.t - start, x: $0.x, y: $0.y) },
                      types: types.map { .init(t: $0.t - start, type: $0.type) },
                      keys: keys.map { KeyPress(t: $0.t - start, modifiers: $0.modifiers, key: $0.key) },
                      scrolls: scrolls.map { .init(t: $0.t - start, x: $0.x, y: $0.y) },
                      typing: typing.map { $0 - start },
                      hits: hits.map { KeyHit(t: $0.t - start, kind: $0.kind) },
                      annotations: annotations.compactMap { $0.since(start) })
        }
    }

    typealias Mapping = (NSPoint) -> CGPoint

    /// What's been logged so far, for saving while the take records.
    var snapshot: Result { result }

    private var result = Result()
    private var map: Mapping = { _ in .zero }
    private var timer: Timer?
    private var monitors: [Any] = []
    private var keyTap: CFMachPort?
    private var keyTapSource: CFRunLoopSource?
    private lazy var classifier = SystemCursorClassifier()
    private var deviceWindowsInPicture = false
    private var analysis: LiveTakeAnalyzer?
    /// Keys that aren't part of what's recorded, such as Slice's own shortcuts.
    var ignoresKey: ((NSEvent) -> Bool)?
    /// Typed characters are kept too, to show what was typed; asked for at recording time, off unless it is.
    private var keepsTyping = false

    func start(globalRect: CGRect, mapping: Mapping? = nil, keys: Bool = false, typing: Bool = false,
               deviceWindowsInPicture: Bool = false, analysis: LiveTakeAnalyzer? = nil) {
        map = mapping ?? Self.mapping(globalRect)
        keepsTyping = keys && typing
        result = Result()
        self.analysis = analysis
        self.deviceWindowsInPicture = deviceWindowsInPicture
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self, !self.isOverOwnWindow else { return }
            self.sample(into: \.samples)
            self.sampleType()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // Only events going to other apps: our own windows (the recording controls) aren't in the video, so clicks and
        // movement over them would put the pointer, and a click effect, on something that isn't there. While over
        // them the pointer simply holds where it left the recorded picture.
        let downs: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let handle: (NSEvent) -> Void = { [weak self] event in
            guard let self else { return }
            switch event.type {
            case .leftMouseDown, .rightMouseDown: self.sample(event, into: \.clicks)
            case .scrollWheel:
                let t = self.hostTime(event)
                if t - (self.result.scrolls.last?.t ?? -1) > 0.05, abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX) > 0 {
                    self.sample(event, into: \.scrolls)
                }
            default: self.sample(event, into: \.samples)
            }
        }
        let all = downs.union(moves).union(.scrollWheel)
        if let global = NSEvent.addGlobalMonitorForEvents(matching: all, handler: handle) { monitors.append(global) }
        if deviceWindowsInPicture, let local = NSEvent.addLocalMonitorForEvents(matching: all, handler: { event in
            if let window = event.window, MainActor.assumeIsolated({ DeviceWindowController.isDeviceWindow(window) }) { handle(event) }
            return event
        }) {
            monitors.append(local)
        }
        if keys { startKeys() }
    }

    private var isOverOwnWindow: Bool {
        let p = NSEvent.mouseLocation
        return NSApp.windows.contains { window in
            window.isVisible && !window.isMiniaturized && !window.ignoresMouseEvents && window.frame.contains(p)
                && !(window is AnnotationCanvasPanel)
                && !(deviceWindowsInPicture && MainActor.assumeIsolated { DeviceWindowController.isDeviceWindow(window) })
        }
    }

    func stop() -> Result {
        timer?.invalidate()
        timer = nil
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        stopKeys()
        analysis = nil
        return result
    }

    private func sample(into keyPath: WritableKeyPath<Result, [CursorLog.Sample]>) {
        append(NSEvent.mouseLocation, at: CMClockGetTime(CMClockGetHostTimeClock()).seconds, into: keyPath)
    }

    /// Watches every key press. Shortcuts the system handles itself (switching Spaces with ⌃← ⌃→, ⌘Tab, ⌘Space,
    /// screenshots) are never delivered to apps, so an app's event monitor misses them; a listen-only tap at the
    /// hardware level sees them before the system acts. It needs Accessibility access, and macOS still keeps password
    /// fields from it. Without the tap, falls back to the monitor, which sees keys going to other apps.
    private func startKeys() {
        let callback: CGEventTapCallBack = { _, type, event, info in
            if let info {
                Unmanaged<CursorLogger>.fromOpaque(info).takeUnretainedValue().tapped(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        if let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .listenOnly,
                                       eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue)
                                           | CGEventMask(1 << CGEventType.flagsChanged.rawValue), callback: callback,
                                       userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            keyTap = tap
            keyTapSource = source
        } else if let global = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged], handler: { [weak self] event in
            guard let self else { return }
            if event.type == .flagsChanged { self.logModifier(event, at: self.hostTime(event)) } else { self.logKey(event, at: self.hostTime(event)) }
        }) {
            monitors.append(global)
        }
    }

    private func stopKeys() {
        guard let tap = keyTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source = keyTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        keyTap = nil
        keyTapSource = nil
    }

    private func tapped(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switches a tap off if it ever stalls; carry on listening.
            if let keyTap { CGEvent.tapEnable(tap: keyTap, enable: true) }
        case .keyDown:
            if let key = NSEvent(cgEvent: event) { logKey(key, at: CMClockGetTime(CMClockGetHostTimeClock()).seconds) }
        case .flagsChanged:
            if let key = NSEvent(cgEvent: event) { logModifier(key, at: CMClockGetTime(CMClockGetHostTimeClock()).seconds) }
        default:
            break
        }
    }

    private func logKey(_ event: NSEvent, at t: Double) {
        guard !event.isARepeat, ignoresKey?(event) != true else { return }
        result.hits.append(KeyHit(t: t, kind: KeyHit.kind(keyCode: event.keyCode)))
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Never what goes into a password field: macOS turns secure input on for those.
        let text = keepsTyping && !IsSecureEventInputEnabled() ? event.characters : nil
        guard let press = KeyPress.make(t: t, keyCode: event.keyCode,
                                        characters: event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers,
                                        text: text, control: flags.contains(.control), option: flags.contains(.option),
                                        shift: flags.contains(.shift), command: flags.contains(.command)) else {
            result.typing.append(t)
            return
        }
        if press.isTyped { result.typing.append(t) }
        result.keys.append(press)
    }

    private func logModifier(_ event: NSEvent, at t: Double) {
        let flag: NSEvent.ModifierFlags? = switch event.keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 58, 61: .option
        case 59, 62: .control
        case 63: .function
        default: nil
        }
        guard let flag, event.modifierFlags.contains(flag), ignoresKey?(event) != true else { return }
        result.hits.append(KeyHit(t: t, kind: .modifier))
    }

    private func sampleType() {
        guard let current = NSCursor.currentSystem else { return }
        let type = classifier.type(of: current)
        guard result.types.last?.type != type else { return }
        result.types.append(.init(t: CMClockGetTime(CMClockGetHostTimeClock()).seconds, type: type))
    }

    private func sample(_ event: NSEvent, into keyPath: WritableKeyPath<Result, [CursorLog.Sample]>) {
        append(location(event), at: hostTime(event), into: keyPath)
    }

    private func location(_ event: NSEvent) -> NSPoint {
        event.window.map { $0.convertPoint(toScreen: event.locationInWindow) } ?? event.locationInWindow
    }

    private func hostTime(_ event: NSEvent) -> Double {
        event.timestamp + CMClockGetTime(CMClockGetHostTimeClock()).seconds - ProcessInfo.processInfo.systemUptime
    }

    private func append(_ p: NSPoint, at t: Double, into keyPath: WritableKeyPath<Result, [CursorLog.Sample]>) {
        let q = map(p)
        result[keyPath: keyPath].append(.init(t: t, x: q.x, y: q.y))
        if keyPath == \Result.samples {
            analysis?.pointer(at: t, q)
        } else if keyPath == \Result.clicks {
            analysis?.click(at: t, q)
        }
    }

    static func mapping(_ rect: CGRect) -> Mapping {
        { p in
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return CGPoint(x: (p.x - rect.minX) / max(rect.width, 1), y: (primaryHeight - p.y - rect.minY) / max(rect.height, 1))
        }
    }
}
