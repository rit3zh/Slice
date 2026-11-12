//
//  MockupModel.swift
//  SliceCore
//
//  Created by rit3zh CX on 11/12/26.
//

import CoreGraphics
import CoreImage
import Foundation

/// A browser window drawn around a screen recording, sized to the recording whatever its shape.
public enum MockupKind: String, Codable, CaseIterable {
    case none, safari, safariMinimal
}

public struct ScreenMockup: Codable, Equatable, Hashable {
    public var kind: MockupKind = .none
    /// Dark browser chrome.
    public var dark = false
    /// Shown in the browser's address bar.
    public var url = ""

    public init(kind: MockupKind = .none, dark: Bool = false, url: String = "") {
        self.kind = kind
        self.dark = dark
        self.url = url
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(MockupKind.self, forKey: .kind)) ?? .none
        dark = try c.decodeIfPresent(Bool.self, forKey: .dark) ?? false
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
    }

    public var isBrowser: Bool { kind == .safari || kind == .safariMinimal }
}

/// A look for the webcam, applied as it's drawn: the recording itself is left as it was filmed.
public enum CameraFilter: String, Codable, CaseIterable {
    case none, mono, noir, sepia, warm, cool, vivid, fade

    public var label: String {
        switch self {
        case .none: "None"
        case .mono: "Mono"
        case .noir: "Noir"
        case .sepia: "Sepia"
        case .warm: "Warm"
        case .cool: "Cool"
        case .vivid: "Vivid"
        case .fade: "Fade"
        }
    }

    public func apply(to image: CIImage) -> CIImage {
        let extent = image.extent
        let out: CIImage
        switch self {
        case .none: return image
        case .mono: out = image.applyingFilter("CIPhotoEffectMono")
        case .noir: out = image.applyingFilter("CIPhotoEffectNoir")
        case .fade: out = image.applyingFilter("CIPhotoEffectFade")
        case .sepia: out = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.85])
        case .warm, .cool:
            // The neutral is the colour temperature the picture is taken to be lit by: claiming bluer light than it
            // was warms it, and the other way cools it.
            out = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: self == .warm ? 4900 : 8600, y: 0),
            ])
        case .vivid:
            out = image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.7])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.08, kCIInputContrastKey: 1.06])
        }
        return extent.isInfinite ? out : out.cropped(to: extent)
    }
}
