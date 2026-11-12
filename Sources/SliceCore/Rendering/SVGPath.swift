//
//  SVGPath.swift
//  SliceCore
//
//  Created by rit3zh CX on 11/12/26.
//

import CoreGraphics

/// Reads an SVG path's `d`: moves, lines, cubic curves and closes, absolute or relative. Enough for the artwork drawn
/// here, which keeps to those.
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens = Tokens(d)
        var command: Character = "M"
        var current = CGPoint.zero, start = CGPoint.zero
        while let next = tokens.next() {
            if case let .command(c) = next { command = c } else { tokens.pushBack(next) }
            let relative = command.isLowercase
            func point() -> CGPoint? {
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch command.uppercased() {
            case "M":
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                start = p
                // Pairs after a move are lines.
                command = relative ? "l" : "L"
            case "L":
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
            case "H":
                guard let x = tokens.number() else { return path }
                current.x = relative ? current.x + x : x
                path.addLine(to: current)
            case "V":
                guard let y = tokens.number() else { return path }
                current.y = relative ? current.y + y : y
                path.addLine(to: current)
            case "C":
                let origin = current
                guard let c1 = point() else { return path }
                current = origin
                guard let c2 = point() else { return path }
                current = origin
                guard let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
            case "Z":
                path.closeSubpath()
                current = start
            default:
                return path
            }
        }
        return path
    }

    private enum Token { case command(Character), number(CGFloat) }

    private struct Tokens {
        let chars: [Character]
        var i = 0
        var pending: Token?

        init(_ s: String) { chars = Array(s) }

        mutating func pushBack(_ t: Token) { pending = t }

        mutating func number() -> CGFloat? {
            guard let t = next() else { return nil }
            if case let .number(v) = t { return v }
            pushBack(t)
            return nil
        }

        mutating func next() -> Token? {
            if let p = pending {
                pending = nil
                return p
            }
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c.isLetter, c != "e", c != "E" {
                i += 1
                return .command(c)
            }
            var text = ""
            var seenDot = false
            if c == "-" || c == "+" {
                text.append(c)
                i += 1
            }
            while i < chars.count {
                let ch = chars[i]
                if ch.isNumber {
                    text.append(ch)
                } else if ch == ".", !seenDot {
                    seenDot = true
                    text.append(ch)
                } else if ch == "e" || ch == "E" {
                    text.append(ch)
                    if i + 1 < chars.count, chars[i + 1] == "-" || chars[i + 1] == "+" {
                        i += 1
                        text.append(chars[i])
                    }
                } else {
                    break
                }
                i += 1
            }
            return Double(text).map { .number(CGFloat($0)) }
        }
    }
}
