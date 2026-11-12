//
//  FrameRenderer+Device3D.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/15/26.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Flat scenes the size of a take's picture, for drawing the pointer and clicks on the 3D phone's display just as
/// the flat frame draws them. Kept per scene, so they're made again whenever the project or pointer changes.
final class DisplaySurfaces: @unchecked Sendable {
    private let lock = NSLock()
    private var scenes: [String: RenderScene] = [:]

    func scene(for scene: RenderScene, canvas: CGSize) -> RenderScene {
        let key = "\(canvas.width)x\(canvas.height)"
        return lock.withLock {
            if let made = scenes[key] { return made }
            var project = scene.project
            project.style.padding = 0
            project.zoomBlocks = []
            project.cameraBlocks = []
            project.transitions = []
            let made = RenderScene(project: project, output: canvas, cursor: scene.cursor)
            scenes[key] = made
            return made
        }
    }
}

extension RenderScene {
    /// The 3D device's settings and the take at `t`, when that take is shown on it (an iPhone take on a phone, a
    /// screen recording on a laptop).
    public func device3D(at t: Double) -> (settings: Device3DSettings, clip: Clip)? {
        let settings = project.device3D
        guard settings.enabled else { return nil }
        let i = clipIndex(at: t)
        guard project.clips.indices.contains(i), settings.applies(to: project.clips[i]) else { return nil }
        return (settings, project.clips[i])
    }
}

extension FrameRenderer {
    /// The 3D phone with its shadow at `t`, seen through `view` (the zoom). Nil draws the moment flat: 3D is off,
    /// this take isn't a device recording, or the model couldn't be loaded.
    func device3DLayer(_ screen: CIImage, scene: RenderScene, time t: Double, view: CGRect, ignoreZoom: Bool,
                       placement: Device3DPlacement? = nil) -> CIImage? {
        guard let (settings, clip) = scene.device3D(at: t) else { return nil }
        let renderer = Device3DRenderer.shared
        guard let aspect = renderer.displayAspect(for: settings.model) else { return nil }
        let out = scene.output
        let whole = CGRect(origin: .zero, size: out)
        let base = min(out.width, out.height)
        let margin = base * (max(scene.project.style.effectivePadding, 0.04) + 0.03)
        let request = Device3DRequest(
            output: out, view: view, fit: whole.insetBy(dx: margin, dy: margin),
            pose: settings.pose(at: t, extra: ignoreZoom ? .flat : scene.tilt(at: t), placement: placement), settings: settings,
            landscape: clip.isLandscapeDevice, display: displayImage(screen, scene: scene, time: t, clip: clip, aspect: aspect))
        guard let phone = renderer.render(request) else { return nil }
        let opacity = min(max(settings.shadowOpacity, 0), 1)
        guard opacity > 0.001, !phone.extent.isEmpty else { return phone }
        let k = out.width / request.view.width
        let blur = base * (0.012 + 0.05 * min(max(settings.shadowSoftness, 0), 1)) * k
        let drop = base * 0.07 * min(max(settings.shadowDistance, 0), 1) * k
        let side = -CGFloat(min(max(settings.lightAngle, -1), 1)) * drop * 0.6
        let wide = shadow(of: phone, opacity: opacity * 0.75, blur: blur, offset: CGPoint(x: side, y: -drop))
        let close = shadow(of: phone, opacity: opacity * 0.45, blur: blur * 0.3, offset: CGPoint(x: side * 0.25, y: -drop * 0.25))
        return phone.composited(over: close.composited(over: wide))
    }

    /// What the 3D display shows: the take's picture with its pointer and clicks (an iPhone take lifted out of the
    /// frame's opening and turned upright), shaped to the model's screen: filled when they nearly match, else fitted
    /// on black, the way a phone shows an app made for another screen.
    private func displayImage(_ screen: CIImage, scene: RenderScene, time t: Double, clip: Clip, aspect: CGFloat) -> CIImage? {
        let canvas = clip.device == nil ? screen.extent.size : clip.screenPixelSize
        guard let rect = clip.deviceDisplayRect ?? (canvas.width >= 1 ? CGRect(origin: .zero, size: canvas) : nil), aspect > 0 else { return nil }
        var picture = screen.transformed(by: CGAffineTransform(translationX: -screen.extent.minX, y: -screen.extent.minY))
        let cursor = scene.project.cursor
        if cursor.visible || cursor.clickEffect != .none {
            let surface = scene.displaySurfaces.scene(for: scene, canvas: canvas)
            let g = surface.geometry(at: t)
            let extent = CGRect(origin: .zero, size: canvas)
            picture = screenStack(picture, over: CIImage(color: .clear).cropped(to: extent), scene: surface, time: t, geometry: g,
                                  views: [g.fullView], pointer: surface.pointer(at: t), canvas: extent)
        }
        if let cutout = clip.deviceCutoutRect { picture = paintingOut(cutout, of: picture) }
        var image = picture.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        if clip.isLandscapeDevice {
            // The recording has the phone's top on its left; a quarter turn clockwise stands it up.
            image = image.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        }
        let size = image.extent.size
        guard size.width >= 1, size.height >= 1 else { return nil }
        let source = size.width / size.height
        if abs(log(source / aspect)) < 0.04 {
            let crop = source > aspect
                ? CGRect(x: ((size.width - size.height * aspect) / 2).rounded(), y: 0, width: (size.height * aspect).rounded(), height: size.height)
                : CGRect(x: 0, y: ((size.height - size.width / aspect) / 2).rounded(), width: size.width, height: (size.width / aspect).rounded())
            return image.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        }
        let target = source > aspect ? CGSize(width: size.width, height: (size.width / aspect).rounded())
            : CGSize(width: (size.height * aspect).rounded(), height: size.height)
        return image.transformed(by: CGAffineTransform(translationX: ((target.width - size.width) / 2).rounded(),
                                                       y: ((target.height - size.height) / 2).rounded()))
            .composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: target)))
    }

    /// Covers the frame's island or notch with what's either side of it along its length (the status bar's
    /// background, almost always), so the 3D phone's own island isn't drawn over a second one. A little beyond it
    /// too: a Simulator recording has an island of its own under the frame's, not quite the same shape, whose edge
    /// otherwise peeks out as a dark hairline.
    func paintingOut(_ cutout: CGRect, of picture: CIImage) -> CIImage {
        let margin = max(3, (min(cutout.width, cutout.height) * 0.15).rounded(.up))
        let r = cutout.insetBy(dx: -margin, dy: -margin).intersection(picture.extent.insetBy(dx: 1, dy: 1))
        guard r.width >= 2, r.height >= 2 else { return picture }
        let across = r.width >= r.height
        let before = across ? CGRect(x: r.minX - 1, y: r.minY, width: 1, height: r.height) : CGRect(x: r.minX, y: r.minY - 1, width: r.width, height: 1)
        let after = across ? CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height) : CGRect(x: r.minX, y: r.maxY, width: r.width, height: 1)
        let f = CIFilter.linearGradient()
        f.point0 = across ? CGPoint(x: r.minX, y: r.midY) : CGPoint(x: r.midX, y: r.minY)
        f.point1 = across ? CGPoint(x: r.maxX, y: r.midY) : CGPoint(x: r.midX, y: r.maxY)
        f.color0 = .black
        f.color1 = .white
        let fill = picture.cropped(to: after).clampedToExtent().applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: picture.cropped(to: before).clampedToExtent(), kCIInputMaskImageKey: f.outputImage!,
        ]).cropped(to: r)
        return fill.composited(over: picture)
    }

    /// A soft shadow of the phone's silhouette, blurred at a quarter of the resolution (a wide blur can't show it).
    private func shadow(of layer: CIImage, opacity: Double, blur: CGFloat, offset: CGPoint) -> CIImage {
        let q: CGFloat = blur > 12 ? 0.25 : 1
        let dark = layer.transformed(by: CGAffineTransform(scaleX: q, y: q)).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity)),
        ])
        let sigma = blur * q
        return dark.applyingGaussianBlur(sigma: Double(sigma))
            .cropped(to: dark.extent.insetBy(dx: -sigma * 3, dy: -sigma * 3))
            .transformed(by: CGAffineTransform(scaleX: 1 / q, y: 1 / q).concatenating(CGAffineTransform(translationX: offset.x, y: offset.y)))
    }

    /// The 3D tab's own backgrounds: a flat colour, or a studio sweep lit from just above the phone.
    func device3DBackground(_ settings: Device3DSettings, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let c = settings.backgroundColor
        guard settings.background == .studio else { return CIImage(color: ciColor(c)).cropped(to: rect) }
        func shade(_ k: Double, _ lift: Double) -> CIColor {
            ciColor(RGBA(min(c.r * k + lift, 1), min(c.g * k + lift, 1), min(c.b * k + lift, 1)))
        }
        let f = CIFilter.radialGradient()
        f.center = CGPoint(x: size.width / 2, y: size.height * 0.58)
        f.radius0 = 0
        f.radius1 = Float(hypot(size.width, size.height) * 0.6)
        f.color0 = shade(1.8, 0.05)
        f.color1 = shade(0.35, 0)
        return f.outputImage!.cropped(to: rect)
    }
}
