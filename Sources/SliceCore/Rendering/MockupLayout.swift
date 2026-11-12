//
//  MockupLayout.swift
//  SliceCore
//
//  Created by rit3zh CX on 11/12/26.
//

import CoreGraphics

/// How much a mockup adds on each side of the recording, in the recording's units.
public struct MockupInsets: Equatable {
    public var top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0
    public static let zero = MockupInsets()
}

/// Where a mockup's parts sit around a recording placed at `content`, all in that rect's space (top-left origin).
public struct MockupLayout: Equatable {
    /// The outer shape, for the drop shadow.
    public var outline: CGRect
    public var outlineRadius: CGFloat
    /// The recording's own corners: a browser's top corners meet its toolbar square.
    public var contentTopRadius: CGFloat
    public var contentBottomRadius: CGFloat
}

/// Proportions of the Safari window, in the units of its 1203 × 753 drawing: a 1200-wide page under a 52-tall
/// toolbar with a 1-unit edge. Its toolbar is as tall for a tall recording as a wide one, so a unit is measured
/// against the recording's longer side.
enum SafariMetrics {
    static let page: CGFloat = 1200
    static let toolbar: CGFloat = 52
    static let edge: CGFloat = 1
    static let outerRadius: CGFloat = 12
    static let pageRadius: CGFloat = 11

    static func unit(for content: CGSize) -> CGFloat { max(content.width, content.height) / page }
}

extension ScreenMockup {
    public func insets(for content: CGSize) -> MockupInsets {
        switch kind {
        case .none:
            return .zero
        case .safari, .safariMinimal:
            let u = SafariMetrics.unit(for: content), e = SafariMetrics.edge * u
            return MockupInsets(top: SafariMetrics.toolbar * u, left: e, bottom: e, right: e)
        }
    }

    public func layout(content c: CGRect) -> MockupLayout {
        switch kind {
        case .none:
            return MockupLayout(outline: c, outlineRadius: 0, contentTopRadius: 0, contentBottomRadius: 0)
        case .safari, .safariMinimal:
            let u = SafariMetrics.unit(for: c.size), e = SafariMetrics.edge * u
            let outline = CGRect(x: c.minX - e, y: c.minY - SafariMetrics.toolbar * u, width: c.width + 2 * e,
                                 height: c.height + (SafariMetrics.toolbar + SafariMetrics.edge) * u)
            return MockupLayout(outline: outline, outlineRadius: SafariMetrics.outerRadius * u, contentTopRadius: 0,
                                contentBottomRadius: SafariMetrics.pageRadius * u)
        }
    }
}
