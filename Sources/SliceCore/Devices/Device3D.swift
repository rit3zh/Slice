//
//  Device3D.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/15/26.
//

import CoreGraphics
import Foundation

/// Where the phone is and which way it faces: the part of the 3D settings a keyframe holds.
public struct Device3DPlacement: Codable, Equatable {
    /// Degrees turning the phone left or right about its upright axis; positive turns its right edge away.
    public var yaw: Double
    /// Degrees tipping the phone forwards or back; positive tips its top away.
    public var pitch: Double
    /// Degrees turning the phone in the picture's plane (counter-clockwise).
    public var rotation: Double
    /// Fractions of the frame from its centre; positive y is up.
    public var position: CGPoint
    public var scale: Double
    /// Degrees a laptop's lid stands open from its keyboard: 0 is shut, 90 upright.
    public var lid: Double

    public init(yaw: Double = 12, pitch: Double = 3, rotation: Double = 0, position: CGPoint = .zero, scale: Double = 1,
                lid: Double = Device3DPlacement.openLid) {
        self.yaw = yaw
        self.pitch = pitch
        self.rotation = rotation
        self.position = position
        self.scale = scale
        self.lid = lid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        yaw = try c.decode(Double.self, forKey: .yaw)
        pitch = try c.decode(Double.self, forKey: .pitch)
        rotation = try c.decode(Double.self, forKey: .rotation)
        position = try c.decode(CGPoint.self, forKey: .position)
        scale = try c.decode(Double.self, forKey: .scale)
        lid = try c.decodeIfPresent(Double.self, forKey: .lid) ?? Self.openLid
    }

    /// A lid standing open, as laptops are modelled.
    public static let openLid = 90.0

    public static let standard = Device3DPlacement()

    /// Part way from `a` to `b`, turning the short way round.
    public static func interpolate(_ a: Device3DPlacement, _ b: Device3DPlacement, _ f: Double) -> Device3DPlacement {
        func angle(_ x: Double, _ y: Double) -> Double {
            var d = (y - x).truncatingRemainder(dividingBy: 360)
            if d > 180 { d -= 360 } else if d < -180 { d += 360 }
            return x + d * f
        }
        return Device3DPlacement(yaw: angle(a.yaw, b.yaw), pitch: angle(a.pitch, b.pitch), rotation: angle(a.rotation, b.rotation),
                                 position: CGPoint(x: lerp(a.position.x, b.position.x, f), y: lerp(a.position.y, b.position.y, f)),
                                 scale: exp(lerp(log(max(a.scale, 1e-3)), log(max(b.scale, 1e-3)), f)), lid: lerp(a.lid, b.lid, f))
    }

    func isClose(to other: Device3DPlacement) -> Bool {
        abs(yaw - other.yaw) < 0.5 && abs(pitch - other.pitch) < 0.5 && abs(rotation - other.rotation) < 0.5
    }
}

/// A pose at a moment on the edited timeline; the phone moves from one keyframe to the next.
public struct Device3DKeyframe: Codable, Equatable, Identifiable {
    public var id: UUID
    public var time: Double
    public var placement: Device3DPlacement
    /// How the phone moves into this keyframe from the one before.
    public var easing: EasingCurve
    /// The shape of that move when `easing` is `.custom`.
    public var curve: CubicBezier

    public init(id: UUID = UUID(), time: Double, placement: Device3DPlacement, easing: EasingCurve = .smooth,
                curve: CubicBezier = .default) {
        self.id = id
        self.time = time
        self.placement = placement
        self.easing = easing
        self.curve = curve
    }

    public func ease(_ x: Double) -> Double { easing == .custom ? curve(x) : easing(x) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        time = try c.decode(Double.self, forKey: .time)
        placement = try c.decodeIfPresent(Device3DPlacement.self, forKey: .placement) ?? .standard
        easing = (try? c.decodeIfPresent(EasingCurve.self, forKey: .easing)) ?? .smooth
        curve = (try? c.decodeIfPresent(CubicBezier.self, forKey: .curve)) ?? .default
    }
}

public enum Device3DBackground: String, Codable, CaseIterable {
    case frame, studio, color

    public var label: String {
        switch self {
        case .frame: "Frame"
        case .studio: "Studio"
        case .color: "Colour"
        }
    }
}

public enum Device3DMotion: String, Codable, CaseIterable {
    case none, sway, float

    public var label: String {
        switch self {
        case .none: "Off"
        case .sway: "Sway"
        case .float: "Float"
        }
    }
}

public struct Device3DAnimation: Codable, Equatable {
    public var motion: Device3DMotion = .none
    /// Seconds for one swing from side to side (sway), or one rise or fall (float).
    public var duration = 4.0
    public var easing: EasingCurve = .gentle
    /// The shape of each swing when `easing` is `.custom`.
    public var curve: CubicBezier = .default
    /// The share of each swing spent resting at its end before turning back.
    public var hold = 0.2
    /// How far the float drifts and turns.
    public var amount = 0.5
    /// Degrees a sway turns either side of the phone's own pose.
    public var swing = 20.0
    /// The side a sway sets off towards.
    public var startSide: TiltDirection = .right

    public init() {}

    public static let durationRange = 1.5 ... 12.0
    public static let swingRange = 2.0 ... 90.0

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Device3DAnimation()
        motion = (try? c.decodeIfPresent(Device3DMotion.self, forKey: .motion)) ?? d.motion
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? d.duration
        easing = (try? c.decodeIfPresent(EasingCurve.self, forKey: .easing)) ?? d.easing
        curve = (try? c.decodeIfPresent(CubicBezier.self, forKey: .curve)) ?? d.curve
        hold = try c.decodeIfPresent(Double.self, forKey: .hold) ?? d.hold
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? d.amount
        swing = try c.decodeIfPresent(Double.self, forKey: .swing) ?? d.swing
        startSide = (try? c.decodeIfPresent(TiltDirection.self, forKey: .startSide)) ?? d.startSide
    }

    /// Where a sway is at `t`, from 1 (the chosen side) to -1 (the other). It rests at each end for `hold` of a swing,
    /// then eases across, so playback, scrubbing and export all land on the same pose for the same moment.
    func swing(at t: Double) -> Double {
        let length = max(duration, 0.1)
        let s = t / length
        let k = s.rounded(.down)
        let f = s - k
        let h = min(max(hold, 0), 0.9)
        let x = min(max((f - h / 2) / (1 - h), 0), 1)
        let from: Double = Int(k).isMultiple(of: 2) ? 1 : -1
        return from - 2 * from * (easing == .custom ? curve(x) : easing(x))
    }
}

public struct Device3DSettings: Codable, Equatable {
    public var enabled = false
    public var model: Device3DModel = .iPhone17ProMax
    public var finish: Device3DFinish = .cosmicOrange
    /// Degrees turning the phone left or right about its upright axis; positive turns its right edge away. Free all
    /// the way round.
    public var yaw = 12.0
    /// Degrees tipping the phone forwards or back; positive tips its top away.
    public var pitch = 3.0
    /// Degrees turning the phone in the picture's plane (counter-clockwise).
    public var rotation = 0.0
    /// Fractions of the frame from its centre; positive y is up. Beyond ±0.5 the phone runs off the frame.
    public var position = CGPoint.zero
    public var scale = 1.0
    /// Degrees a laptop's lid stands open.
    public var lid = Device3DPlacement.openLid
    /// Whether a phone shows its Dynamic Island.
    public var dynamicIsland = true
    /// The island's size against the model's own, and how far it's moved down the display in its own heights: for
    /// covering an island that's in the recording itself.
    public var islandSize = 1.0
    public var islandOffset = 0.0
    /// 0 is a long lens (almost flat), 1 a wide one (strong perspective).
    public var perspective = 0.35
    public var animation = Device3DAnimation()
    public var background: Device3DBackground = .frame
    public var backgroundColor = RGBA(0.13, 0.13, 0.16)
    public var brightness = 1.0
    /// Where the main light comes from: -1 the left, 1 the right.
    public var lightAngle = -0.35
    public var reflections = 0.5
    public var shadowOpacity = 0.45
    public var shadowSoftness = 0.5
    public var shadowDistance = 0.4
    /// The phone's own animation, made on the timeline's 3D track. With none, it holds the pose above.
    public var keyframes: [Device3DKeyframe] = []

    public init() {}

    public static let scaleRange = 0.15 ... 4.0
    public static let positionRange = -1.0 ... 1.0
    public static let islandSizeRange = 0.6 ... 1.8
    public static let islandOffsetRange = -1.0 ... 1.5
    /// Shut to leaning well back, as far as a MacBook's hinge goes.
    public static let lidRange = 0.0 ... 120.0
    static let fieldOfView = 8.0 ... 50.0

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Device3DSettings()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        model = (try? c.decodeIfPresent(Device3DModel.self, forKey: .model)) ?? d.model
        finish = (try? c.decodeIfPresent(Device3DFinish.self, forKey: .finish)) ?? d.finish
        if let yaw = try c.decodeIfPresent(Double.self, forKey: .yaw) {
            self.yaw = yaw
            pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? d.pitch
        } else if let strength = try c.decodeIfPresent(Double.self, forKey: .tiltStrength) {
            // Saved with a tilt direction and strength: the same pose as free angles.
            let left = (try? c.decodeIfPresent(TiltDirection.self, forKey: .tiltDirection)) == .left
            yaw = min(max(strength, 0), 1) * 35 * (left ? -1 : 1)
            pitch = abs(yaw) * 0.2 + (try c.decodeIfPresent(Double.self, forKey: .lean) ?? 0)
        }
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? d.rotation
        position = try c.decodeIfPresent(CGPoint.self, forKey: .position) ?? d.position
        scale = try c.decodeIfPresent(Double.self, forKey: .scale) ?? d.scale
        lid = try c.decodeIfPresent(Double.self, forKey: .lid) ?? d.lid
        dynamicIsland = try c.decodeIfPresent(Bool.self, forKey: .dynamicIsland) ?? d.dynamicIsland
        islandSize = try c.decodeIfPresent(Double.self, forKey: .islandSize) ?? d.islandSize
        islandOffset = try c.decodeIfPresent(Double.self, forKey: .islandOffset) ?? d.islandOffset
        perspective = try c.decodeIfPresent(Double.self, forKey: .perspective) ?? d.perspective
        animation = try c.decodeIfPresent(Device3DAnimation.self, forKey: .animation) ?? d.animation
        background = (try? c.decodeIfPresent(Device3DBackground.self, forKey: .background)) ?? d.background
        backgroundColor = try c.decodeIfPresent(RGBA.self, forKey: .backgroundColor) ?? d.backgroundColor
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        lightAngle = try c.decodeIfPresent(Double.self, forKey: .lightAngle) ?? d.lightAngle
        reflections = try c.decodeIfPresent(Double.self, forKey: .reflections) ?? d.reflections
        shadowOpacity = try c.decodeIfPresent(Double.self, forKey: .shadowOpacity) ?? d.shadowOpacity
        shadowSoftness = try c.decodeIfPresent(Double.self, forKey: .shadowSoftness) ?? d.shadowSoftness
        shadowDistance = try c.decodeIfPresent(Double.self, forKey: .shadowDistance) ?? d.shadowDistance
        keyframes = try c.decodeIfPresent([Device3DKeyframe].self, forKey: .keyframes) ?? []
        if !model.finishes.contains(finish) { finish = model.finishes[0] }
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, model, finish, yaw, pitch, rotation, position, scale, lid, dynamicIsland, islandSize, islandOffset, perspective,
             animation, background, backgroundColor, brightness, lightAngle, reflections, shadowOpacity, shadowSoftness, shadowDistance, keyframes
        case tiltDirection, tiltStrength, lean
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(model, forKey: .model)
        try c.encode(finish, forKey: .finish)
        try c.encode(yaw, forKey: .yaw)
        try c.encode(pitch, forKey: .pitch)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(position, forKey: .position)
        try c.encode(scale, forKey: .scale)
        try c.encode(lid, forKey: .lid)
        try c.encode(dynamicIsland, forKey: .dynamicIsland)
        try c.encode(islandSize, forKey: .islandSize)
        try c.encode(islandOffset, forKey: .islandOffset)
        try c.encode(perspective, forKey: .perspective)
        try c.encode(animation, forKey: .animation)
        try c.encode(background, forKey: .background)
        try c.encode(backgroundColor, forKey: .backgroundColor)
        try c.encode(brightness, forKey: .brightness)
        try c.encode(lightAngle, forKey: .lightAngle)
        try c.encode(reflections, forKey: .reflections)
        try c.encode(shadowOpacity, forKey: .shadowOpacity)
        try c.encode(shadowSoftness, forKey: .shadowSoftness)
        try c.encode(shadowDistance, forKey: .shadowDistance)
        try c.encode(keyframes, forKey: .keyframes)
    }

    /// Whether a take is drawn on this model: an iPhone take on a phone, a screen recording on a laptop.
    public func applies(to clip: Clip) -> Bool { model.kind == .phone ? clip.device != nil && !clip.isAndroid : clip.device == nil }

    /// The pose controls' own values (used while there are no keyframes).
    public var placement: Device3DPlacement {
        get { Device3DPlacement(yaw: yaw, pitch: pitch, rotation: rotation, position: position, scale: scale, lid: lid) }
        set {
            yaw = newValue.yaw
            pitch = newValue.pitch
            rotation = newValue.rotation
            position = newValue.position
            scale = newValue.scale
            lid = newValue.lid
        }
    }

    /// Where the phone is at `t`: between the keyframes either side (eased as the later one says), held before the
    /// first and after the last, or the pose controls' own values when there are no keyframes.
    public func placement(at t: Double) -> Device3DPlacement {
        guard let first = keyframes.min(by: { $0.time < $1.time }) else { return placement }
        let keys = keyframes.sorted { $0.time < $1.time }
        guard t > first.time else { return first.placement }
        guard let next = keys.firstIndex(where: { $0.time > t }) else { return keys[keys.count - 1].placement }
        let a = keys[next - 1], b = keys[next]
        let span = b.time - a.time
        let f = span > 1e-6 ? (t - a.time) / span : 1
        return .interpolate(a.placement, b.placement, b.ease(f))
    }

    /// The keyframe at `t`, give or take `tolerance`.
    public func keyframe(at t: Double, tolerance: Double = 1.0 / 30) -> Device3DKeyframe? {
        keyframes.filter { abs($0.time - t) <= tolerance }.min { abs($0.time - t) < abs($1.time - t) }
    }

    /// Changes the pose at `t`: the keyframe there, a new one there when the phone is keyframed, or else the pose
    /// controls' own values. Returns the keyframe changed, if any.
    @discardableResult
    public mutating func setPlacement(_ new: Device3DPlacement, at t: Double, keyframe id: UUID? = nil) -> UUID? {
        if let id, let i = keyframes.firstIndex(where: { $0.id == id }) {
            keyframes[i].placement = new
            return id
        }
        guard !keyframes.isEmpty else {
            placement = new
            return nil
        }
        if let key = keyframe(at: t), let i = keyframes.firstIndex(where: { $0.id == key.id }) {
            keyframes[i].placement = new
            return key.id
        }
        let key = Device3DKeyframe(time: t, placement: new)
        keyframes.append(key)
        keyframes.sort { $0.time < $1.time }
        return key.id
    }

    /// The pose controls, as they start: what double-clicking the preview goes back to.
    public mutating func resetPose() {
        let d = Device3DSettings()
        yaw = d.yaw
        pitch = d.pitch
        rotation = d.rotation
        position = d.position
        scale = d.scale
        lid = d.lid
    }

    var fieldOfView: Double {
        let f = min(max(perspective, 0), 1)
        return Self.fieldOfView.lowerBound + (Self.fieldOfView.upperBound - Self.fieldOfView.lowerBound) * f
    }

    /// The phone's pose at `t` on the edited timeline. `extra` is a zoom's own tilt, added on top; `placement` stands
    /// in for the keyframes' (or controls') pose there.
    public func pose(at t: Double, extra: ScreenTilt = .flat, placement: Device3DPlacement? = nil) -> Device3DPose {
        let radians = Double.pi / 180
        let base = placement ?? self.placement(at: t)
        var yaw = base.yaw * radians
        var pitch = base.pitch * radians
        var drift = CGPoint.zero
        let a = animation
        switch a.motion {
        case .none:
            break
        case .sway:
            yaw += min(max(a.swing, 0), 180) * radians * a.swing(at: t) * (a.startSide == .right ? 1 : -1)
        case .float:
            let amount = min(max(a.amount, 0), 1)
            let phase = t / max(a.duration, 0.1) * .pi
            drift.y = 0.018 * amount * sin(phase)
            yaw += 4 * radians * amount * sin(phase * 0.5 + 0.6)
            pitch += 2.5 * radians * amount * cos(phase * 0.75)
        }
        // A zoom's tilt turns the phone too (its pitch is negative for the top away).
        yaw += extra.yaw
        pitch += abs(extra.yaw) * 0.2
        return Device3DPose(yaw: yaw, pitch: pitch, roll: base.rotation * radians,
                            offset: CGPoint(x: base.position.x + drift.x, y: base.position.y + drift.y),
                            scale: min(max(base.scale, Self.scaleRange.lowerBound), Self.scaleRange.upperBound),
                            lid: min(max(base.lid, Self.lidRange.lowerBound), Self.lidRange.upperBound) * radians)
    }
}

public struct Device3DPose: Equatable {
    /// Radians; positive turns the right edge away.
    public var yaw: Double
    /// Radians; positive tips the top away.
    public var pitch: Double
    /// Radians, counter-clockwise in the picture.
    public var roll: Double
    /// Fractions of the frame; positive y is up.
    public var offset: CGPoint
    public var scale: Double
    /// Radians a laptop's lid stands open.
    public var lid: Double = .pi / 2
}
