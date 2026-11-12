//
//  Device3DStage+Drawing.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/15/26.
//

import AppKit
import CoreImage
import CoreVideo
import Metal
import SceneKit
import simd

extension Device3DStage {
    func render(_ request: Device3DRequest) -> CIImage? {
        let out = request.output
        guard out.width >= 2, out.height >= 2, request.view.width > 0, request.view.height > 0 else { return nil }

        // Every change to the scene, the display's texture included, goes in before the frame is drawn: a change made
        // outside a committed transaction only reaches SceneKit on the frame after.
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        dress(request.settings)
        let full = place(request)
        let display = prepareDisplay(request.display)
        guard let region = region(for: request, projection: full) else {
            SCNTransaction.commit()
            return .empty()
        }
        // Draw only the part of the frame the phone covers (zoomed), at the frame's resolution.
        let k = out.width / request.view.width
        let shown = CGRect(x: request.view.minX + region.minX / k, y: request.view.minY + region.minY / k,
                           width: region.width / k, height: region.height / k)
        camera.projectionTransform = SCNMatrix4(Self.crop(to: shown, of: out) * Self.metalDepth * full)
        SCNTransaction.commit()
        SCNTransaction.flush()

        let w = Int(region.width), h = Int(region.height)
        guard let commands = queue.makeCommandBuffer(), let buffer = pixelBuffer(width: w, height: h),
              let (resolve, cv) = texture(for: buffer), let (color, depth) = renderTargets(width: w, height: h) else { return nil }
        if let display { encode(display.image, into: display.texture, commands: commands) }
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].resolveTexture = resolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.clearDepth = renderer.usesReverseZ ? 0 : 1
        renderer.render(atTime: 0, viewport: CGRect(x: 0, y: 0, width: w, height: h), commandBuffer: commands, passDescriptor: pass)
        commands.commit()
        commands.waitUntilCompleted()
        withExtendedLifetime(cv) {}
        guard commands.status == .completed else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                              .shouldPropagate)
        return CIImage(cvPixelBuffer: buffer, options: [.colorSpace: Self.sRGB])
            .transformed(by: CGAffineTransform(translationX: region.minX, y: out.height - region.maxY))
    }

    static let tintModifier = """
    #pragma arguments
    float3 sliceTint;
    #pragma body
    _surface.diffuse.rgb = sliceTint * dot(_surface.diffuse.rgb, float3(0.2126, 0.7152, 0.0722));
    """

    /// Finish and lights.
    func dress(_ settings: Device3DSettings) {
        // Resized or moved, the island is Slice's pill over the patch, wherever the model's own was cut out.
        let sizes = Device3DSettings.islandSizeRange, offsets = Device3DSettings.islandOffsetRange
        let size = Float(min(max(settings.islandSize, sizes.lowerBound), sizes.upperBound))
        let offset = Float(min(max(settings.islandOffset, offsets.lowerBound), offsets.upperBound))
        let custom = abs(size - 1) > 0.001 || abs(offset) > 0.001
        for node in island { node.isHidden = !settings.dynamicIsland || custom }
        islandPatch?.isHidden = settings.dynamicIsland && !custom
        if let pill = islandPill {
            pill.isHidden = !settings.dynamicIsland || !(custom || model.drawsIsland)
            // Moved by its own height: positive is further down the display.
            let height = pill.boundingBox.max.y - pill.boundingBox.min.y
            pill.simdScale = SIMD3(size, size, 1)
            pill.simdPosition = islandPillRest - SIMD3(0, offset * Float(height), 0)
        }
        if finish != settings.finish {
            finish = settings.finish
            let native = model.finishes.first == settings.finish
            func color(_ c: SIMD3<Float>) -> NSColor {
                NSColor(colorSpace: Self.linearSpace, components: [CGFloat(c.x), CGFloat(c.y), CGFloat(c.z), 1], count: 4)
            }
            func tinted(_ original: SIMD3<Float>) -> SIMD3<Float> {
                let lum = (original * SIMD3(0.2126, 0.7152, 0.0722)).sum()
                return settings.finish.tint * min(max(lum / template.bodyLuminance, 0.3), 1.0)
            }
            for (material, original) in bodyMaterials {
                if let diffuse = original.diffuse {
                    material.diffuse.contents = color(native ? diffuse : tinted(diffuse))
                } else if model.tintsTextures {
                    // The picture carries detail (a keyboard, a logo): kept, its brightness taking the new colour.
                    let tint = settings.finish.tint / template.bodyLuminance
                    material.shaderModifiers = native ? nil : [.surface: Self.tintModifier]
                    material.setValue(NSValue(scnVector3: SCNVector3(tint.x, tint.y, tint.z)), forKey: "sliceTint")
                } else {
                    // A pictured body part keeps its picture in its own colour, and takes the new colour plain (a
                    // coloured picture can't be tinted to another colour, only towards it).
                    material.diffuse.contents = native ? texturedDiffuse[ObjectIdentifier(material)] : color(settings.finish.tint)
                }
                if let glow = original.emission { material.emission.contents = color(native ? glow : tinted(glow)) }
            }
        }
        let brightness = Float(min(max(settings.brightness, 0), 2))
        let angle = Float(min(max(settings.lightAngle, -1), 1))
        key.light?.intensity = CGFloat(1000 * brightness)
        fill.light?.intensity = CGFloat(320 * brightness)
        ambient.light?.intensity = CGFloat(140 * brightness)
        // A directional light shines down its -z: turned by a negative angle it comes from the left.
        key.simdEulerAngles = SIMD3(-0.6, angle * 1.1, 0)
        fill.simdEulerAngles = SIMD3(-0.15, angle > 0 ? -0.9 : 0.9, 0)
        scene.lightingEnvironment.intensity = CGFloat((0.3 + 1.7 * Float(min(max(settings.reflections, 0), 1))) * brightness)
        scene.lightingEnvironment.contentsTransform = SCNMatrix4MakeRotation(CGFloat(angle) * 0.8, 0, 1, 0)
    }

    /// Poses the phone and camera for the unzoomed frame; returns that frame's projection.
    func place(_ request: Device3DRequest) -> simd_float4x4 {
        let out = request.output, size = template.size, pose = request.pose
        let apparent = request.landscape ? SIMD2(size.y, size.x) : SIMD2(size.x, size.y)
        let fit = request.fit
        let ppu = max(min(Float(fit.width) / apparent.x, Float(fit.height) / apparent.y), 1)
        let lensWidth = Float(request.settings.fieldOfView)
        let natural = Float(out.height) / (2 * tan(lensWidth * .pi / 360) * ppu)
        let reach = template.radius * Float(pose.scale)
        // Made large under a wide lens, a device reaches the camera (a laptop's deep base and tall lid soonest) and is
        // cut through where it passes it. The camera backs away instead and narrows its lens to keep the device the
        // same size, as a dolly zoom does; going by the device's reach in every direction, it holds still as it turns.
        let distance = max(natural, reach * 1.15 + 0.05)
        let fov = distance > natural ? 2 * atan(Float(out.height) / (2 * distance * ppu)) * 180 / .pi : lensWidth
        for c in [camera, lens] {
            c.fieldOfView = CGFloat(fov)
            c.zNear = Double(max(min(distance - reach - 0.02, distance * 0.5), 0.005))
            c.zFar = Double(distance * 2 + reach)
        }
        cameraNode.simdPosition = SIMD3(0, 0, distance)
        let x = (Float(fit.midX) - Float(out.width) / 2) / ppu + Float(pose.offset.x) * Float(out.width) / ppu
        let y = -(Float(fit.midY) - Float(out.height) / 2) / ppu + Float(pose.offset.y) * Float(out.height) / ppu
        phone.simdPosition = SIMD3(x, y, 0)
        let roll = Float(pose.roll) + (request.landscape ? .pi / 2 : 0)
        phone.simdOrientation = simd_quatf(angle: Float(pose.yaw), axis: SIMD3(0, 1, 0))
            * simd_quatf(angle: -Float(pose.pitch), axis: SIMD3(1, 0, 0))
            * simd_quatf(angle: roll, axis: SIMD3(0, 0, 1))
        phone.simdScale = SIMD3(repeating: Float(pose.scale))
        lid?.simdOrientation = simd_quatf(angle: template.lidOpening - Float(pose.lid), axis: SIMD3(1, 0, 0))
        // `lens` never has its projection set, so it always reports SceneKit's own for the current field of view.
        return simd_float4x4(lens.projectionTransform(withViewportSize: out))
    }

    /// The part of the output the posed phone covers, padded and rounded up to a few sizes so buffers get reused.
    func region(for request: Device3DRequest, projection: simd_float4x4) -> CGRect? {
        let out = request.output
        let view = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0),
                                           SIMD4(0, 0, -cameraNode.simdPosition.z, 1)))
        let m = projection * view * phone.simdTransform
        let b = template.extent
        var lo = CGPoint(x: CGFloat.infinity, y: .infinity), hi = CGPoint(x: -CGFloat.infinity, y: -.infinity)
        for i in 0 ..< 8 {
            let p = SIMD4<Float>(i & 1 == 0 ? b.min.x : b.max.x, i & 2 == 0 ? b.min.y : b.max.y, i & 4 == 0 ? b.min.z : b.max.z, 1)
            let c = m * p
            // Part of the phone reaches past the camera: it can be anywhere in the picture.
            guard c.w > 1e-4 else { return CGRect(origin: .zero, size: CGSize(width: out.width.rounded(.down), height: out.height.rounded(.down))) }
            let x = CGFloat((c.x / c.w + 1) / 2) * out.width, y = CGFloat((1 - c.y / c.w) / 2) * out.height
            lo = CGPoint(x: min(lo.x, x), y: min(lo.y, y))
            hi = CGPoint(x: max(hi.x, x), y: max(hi.y, y))
        }
        let k = out.width / request.view.width
        let margin = 4 + min(out.width, out.height) * 0.01
        let covered = CGRect(x: (lo.x - request.view.minX) * k - margin, y: (lo.y - request.view.minY) * k - margin,
                             width: (hi.x - lo.x) * k + 2 * margin, height: (hi.y - lo.y) * k + 2 * margin)
            .intersection(CGRect(origin: .zero, size: out))
        guard !covered.isNull, covered.width >= 1, covered.height >= 1 else { return nil }
        let step: CGFloat = 64
        let w = min((covered.width / step).rounded(.up) * step, out.width.rounded(.down))
        let h = min((covered.height / step).rounded(.up) * step, out.height.rounded(.down))
        let x = max(min(covered.minX.rounded(.down), out.width.rounded(.down) - w), 0)
        let y = max(min(covered.minY.rounded(.down), out.height.rounded(.down) - h), 0)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// SceneKit hands out projections with OpenGL's depth (-1 at the near plane to 1 at the far one) but takes a set one
    /// as Metal's (0 to 1), before turning it round for its reversed depth buffer. Set as given, the near plane landed
    /// at about twice its distance and sliced through anything deep (a laptop's lid) as it turned.
    static let metalDepth = simd_float4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0.5, 0.5), SIMD4(0, 0, 0, 1)])

    /// Narrows a projection of the whole `size` frame to `rect` of it (top-left origin), so that part fills the target.
    static func crop(to rect: CGRect, of size: CGSize) -> simd_float4x4 {
        let a0 = Float(2 * rect.minX / size.width - 1), a1 = Float(2 * rect.maxX / size.width - 1)
        let b0 = Float(1 - 2 * rect.maxY / size.height), b1 = Float(1 - 2 * rect.minY / size.height)
        let sx = 2 / (a1 - a0), sy = 2 / (b1 - b0)
        return simd_float4x4(columns: (SIMD4(sx, 0, 0, 0), SIMD4(0, sy, 0, 0), SIMD4(0, 0, 1, 0),
                                       SIMD4(-(a0 + a1) / (a1 - a0), -(b0 + b1) / (b1 - b0), 0, 1)))
    }

    // MARK: Textures

    /// Readies the display's texture for `image` (or a dark display) and puts it on the display.
    func prepareDisplay(_ image: CIImage?) -> (image: CIImage, texture: MTLTexture)? {
        guard let image, image.extent.width >= 1, image.extent.height >= 1, !image.extent.isInfinite else {
            displayMaterial.diffuse.contents = NSColor.black
            return nil
        }
        let limit: CGFloat = 4096
        var source = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        if let region = template.screenRegion { source = inBezel(source, region: region) }
        let fit = min(limit / source.extent.width, limit / source.extent.height, 1)
        if fit < 1 { source = source.transformed(by: CGAffineTransform(scaleX: fit, y: fit), highQualityDownsample: true) }
        let w = Int(source.extent.width.rounded()), h = Int(source.extent.height.rounded())
        if displayTexture?.base.width != w || displayTexture?.base.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
            d.usage = [.shaderRead, .shaderWrite, .renderTarget, .pixelFormatView]
            d.storageMode = .private
            guard let base = device.makeTexture(descriptor: d), let view = base.makeTextureView(pixelFormat: .bgra8Unorm_srgb) else {
                displayTexture = nil
                displayMaterial.diffuse.contents = NSColor.black
                return nil
            }
            displayTexture = (base, view)
        }
        guard let (base, view) = displayTexture else { return nil }
        // Sampled through an sRGB view, so the constant-lit display lands on screen in exactly the recording's colours.
        if displayMaterial.diffuse.contents as AnyObject? !== view { displayMaterial.diffuse.contents = view }
        return (source, base)
    }

    /// The picture set into the display where its screen is, black around it (the bezel) and over the notch.
    private func inBezel(_ picture: CIImage, region: CGRect) -> CIImage {
        let canvas = CGRect(x: 0, y: 0, width: (picture.extent.width / region.width).rounded(),
                            height: (picture.extent.height / region.height).rounded())
        let black = CIImage(color: .black).cropped(to: canvas)
        let placed = picture.transformed(by: CGAffineTransform(translationX: (region.minX * canvas.width).rounded(),
                                                               y: ((1 - region.maxY) * canvas.height).rounded()))
            .composited(over: black)
        guard let mask = template.screenMask else { return placed.cropped(to: canvas) }
        let m = CIImage(cgImage: mask)
        let scaled = m.transformed(by: CGAffineTransform(scaleX: canvas.width / m.extent.width, y: canvas.height / m.extent.height))
        return placed.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: black, kCIInputMaskImageKey: scaled])
            .cropped(to: canvas)
    }

    func encode(_ image: CIImage, into texture: MTLTexture, commands: MTLCommandBuffer) {
        let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: commands)
        destination.isFlipped = true
        destination.colorSpace = Self.sRGB
        destination.alphaMode = .premultiplied
        _ = try? context.startTask(toRender: image.composited(over: CIImage(color: .black).cropped(to: image.extent)), to: destination)
        if let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
        }
    }

    func renderTargets(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        if let targets, targets.color.width == width, targets.color.height == height { return targets }
        // Apple GPUs keep multisampled attachments in tile memory, so they cost nothing at any size.
        let storage: MTLStorageMode = device.supportsFamily(.apple1) ? .memoryless : .private
        func make(_ format: MTLPixelFormat) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            d.textureType = .type2DMultisample
            d.sampleCount = Self.samples
            d.usage = .renderTarget
            d.storageMode = storage
            return device.makeTexture(descriptor: d)
        }
        guard let color = make(.bgra8Unorm_srgb), let depth = make(.depth32Float) else { return nil }
        targets = (color, depth)
        return targets
    }

    func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let key = "\(width)x\(height)"
        if pools[key] == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            var pool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
            pools[key] = pool
            poolOrder.append(key)
            if poolOrder.count > 6 { pools[poolOrder.removeFirst()] = nil }
        }
        guard let pool = pools[key] else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }

    func texture(for buffer: CVPixelBuffer) -> (MTLTexture, CVMetalTexture)? {
        var cv: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, .bgra8Unorm_srgb, CVPixelBufferGetWidth(buffer),
                                                  CVPixelBufferGetHeight(buffer), 0, &cv)
        guard let cv, let texture = CVMetalTextureGetTexture(cv) else { return nil }
        return (texture, cv)
    }

    static let linearSpace = NSColorSpace(cgColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!

    /// A photo studio for the metal and glass to reflect: a dim room with a large soft box overhead and strip lights
    /// either side, as an equirectangular map.
    static let environment: CGImage? = {
        let w = 1024, h = 512
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(gray: 0.42, alpha: 1), CGColor(gray: 0.16, alpha: 1), CGColor(gray: 0.06, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: sRGB, colors: colors, locations: [0, 0.5, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])
        }
        func softBox(_ rect: CGRect, _ level: CGFloat) {
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: min(rect.width, rect.height) * 0.6, color: CGColor(gray: level, alpha: 1))
            ctx.setFillColor(CGColor(gray: level, alpha: 1))
            ctx.fill(rect)
            ctx.restoreGState()
        }
        softBox(CGRect(x: 384, y: 360, width: 256, height: 90), 1)
        softBox(CGRect(x: 150, y: 210, width: 60, height: 170), 0.9)
        softBox(CGRect(x: 820, y: 220, width: 50, height: 150), 0.75)
        softBox(CGRect(x: 560, y: 250, width: 70, height: 60), 0.55)
        return ctx.makeImage()
    }()
}
