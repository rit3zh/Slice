//
//  DeviceCompositor.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/7/26.
//

import CoreVideo
import Foundation
import Metal

public final class DeviceFrameTextures: @unchecked Sendable {
    public let definition: DeviceFrameDefinition
    let frame: MTLTexture
    let mask: MTLTexture

    init(definition: DeviceFrameDefinition, frame: MTLTexture, mask: MTLTexture) {
        self.definition = definition
        self.frame = frame
        self.mask = mask
    }
}

public final class DeviceCompositor: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let library: MTLLibrary
    let textureCache: CVMetalTextureCache
    private let lock = NSLock()
    private var frames: [String: DeviceFrameTextures] = [:]

    public static let shared: DeviceCompositor? = DeviceCompositor()

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let url = Bundle.module.url(forResource: "DeviceFrame", withExtension: "metal.txt"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "deviceFrameVertex")
            desc.fragmentFunction = library.makeFunction(name: "deviceFrameFragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            self.library = library
        } catch {
            NSLog("Device frame shader failed to build: \(error)")
            return nil
        }
        let s = MTLSamplerDescriptor()
        s.minFilter = .linear
        s.magFilter = .linear
        s.mipFilter = .linear
        s.sAddressMode = .clampToEdge
        s.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: s) else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { return nil }
        self.device = device
        commandQueue = queue
        self.sampler = sampler
        textureCache = cache
    }

    // MARK: - Frame images

    /// `withoutCutout` leaves the frame's island or notch out, for a recording with its own.
    public func textures(for definition: DeviceFrameDefinition, withoutCutout: Bool = false) throws -> DeviceFrameTextures {
        let key = definition.cacheKey + (withoutCutout ? " without cutout" : "")
        if let cached = lock.withLock({ frames[key] }) { return cached }
        var image = try definition.frameURL.map(DeviceFrameImage.load) ?? .frameless(size: definition.canvasSize)
        if withoutCutout { image = image.withoutCutout() }
        guard let frame = makeTexture(.bgra8Unorm, image.width, image.height, bytes: image.pixels, bytesPerRow: image.width * 4),
              let mask = makeTexture(.r8Unorm, image.width, image.height, bytes: image.mask, bytesPerRow: image.width)
        else { throw DeviceFrameImage.LoadError.unreadable(definition.frameURL ?? URL(fileURLWithPath: "/")) }
        generateMipmaps([frame, mask])
        let textures = DeviceFrameTextures(definition: definition, frame: frame, mask: mask)
        lock.withLock { frames[key] = textures }
        return textures
    }

    private func makeTexture(_ format: MTLPixelFormat, _ w: Int, _ h: Int, bytes: [UInt8], bytesPerRow: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: true)
        desc.usage = .shaderRead
        desc.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        bytes.withUnsafeBytes {
            texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: bytesPerRow)
        }
        return texture
    }

    private func generateMipmaps(_ textures: [MTLTexture]) {
        guard let commands = commandQueue.makeCommandBuffer(), let blit = commands.makeBlitCommandEncoder() else { return }
        textures.forEach { blit.generateMipmaps(for: $0) }
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
    }

    // MARK: - Drawing

    /// A Metal texture over a pixel buffer's IOSurface, with no copy. The returned object must be kept alive until the
    /// GPU has finished with the texture.
    public func texture(for buffer: CVPixelBuffer, format: MTLPixelFormat = .bgra8Unorm) -> (MTLTexture, CVMetalTexture)? {
        var cv: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, buffer, nil, format, CVPixelBufferGetWidth(buffer),
                                                  CVPixelBufferGetHeight(buffer), 0, &cv)
        guard let cv, let texture = CVMetalTextureGetTexture(cv) else { return nil }
        return (texture, cv)
    }

    public func encode(into commands: MTLCommandBuffer, target: MTLTexture, rect: CGRect, frame: DeviceFrameTextures,
                       layout: DeviceLayout, screen: MTLTexture?) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        let w = CGFloat(target.width), h = CGFloat(target.height)
        var u = Uniforms(
            destination: SIMD4(Float(rect.minX / w * 2 - 1), Float(1 - rect.minY / h * 2),
                               Float(rect.maxX / w * 2 - 1), Float(1 - rect.maxY / h * 2)),
            screenRect: SIMD4(layout.screenRect), streamCrop: SIMD4(layout.streamCrop),
            landscape: layout.landscape ? 1 : 0, hasScreen: screen == nil ? 0 : 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentTexture(frame.frame, index: 0)
        encoder.setFragmentTexture(frame.mask, index: 1)
        // The shader still binds slot 2 when there's no screen; the mask stands in and is never sampled.
        encoder.setFragmentTexture(screen ?? frame.mask, index: 2)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Matches `DeviceFrameUniforms` in the shader.
    private struct Uniforms {
        var destination: SIMD4<Float>
        var screenRect: SIMD4<Float>
        var streamCrop: SIMD4<Float>
        var landscape: UInt32
        var hasScreen: UInt32
    }
}

private extension SIMD4 where Scalar == Float {
    init(_ r: CGRect) { self.init(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)) }
}

public final class MipmappedScreen {
    private let compositor: DeviceCompositor
    private var texture: MTLTexture?

    public init(compositor: DeviceCompositor) { self.compositor = compositor }

    public func texture(for buffer: CVPixelBuffer, commands: MTLCommandBuffer) -> MTLTexture? {
        guard let (source, cv) = compositor.texture(for: buffer) else { return nil }
        if texture?.width != source.width || texture?.height != source.height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: source.width,
                                                                height: source.height, mipmapped: true)
            desc.usage = .shaderRead
            desc.storageMode = .private
            texture = compositor.device.makeTexture(descriptor: desc)
        }
        guard let texture, let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, to: texture, destinationSlice: 0, destinationLevel: 0,
                  sliceCount: 1, levelCount: 1)
        blit.generateMipmaps(for: texture)
        blit.endEncoding()
        commands.addCompletedHandler { _ in withExtendedLifetime(cv) {} }
        return texture
    }
}

public final class DeviceSurfaceRenderer: @unchecked Sendable {
    public let size: CGSize
    private let compositor: DeviceCompositor
    private let pool: CVPixelBufferPool

    public init?(compositor: DeviceCompositor, size: CGSize) {
        let w = (Int(size.width.rounded(.up)) + 1) / 2 * 2, h = (Int(size.height.rounded(.up)) + 1) / 2 * 2
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &pool)
        guard let pool else { return nil }
        self.size = CGSize(width: w, height: h)
        self.compositor = compositor
        self.pool = pool
    }

    public func render(screen: CVPixelBuffer?, frame: DeviceFrameTextures, layout: DeviceLayout,
                       completion: @escaping (CVPixelBuffer?) -> Void) {
        var out: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
        guard let out, let (target, targetCV) = compositor.texture(for: out),
              let commands = compositor.commandQueue.makeCommandBuffer() else {
            completion(nil)
            return
        }
        let source = screen.flatMap { compositor.texture(for: $0) }
        compositor.encode(into: commands, target: target, rect: layout.fitted(in: size), frame: frame, layout: layout,
                          screen: source?.0)
        CVBufferSetAttachment(out, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                              .shouldPropagate)
        commands.addCompletedHandler { buffer in
            withExtendedLifetime((targetCV, source?.1)) {}
            completion(buffer.status == .completed ? out : nil)
        }
        commands.commit()
    }

    public func renderNow(screen: CVPixelBuffer?, frame: DeviceFrameTextures, layout: DeviceLayout) -> CVPixelBuffer? {
        let done = DispatchSemaphore(value: 0)
        var result: CVPixelBuffer?
        render(screen: screen, frame: frame, layout: layout) {
            result = $0
            done.signal()
        }
        done.wait()
        return result
    }
}
