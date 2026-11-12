//
//  Device3DStage.swift
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

/// One copy of the phone with its own renderer, textures and targets. A stage draws one frame at a time.
final class Device3DStage {
    let model: Device3DModel
    let template: Device3DTemplate
    let device: MTLDevice
    let queue: MTLCommandQueue
    let context: CIContext
    let renderer: SCNRenderer
    let scene = SCNScene()
    let phone: SCNNode
    /// A laptop's lid, on its hinge.
    let lid: SCNNode?
    let cameraNode = SCNNode()
    let camera = SCNCamera()
    let lens = SCNCamera()
    let key = SCNNode()
    let fill = SCNNode()
    let ambient = SCNNode()
    let displayMaterial = SCNMaterial()
    /// The Dynamic Island's parts, and the patch of display drawn where it was when it's switched off.
    var island: [SCNNode] = []
    let islandPatch: SCNNode?
    /// Slice's own island, which stands in for the model's when it's resized or moved, and where it sits at rest.
    let islandPill: SCNNode?
    let islandPillRest: SIMD3<Float>
    var bodyMaterials: [(material: SCNMaterial, color: (diffuse: SIMD3<Float>?, emission: SIMD3<Float>?))] = []
    /// The pictures on textured body parts, to put back for the model's own finish.
    var texturedDiffuse: [ObjectIdentifier: Any] = [:]
    var finish: Device3DFinish?
    var displayTexture: (base: MTLTexture, view: MTLTexture)?
    var targets: (color: MTLTexture, depth: MTLTexture)?
    var pools: [String: CVPixelBufferPool] = [:]
    var poolOrder: [String] = []
    let textureCache: CVMetalTextureCache
    let pass = MTLRenderPassDescriptor()

    static let samples = 4
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    init?(model: Device3DModel, template: Device3DTemplate, device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        guard let cache else { return nil }
        self.model = model
        self.template = template
        self.device = device
        self.queue = queue
        textureCache = cache
        context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
        renderer = SCNRenderer(device: device, options: nil)

        phone = template.root.clone()
        lid = phone.childNode(withName: Device3DTemplate.lidName, recursively: true)
        islandPatch = phone.childNode(withName: Device3DTemplate.islandPatchName, recursively: true)
        islandPill = phone.childNode(withName: Device3DTemplate.islandPillName, recursively: true)
        islandPillRest = islandPill?.simdPosition ?? .zero
        phone.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry?.copy() as? SCNGeometry else { return }
            geometry.materials = geometry.materials.map { ($0.copy() as? SCNMaterial) ?? $0 }
            node.geometry = geometry
        }
        phone.enumerateHierarchy { node, _ in
            for material in node.geometry?.materials ?? [] {
                if let name = material.name, let color = template.bodyColors[name] {
                    bodyMaterials.append((material, color))
                    if color.diffuse == nil, let picture = material.diffuse.contents { texturedDiffuse[ObjectIdentifier(material)] = picture }
                }
            }
        }
        displayMaterial.lightingModel = .constant
        displayMaterial.diffuse.contents = NSColor.black
        displayMaterial.isDoubleSided = true
        // Seen nearly edge-on a display goes dark, as real glass does. Drawn at full brightness it showed as a bright
        // sliver beyond the frame, its picture squeezed into a strip of sparkling texels. The surface's own facing
        // comes from its position, as models' display normals can't be trusted.
        displayMaterial.shaderModifiers = [.fragment: """
        float3 p = _surface.position;
        float3 n = cross(dfdx(p), dfdy(p));
        float facing = length(n) > 0.0 ? abs(dot(normalize(n), normalize(-p))) : 1.0;
        _output.color.rgb *= smoothstep(0.06, 0.45, facing);
        """]
        for property in [displayMaterial.diffuse] {
            property.minificationFilter = .linear
            property.magnificationFilter = .linear
            property.mipFilter = .linear
            property.maxAnisotropy = 16
            property.wrapS = .clamp
            property.wrapT = .clamp
        }
        phone.childNode(withName: Device3DTemplate.displayName, recursively: true)?.geometry?.materials = [displayMaterial]
        islandPatch?.geometry?.materials = [displayMaterial]
        phone.childNode(withName: Device3DTemplate.displaySeamName, recursively: true)?.geometry?.materials = [displayMaterial]
        phone.enumerateHierarchy { node, _ in
            if node.categoryBitMask & Device3DTemplate.islandCategory != 0, node !== islandPill { island.append(node) }
        }
        scene.rootNode.addChildNode(phone)

        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = Self.environment
        for (node, type) in [(key, SCNLight.LightType.directional), (fill, .directional), (ambient, .ambient)] {
            node.light = SCNLight()
            node.light?.type = type
            // Glass the island's parts take in stays out of the studio lights too.
            node.light?.categoryBitMask = ~(Device3DTemplate.glassCategory | Device3DTemplate.islandCategory)
            scene.rootNode.addChildNode(node)
        }
        camera.projectionDirection = .vertical
        lens.projectionDirection = .vertical
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        renderer.isJitteringEnabled = false

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
    }
}
