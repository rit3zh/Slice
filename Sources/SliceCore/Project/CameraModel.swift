//
//  CameraModel.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/15/26.
//

import Foundation

public enum Corner: String, Codable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

public enum CameraShape: String, Codable, CaseIterable {
    case landscape, portrait, square
}

public enum CameraSize: String, Codable, CaseIterable {
    case small, large
}

public enum CameraLayout: Codable, Equatable, Hashable {
    case hidden
    case corner(Corner, CameraShape, CameraSize)
    case centre(coverage: Double)
    case fullscreen
    /// `share` is the camera's part of the frame's width (height in a tall video); nil sizes the two to fit the screen.
    case split(SplitSide, share: Double? = nil)
}

public enum SplitSide: String, Codable, CaseIterable {
    case left, right
}

public struct CameraBlock: Codable, Equatable, Identifiable {
    public var id: UUID
    public var start: Double
    public var end: Double
    public var layout: CameraLayout

    public init(id: UUID = UUID(), start: Double, end: Double, layout: CameraLayout) {
        self.id = id
        self.start = start
        self.end = end
        self.layout = layout
    }
}
