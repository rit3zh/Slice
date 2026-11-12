//
//  FrameRenderer+Layers.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/13/26.
//

import CoreImage
import CoreImage.CIFilterBuiltins

extension FrameRenderer {
    func screenStack(_ screen: CIImage, over backdrop: CIImage, scene: RenderScene, time t: Double, geometry g: ScreenGeometry,
                             views: [CGRect], pointer: CursorPointer?, canvas: CGRect) -> CIImage {
        let out = scene.output
        let style = scene.project.style
        let layer = views.count > 1
            ? blurredScreenLayer(screen, geometry: g, views: views, style: style, output: out, canvas: canvas)
            : nil
        var image = (layer ?? average(views.map {
            screenLayer(screen, geometry: g, view: $0, style: style, output: out, sharp: views.count == 1)
        })).composited(over: backdrop)
        let viewShutter = style.motionBlur ? style.motionBlurAmount / 60 : 0
        let cursor = scene.project.cursor
        let press = cursor.clickPress ? cursor.pressScale(ages: scene.clicks(at: t, lasting: cursor.clickPressDuration).map(\.age)) : 1
        if let pointer, let layer = cursorLayer(pointer, geometry: g, views: views, viewShutter: viewShutter,
                                                settings: cursor, press: CGFloat(press), output: out, canvas: canvas) {
            image = layer.composited(over: image)
        }
        return clickEffects(on: image, scene: scene, time: t, geometry: g, view: views[0], output: out, canvas: canvas)
    }

    func magnifiedView(_ view: CGRect, lens: LensState, geometry g: ScreenGeometry) -> (view: CGRect, center: CGPoint) {
        let c = g.contentRect
        let p = CGPoint(x: c.minX + lens.center.x * c.width, y: c.minY + lens.center.y * c.height)
        let m = CGFloat(max(lens.magnification, 1))
        let zoomed = CGRect(x: p.x - (p.x - view.minX) / m, y: p.y - (p.y - view.minY) / m,
                            width: view.width / m, height: view.height / m)
        let k = g.output.width / view.width
        return (zoomed, CGPoint(x: (p.x - view.minX) * k, y: g.output.height - (p.y - view.minY) * k))
    }

    func lensViews(scene: RenderScene, time t: Double, lens: LensState, view: CGRect,
                   geometry g: ScreenGeometry) -> (views: [CGRect], center: CGPoint) {
        let now = magnifiedView(view, lens: lens, geometry: g)
        let shutter = scene.project.style.motionBlurAmount / 60
        guard scene.project.style.motionBlur, shutter > 0 else { return ([now.view], now.center) }
        func sample(_ dt: Double) -> CGRect {
            var earlier = scene.lens(at: t - dt) ?? lens
            if scene.lens(at: t - dt) == nil { earlier.magnification = 1 }
            return magnifiedView(view, lens: earlier, geometry: g).view
        }
        let before = sample(shutter)
        let k = g.output.width / now.view.width
        let spread = [abs(now.view.minX - before.minX), abs(now.view.maxX - before.maxX),
                      abs(now.view.minY - before.minY), abs(now.view.maxY - before.maxY)].max()! * k
        guard spread > 1.5 else { return ([now.view], now.center) }
        let count = min(max(Int((spread / 2.5).rounded(.up)), 3), 24)
        return ((0 ..< count).map { sample(shutter * Double($0) / Double(count - 1)) }, now.center)
    }

    func backdrop(scene: RenderScene, time t: Double, options: Options) -> CIImage {
        let style = scene.project.style
        let shown3D = scene.device3D(at: t)
        if let settings = shown3D?.settings, settings.background != .frame {
            return device3DBackground(settings, size: scene.output)
        }
        // A screen filling the frame edge to edge has black behind it; a 3D device always stands on the background.
        if style.padding < 0.0005, !scene.geometry(at: t).shapedByAlpha, shown3D == nil {
            return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: scene.output))
        }
        return background(style: style, image: options.backgroundImage, size: scene.output)
    }

    func background(style: FrameStyle, image: CIImage?, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        if let name = style.backgroundImage, let image, image.extent.width > 0 {
            let e = image.extent
            let s = max(size.width / e.width, size.height / e.height)
            let placed = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: (size.width - e.width * s) / 2, y: (size.height - e.height * s) / 2)))
                .clampedToExtent()
            guard style.backgroundBlur > 0.005 else { return placed.cropped(to: rect) }
            return blurredBackground(placed, key: "\(name)|\(e)", amount: style.backgroundBlur, size: size)
        }
        let f = CIFilter.linearGradient()
        f.point0 = CGPoint(x: 0, y: size.height)
        f.point1 = CGPoint(x: size.width * 0.3, y: 0)
        f.color0 = ciColor(style.backgroundTop)
        f.color1 = ciColor(style.backgroundBottom)
        return f.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    func screenLayer(_ screen: CIImage, geometry g: ScreenGeometry, view: CGRect, style: FrameStyle, output: CGSize,
                     sharp: Bool) -> CIImage {
        let k = output.width / view.width
        let ciRect = flip(viewed(g.contentRect, view: view, output: output), height: output.height)
        let src = screen.extent
        let placed = place(screen.transformed(by: CGAffineTransform(translationX: -src.minX, y: -src.minY)),
                           sourceSize: src.size, into: ciRect, sharp: sharp)

        let base = min(output.width, output.height)
        if g.shapedByAlpha {
            guard style.effectiveShadow > 0 else { return placed }
            return placed.composited(over: shadow(for: placed, strength: style.effectiveShadow, blur: base * 0.02 * k,
                                                  offset: base * 0.008 * k))
        }
        let mask = g.mockup.map { mockupMask($0, geometry: g, rect: ciRect, zoom: k) }
            ?? roundedRect(ciRect, radius: style.effectiveScreenCornerRadius * base * k)
        let layer = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
        return decorated(layer, geometry: g, view: view, style: style, output: output)
    }

    /// The recording's corner radius, unzoomed: a mockup's display has its own. A browser's top corners are square,
    /// so this is its rounded bottom.
    func contentRadius(geometry g: ScreenGeometry, style: FrameStyle, output: CGSize) -> CGFloat {
        if let m = g.mockup {
            let l = m.layout(content: g.contentRect)
            return max(l.contentTopRadius, l.contentBottomRadius)
        }
        return style.effectiveScreenCornerRadius * min(output.width, output.height)
    }

    func decorated(_ layer: CIImage, geometry g: ScreenGeometry, view: CGRect, style: FrameStyle,
                   output: CGSize) -> CIImage {
        var layer = layer
        let k = output.width / view.width
        let base = min(output.width, output.height)
        if let mockup = g.mockup {
            layer = layer.composited(over: mockupLayer(mockup, geometry: g, view: view, output: output))
        } else if style.screenBorder > 0.001, style.framing > 0.001 {
            let ciRect = flip(viewed(g.contentRect, view: view, output: output), height: output.height)
            let radius = style.effectiveScreenCornerRadius * base * k
            let w = max(base * 0.0014 * k, 1)
            let inner = roundedRect(ciRect.insetBy(dx: w, dy: w), radius: max(radius - w, 0))
            let ring = roundedRect(ciRect, radius: radius)
                .applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
            layer = scaleAlpha(ring, by: 0.45 * style.screenBorder * style.framing).composited(over: layer)
        }
        if style.effectiveShadow > 0 {
            layer = layer.composited(over: screenShadow(geometry: g, view: view, style: style, output: output))
        }
        return layer
    }

    /// The screen's drop shadow for `view`. Everything about it (rect, corners, blur, offset) scales with the zoom, so
    /// it's rendered once as seen unzoomed, at a quarter of the resolution (it's a wide blur, so that can't show), kept,
    /// and only moved and scaled to the view: re-blurring it every frame of a zoom, at a radius growing with it, was
    /// most of what a zooming frame cost.
    func screenShadow(geometry g: ScreenGeometry, view: CGRect, style: FrameStyle, output: CGSize) -> CIImage {
        let full = g.fullView
        let k0 = output.width / full.width, k = output.width / view.width
        let base = min(output.width, output.height)
        let q: CGFloat = 0.25
        // A mockup casts its shadow from its own outline.
        let outline = g.mockup.map { $0.layout(content: g.contentRect) }
        let rect = flip(viewed(outline?.outline ?? g.contentRect, view: full, output: output), height: output.height)
        let radius = (outline?.outlineRadius ?? style.effectiveScreenCornerRadius * base) * k0
        let key = "\(rect)|\(radius)|\(style.effectiveShadow)|\(base * k0)" as NSString
        var unzoomed = screenShadows.object(forKey: key)
        if unzoomed == nil {
            let small = CGRect(x: rect.minX * q, y: rect.minY * q, width: rect.width * q, height: rect.height * q)
            let image = shadow(for: roundedRect(small, radius: radius * q), strength: style.effectiveShadow,
                               blur: base * 0.02 * k0 * q, offset: base * 0.008 * k0 * q)
            let bounds = image.extent.integral
            if let cg = context.createCGImage(image, from: bounds) {
                unzoomed = CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: bounds.minX, y: bounds.minY))
                unzoomed.map { screenShadows.setObject($0, forKey: key) }
            }
        }
        guard let unzoomed else { return .empty() }
        let s = k / k0
        let move = CGAffineTransform(a: s / q, b: 0, c: 0, d: s / q, tx: (full.minX - view.minX) * k,
                                     ty: output.height * (1 - s) - (full.minY - view.minY) * k)
        return unzoomed.transformed(by: move)
    }

    static let zoomBlurKernel = kernel("zoomMotionBlur", in: "ZoomBlur", label: "Zoom blur")

    func blurredScreenLayer(_ screen: CIImage, geometry g: ScreenGeometry, views: [CGRect], style: FrameStyle,
                            output: CGSize, canvas: CGRect) -> CIImage? {
        guard let kernel = Self.zoomBlurKernel, let now = views.first, let then = views.last else { return nil }
        var source = screen.transformed(by: CGAffineTransform(translationX: -screen.extent.minX, y: -screen.extent.minY))
        let shrink = viewed(g.contentRect, view: now, output: output).width / source.extent.width
        if shrink < 0.97 {
            let f = CIFilter.lanczosScaleTransform()
            f.inputImage = source.clampedToExtent().cropped(to: source.extent)
            f.scale = Float(shrink)
            f.aspectRatio = 1
            source = f.outputImage!.cropped(to: CGRect(origin: .zero, size: CGSize(
                width: (source.extent.width * shrink).rounded(.down), height: (source.extent.height * shrink).rounded(.down))))
        }
        let size = source.extent.size
        let sampled = g.shapedByAlpha ? source : source.clampedToExtent()
        func rect(_ r: CGRect) -> CIVector { CIVector(x: r.minX, y: r.minY, z: r.width, w: r.height) }
        let base = min(output.width, output.height)
        let radius = g.shapedByAlpha ? 0 : contentRadius(geometry: g, style: style, output: output)
        let args: [Any] = [sampled, rect(now), rect(then), rect(g.contentRect), CIVector(x: output.width, y: output.height),
                           CIVector(x: size.width, y: size.height), Float(radius), Float(g.shapedByAlpha ? 0 : 1),
                           Float(views.count)]
        let covered = views.map { flip(viewed(g.contentRect, view: $0, output: output), height: output.height) }
            .reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -1, dy: -1)
            .intersection(canvas)
        guard !covered.isEmpty,
              let layer = kernel.apply(extent: covered, roiCallback: { _, _ in sampled.extent.isInfinite ? CGRect(origin: .zero, size: size) : sampled.extent },
                                       arguments: args) else { return nil }
        if g.shapedByAlpha {
            guard style.effectiveShadow > 0 else { return layer }
            let k = output.width / now.width
            return layer.composited(over: shadow(for: layer, strength: style.effectiveShadow, blur: base * 0.02 * k,
                                                 offset: base * 0.008 * k))
        }
        return decorated(layer, geometry: g, view: now, style: style, output: output)
    }

    func splitView(_ view: CGRect, slot: CGRect, geometry g: ScreenGeometry, output out: CGSize) -> CGRect {
        guard g.followsCursor else { return view }
        let c = g.contentRect, aspect = out.width / out.height
        let size = c.width / c.height > aspect ? CGSize(width: c.width, height: c.width / aspect)
            : CGSize(width: c.height * aspect, height: c.height)
        let whole = CGRect(x: c.midX - size.width / 2, y: c.midY - size.height / 2, width: size.width, height: size.height)
        let zoom = g.fullBleedSize.width / max(view.width, 1)
        let weight = ScreenSlot.amount(slot) * min(max(2 - zoom, 0), 1)
        return ViewRect.interpolate(ViewRect(view), ViewRect(whole), weight).rect
    }

    func slotPlacement(_ split: CameraState, geometry g: ScreenGeometry, view: CGRect, style: FrameStyle,
                       output out: CGSize)
        -> (transform: CGAffineTransform, mask: CIImage, shadow: CIImage, rect: CGRect, radius: CGFloat)? {
        let amount = ScreenSlot.amount(split.screenSlot)
        let extent = CGRect(origin: .zero, size: out)
        let target = flip(ScreenSlot.rect(split.screenSlot, in: out), height: out.height)
        let shown = flip(viewed(g.frameRect, view: view, output: out), height: out.height).intersection(extent)
        guard target.width > 1, target.height > 1, shown.width > 1, shown.height > 1 else { return nil }
        func placed(_ r: CGRect, _ k: CGFloat) -> (scale: CGFloat, origin: CGPoint) {
            (k, CGPoint(x: target.midX - r.midX * k, y: target.midY - r.midY * k))
        }
        let whole = placed(extent, min(target.width / extent.width, target.height / extent.height))
        let screen = placed(shown, max(target.width / shown.width, target.height / shown.height))
        let k = lerp(whole.scale, screen.scale, amount)
        let transform = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: lerp(whole.origin.x, screen.origin.x, amount),
                                          ty: lerp(whole.origin.y, screen.origin.y, amount))
        let radius = CameraLayoutResolver.splitRadius(style: style, output: out) * CGFloat(amount)
        let mask = seamedRect(target, radius: radius, seam: split.seam, edge: split.seamEdge.opposite)
        let base = min(out.width, out.height)
        let shadow = shadow(for: mask, strength: 0.45 * amount, blur: base * 0.015, offset: base * 0.006)
        return (transform, mask, shadow, target, radius)
    }

    static let cornerRectKernel = kernel("cornerRoundedRect", in: "CameraBlur", label: "Camera shape")

    // Rounds every corner in one shape so the seam side straightens in step; a separate half-rect laid over the
    // full shape bulged out as a lump while a circle morphed to or from a split.
    func seamedRect(_ rect: CGRect, radius: CGFloat, seam: Double, edge: CGRectEdge) -> CIImage {
        guard seam > 0.001, radius > 0.5, let kernel = Self.cornerRectKernel else { return roundedRect(rect, radius: radius) }
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        let s = r * CGFloat(1 - min(seam, 1))
        let radii: CIVector = switch edge {
        case .minXEdge: CIVector(x: s, y: r, z: s, w: r)
        case .maxXEdge: CIVector(x: r, y: s, z: r, w: s)
        case .minYEdge: CIVector(x: r, y: r, z: s, w: s)
        default: CIVector(x: s, y: s, z: r, w: r)
        }
        let bounds = CIVector(x: rect.minX, y: rect.minY, z: rect.width, w: rect.height)
        return kernel.apply(extent: rect.insetBy(dx: -1, dy: -1), roiCallback: { _, _ in .null },
                            arguments: [bounds, radii]) ?? roundedRect(rect, radius: radius)
    }

    func cameraLayer(_ camera: CIImage, state: CameraState, style: FrameStyle, options: Options,
                     output: CGSize) -> CIImage {
        let rect = flip(state.rect, height: output.height)
        var cam = camera.transformed(by: CGAffineTransform(translationX: -camera.extent.minX, y: -camera.extent.minY))
        let size = camera.extent.size
        if style.cameraBackgroundBlur > 0.01 {
            cam = blurBackground(cam, pixelBuffer: camera.pixelBuffer, strength: style.cameraBackgroundBlur,
                                 accurate: options.accurateSegmentation)
        }
        cam = style.cameraFilter.apply(to: cam)
        if style.mirrorCamera {
            cam = cam.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -size.width, y: 0))
        }
        let s = max(rect.width / size.width, rect.height / size.height)
        let filled = CGRect(x: rect.midX - size.width * s / 2, y: rect.midY - size.height * s / 2,
                            width: size.width * s, height: size.height * s)
        let placed = place(cam, sourceSize: size, into: filled, sharp: true).cropped(to: rect)
        let mask = seamedRect(rect, radius: state.cornerRadius, seam: state.seam, edge: state.seamEdge)
        var layer = placed.applyingFilter("CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask,
        ])
        let base = min(output.width, output.height)
        layer = layer.composited(over: shadow(for: mask, strength: 0.45, blur: base * 0.015, offset: base * 0.006))
        if state.opacity < 1 { layer = scaleAlpha(layer, by: state.opacity) }
        return layer
    }

    static let cameraBlurKernel = kernel("cameraMotionBlur", in: "CameraBlur", label: "Camera blur")

    func smeared(_ layer: CIImage, from now: CGRect, to then: CGRect, count: Int) -> CIImage {
        guard let kernel = Self.cameraBlurKernel, now.width > 0, now.height > 0, then.width > 0, then.height > 0
        else { return layer }
        let source = layer.extent
        func moved(onto r: CGRect) -> CGRect {
            let k = CGSize(width: r.width / now.width, height: r.height / now.height)
            return CGRect(x: r.minX + (source.minX - now.minX) * k.width, y: r.minY + (source.minY - now.minY) * k.height,
                          width: source.width * k.width, height: source.height * k.height)
        }
        func rect(_ r: CGRect) -> CIVector { CIVector(x: r.minX, y: r.minY, z: r.width, w: r.height) }
        let covered = source.union(moved(onto: then)).integral
        return kernel.apply(extent: covered, roiCallback: { _, _ in source },
                            arguments: [layer, rect(now), rect(then), Float(count)]) ?? layer
    }
}

extension CGRectEdge {
    var opposite: CGRectEdge {
        switch self {
        case .minXEdge: .maxXEdge
        case .maxXEdge: .minXEdge
        case .minYEdge: .maxYEdge
        default: .minYEdge
        }
    }
}
