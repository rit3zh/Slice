//
//  LyricsScroller.swift
//  Slice
//
//  Created by rit3zh CX on 10/4/26.
//

import AppKit
import SliceCore
import SwiftUI

@Observable
@MainActor
final class LyricsScroller {
    struct Kick {
        let start: Date
        let delta: CGFloat
        let epicenter: Int
    }

    private(set) var y: CGFloat = 0
    var viewport: CGFloat = 0 {
        didSet { if y > maxY { y = maxY } }
    }
    var contentHeight: CGFloat = 0 {
        didSet { if y > maxY { y = maxY } }
    }
    private(set) var kicks: [Kick] = []
    private(set) var browsing = false
    @ObservationIgnored var hovering = false
    @ObservationIgnored var lineFrames: [Int: CGRect] = [:]
    @ObservationIgnored var wordFrames: [Int: CGRect] = [:]
    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var browseEnd: Task<Void, Never>?

    private static let trail = UnitCurve.bezier(startControlPoint: UnitPoint(x: 0.4, y: 0.8), endControlPoint: UnitPoint(x: 0.6, y: 1))
    private static let trailDuration = 0.42
    private var maxY: CGFloat { max(contentHeight - viewport, 0) }

    func scroll(to target: CGFloat, trailFrom epicenter: Int?) {
        let target = min(max(target, 0), maxY)
        let delta = target - y
        guard abs(delta) > 0.5 else { return }
        if let epicenter {
            kicks.append(Kick(start: Date(), delta: delta, epicenter: epicenter))
            cleanup?.cancel()
            cleanup = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.8))
                guard !Task.isCancelled else { return }
                self?.kicks.removeAll()
            }
        }
        y = target
    }

    func offset(line: Int, at now: Date) -> CGFloat {
        var sum: CGFloat = 0
        for k in kicks {
            let distance = abs(line - k.epicenter)
            guard distance <= 20 else { continue }
            let delay = min(Double(distance) * 0.03, 0.3)
            let p = min(max((now.timeIntervalSince(k.start) - delay) / Self.trailDuration, 0), 1)
            sum += k.delta * CGFloat(1 - Self.trail.value(at: p))
        }
        return sum
    }

    func word(at p: CGPoint) -> Int? {
        let onLine = wordFrames.filter { $0.value.minY - 3 <= p.y && p.y <= $0.value.maxY + 3 }
        let pool = onLine.isEmpty ? wordFrames : onLine
        return pool.min { a, b in
            func distance(_ r: CGRect) -> CGFloat {
                let dx = p.x < r.minX ? r.minX - p.x : (p.x > r.maxX ? p.x - r.maxX : 0)
                let dy = p.y < r.minY ? r.minY - p.y : (p.y > r.maxY ? p.y - r.maxY : 0)
                return dx + dy * 4
            }
            return distance(a.value) < distance(b.value)
        }?.key
    }

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.wheel(event) ?? false }
            return handled ? nil : event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        browseEnd?.cancel()
        browsing = false
    }

    private func wheel(_ event: NSEvent) -> Bool {
        guard hovering else { return false }
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        guard dy != 0 else { return true }
        browse()
        if event.hasPreciseScrollingDeltas {
            y = min(max(y - dy, 0), maxY)
        } else {
            let mark = y + viewport * 0.3
            scroll(to: y - dy, trailFrom: lineFrames.min { abs($0.value.midY - mark) < abs($1.value.midY - mark) }?.key)
        }
        return true
    }

    private func browse() {
        if !browsing { browsing = true }
        browseEnd?.cancel()
        browseEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.browsing = false
        }
    }
}
