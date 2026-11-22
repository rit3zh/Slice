//
//  CaptureSource.swift
//  Slice
//
//  Created by rit3zh CX on 10/7/26.
//

import AppKit
import ScreenCaptureKit

enum CaptureSource: Equatable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case area(CGDirectDisplayID, CGRect)
    case device(String)

    var label: String {
        switch self {
        case .display: "Display"
        case .window: "Window"
        case .area: "Area"
        case .device: "iPhone"
        }
    }
}

struct ResolvedSource {
    let filter: SCContentFilter
    let sourceRect: CGRect?
    let pixelSize: CGSize
    let globalRect: CGRect
    let maxFrameRate: Int
}

enum CaptureError: LocalizedError {
    case sourceGone
    case noScreenPermission
    case deviceNotStreaming(String)
    case interrupted(String)
    case appNotRunning(String)

    var errorDescription: String? {
        switch self {
        case .sourceGone: "The selected display or window is no longer available."
        case let .deviceNotStreaming(name): "\(name) isn't streaming its screen. Check it's connected and unlocked, then try again."
        case let .appNotRunning(name):
            "\(name) isn't running, so its sound can't be recorded. Open it, or pick another app in Options."
        case .noScreenPermission:
            "Screen Recording permission is needed. Enable it in System Settings > Privacy & Security > Screen & System Audio Recording, then reopen the app."
        case let .interrupted(reason): "Recording stopped: \(reason)"
        }
    }
}

enum SourceResolver {
    static func shareableContent() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CaptureError.noScreenPermission
        }
        do {
            return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        } catch let error as SCStreamError where error.code == .userDeclined {
            throw CaptureError.noScreenPermission
        }
    }

    static func resolve(_ source: CaptureSource) async throws -> ResolvedSource {
        let content = try await shareableContent()
        switch source {
        case let .display(id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceGone }
            let filter = await displayFilter(display, in: content)
            let size = recordedPixels(display: id, points: filter.contentRect.size, scale: filter.pointPixelScale)
            return ResolvedSource(filter: filter, sourceRect: nil, pixelSize: size, globalRect: display.frame,
                                  maxFrameRate: refreshRate(display: id))
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.sourceGone }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let screen = NSScreen.screens.max {
                $0.topLeftFrame.intersection(window.frame).area < $1.topLeftFrame.intersection(window.frame).area
            }
            return ResolvedSource(filter: filter, sourceRect: nil, pixelSize: pixels(filter.contentRect.size, filter.pointPixelScale),
                                  globalRect: window.frame, maxFrameRate: screen?.maximumFramesPerSecond ?? 60)
        case let .area(id, rect):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.sourceGone }
            let filter = await displayFilter(display, in: content)
            let local = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
            let whole = recordedPixels(display: id, points: display.frame.size, scale: filter.pointPixelScale)
            let scale = Float(whole.width / max(display.frame.width, 1))
            return ResolvedSource(filter: filter, sourceRect: local, pixelSize: pixels(rect.size, scale),
                                  globalRect: rect, maxFrameRate: refreshRate(display: id))
        case .device:
            throw CaptureError.sourceGone
        }
    }

    static func displayFilter(_ display: SCDisplay, in content: SCShareableContent) async -> SCContentFilter {
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let shown = await MainActor.run { DeviceWindowController.windowNumbers() }
        let devices = content.windows.filter { shown.contains($0.windowID) }
        return SCContentFilter(display: display, excludingApplications: me, exceptingWindows: devices)
    }

    static func refreshedFilter(for source: CaptureSource) async -> SCContentFilter? {
        let id: CGDirectDisplayID
        switch source {
        case let .display(d), let .area(d, _): id = d
        default: return nil
        }
        guard let content = try? await shareableContent(),
              let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        return await displayFilter(display, in: content)
    }

    private static func refreshRate(display id: CGDirectDisplayID) -> Int {
        NSScreen.screens.first { $0.displayID == id }?.maximumFramesPerSecond ?? 60
    }

    /// The pixels a whole display is recorded at: what macOS draws it at (its Retina backing, as on the built-in
    /// display), unless a scaled mode draws more than 4K's worth and more than the panel itself has (a 4K monitor set
    /// to look like 2560 × 1440 is drawn at 5120 × 2880): then the panel's own resolution, which shows everything the
    /// monitor can and keeps the hardware encoder in real time.
    static func recordedPixels(display id: CGDirectDisplayID, points: CGSize, scale: Float) -> CGSize {
        let drawn = pixels(points, scale)
        guard drawn.width * drawn.height > 3840 * 2400, let panel = DisplayInfo.panelPixels(id),
              panel.width < drawn.width else { return drawn }
        return pixels(points, Float(panel.width / max(points.width, 1)))
    }

    private static func pixels(_ size: CGSize, _ scale: Float) -> CGSize {
        let s = CGFloat(scale)
        return CGSize(width: (Int(size.width * s) / 2) * 2, height: (Int(size.height * s) / 2) * 2)
    }
}

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let isMain: Bool
    let pixels: CGSize
    let refreshRate: Int

    var detail: String { "\(Int(pixels.width)) × \(Int(pixels.height)) · \(refreshRate) Hz" }

    static func all() -> [DisplayInfo] {
        let main = CGMainDisplayID()
        return NSScreen.screens.compactMap { screen -> DisplayInfo? in
            guard let id = screen.displayID else { return nil }
            let points = screen.frame.size
            return DisplayInfo(id: id, name: screen.localizedName, isBuiltIn: CGDisplayIsBuiltin(id) != 0, isMain: id == main,
                               pixels: SourceResolver.recordedPixels(display: id, points: points, scale: Float(screen.backingScaleFactor)),
                               refreshRate: screen.maximumFramesPerSecond)
        }
        .sorted { ($0.isBuiltIn ? 0 : 1, NSScreen.frame(of: $0.id).minX) < ($1.isBuiltIn ? 0 : 1, NSScreen.frame(of: $1.id).minX) }
    }

    static func panelPixels(_ id: CGDirectDisplayID) -> CGSize? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] else { return nil }
        // kDisplayModeNativeFlag, from IOGraphicsTypes.h.
        let native = modes.filter { $0.ioFlags & 0x0200_0000 != 0 }
        let pool = native.isEmpty ? modes.filter { $0.pixelWidth == $0.width } : native
        return pool.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
            .map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    var topLeftFrame: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static func frame(of id: CGDirectDisplayID) -> CGRect {
        screens.first { $0.displayID == id }?.frame ?? .zero
    }
}
