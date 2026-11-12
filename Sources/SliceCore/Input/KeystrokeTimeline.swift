//
//  KeystrokeTimeline.swift
//  SliceCore
//
//  Created by rit3zh CX on 11/12/26.
//

import Foundation

public struct KeystrokeState: Equatable {
    public var label: String
    public var count: Int
    public var opacity: Double
    public var blur: Double
    public var scale: Double
    public var drop: Double
    /// A typed line rather than a shortcut or key.
    public var isText = false
    /// How far up a stacked press has been pushed by newer ones, in presses.
    public var slot = 0.0
    /// The typed line's newest characters as they come in, by their place in `label`: 0 just typed, 1 settled.
    public var reveal: [Int: Double] = [:]
}

public struct KeystrokeTimeline {
    struct Group {
        var label: String
        var presses: [Double]
        var inStart: Double
        var outStart = 0.0
        var outDuration = 0.0
        /// A typed line: the text as it stood after each press.
        var lines: [String]?
        /// The same with hidden words as dots, letter for letter.
        var shown: [String]?
    }

    private(set) var groups: [Group] = []
    private var stacked = false

    static let inDuration = 0.32
    static let outDuration = 0.28
    static let swapOut = 0.12
    static let swapDelay = 0.05
    static let pulse = 0.2
    /// Characters of a typed line kept; far more than fit, so the renderer's scroll and fade decide what's seen and
    /// dropping the oldest never shows.
    static let lineLength = 80
    /// How long a typed character takes to come into focus.
    static let typeIn = 0.22
    /// How long a backspaced one takes to go.
    static let typeOut = 0.18
    /// The most presses stacked at once.
    static let stackLimit = 5

    public init(presses: [KeyPress], settings: KeystrokeSettings) {
        guard settings.visible else { return }
        stacked = settings.layout == .stack
        let hold = max(settings.hold, 0.2)
        let typing = settings.show == .typing
        for p in presses.sorted(by: { $0.t < $1.t }) where Self.shows(p, settings.show) {
            let edits = p.modifiers.isEmpty && (p.isTyped || p.key == "Space" || p.key == "⌫")
            // Typing carries on the line still up, space and backspace included.
            if typing, edits, let last = groups.last, var lines = last.lines, let prev = last.presses.last, p.t - prev <= hold {
                var line = lines.last ?? ""
                switch p.key {
                case "Space": line += " "
                case "⌫": if !line.isEmpty { line.removeLast() }
                default: line += p.key
                }
                lines.append(line)
                groups[groups.count - 1].presses.append(p.t)
                groups[groups.count - 1].lines = lines
                continue
            }
            if typing, p.isTyped {
                groups.append(Group(label: p.key, presses: [p.t], inStart: p.t, lines: [p.key]))
                continue
            }
            let label = p.label
            if let last = groups.last, last.lines == nil, last.label == label, let prev = last.presses.last, p.t - prev <= hold {
                groups[groups.count - 1].presses.append(p.t)
            } else {
                groups.append(Group(label: label, presses: [p.t], inStart: p.t))
            }
        }
        let hidden = Set(settings.hiddenWords.map(Self.normalized).filter { !$0.isEmpty })
        for i in groups.indices {
            if let lines = groups[i].lines {
                groups[i].shown = hidden.isEmpty ? lines : lines.map { Self.masking($0, finally: lines.last ?? $0, hidden: hidden) }
            }
            let natural = groups[i].presses.last! + hold
            // Stacked, each stays its own time: a newer one pushes it up rather than replacing it.
            guard !stacked, i + 1 < groups.count else {
                groups[i].outStart = natural
                groups[i].outDuration = Self.outDuration
                continue
            }
            let next = groups[i + 1].presses[0]
            if next < natural + Self.outDuration {
                let end = min(natural + Self.outDuration, next + Self.swapOut)
                groups[i].outStart = min(natural, next)
                groups[i].outDuration = max(end - groups[i].outStart, 0.01)
                groups[i + 1].inStart = next + Self.swapDelay
            } else {
                groups[i].outStart = natural
                groups[i].outDuration = Self.outDuration
            }
        }
    }

    /// A word as hidden words are matched: no case, no punctuation around it.
    public static func normalized(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces))
    }

    /// `line` with hidden words as dots. A word still being typed is judged by what it became, so a hidden word is
    /// dots from its first letter.
    static func masking(_ line: String, finally final: String, hidden: Set<String>) -> String {
        let words = line.split(separator: " ", omittingEmptySubsequences: false)
        let finals = final.split(separator: " ", omittingEmptySubsequences: false)
        return words.enumerated().map { n, word in
            let typing = n == words.count - 1 && n < finals.count && finals[n].hasPrefix(word)
            let whole = String(typing ? finals[n] : word)
            return !word.isEmpty && hidden.contains(normalized(whole)) ? String(repeating: "•", count: word.count) : String(word)
        }.joined(separator: " ")
    }

    /// Every word typed in `presses`, as hidden words are matched, in the order first typed.
    public static func typedWords(in presses: [KeyPress], hold: Double) -> [String] {
        var settings = KeystrokeSettings()
        settings.show = .typing
        settings.hold = hold
        var seen = Set<String>()
        return KeystrokeTimeline(presses: presses, settings: settings).groups.flatMap { g in
            (g.lines?.last ?? "").split(separator: " ").map { normalized(String($0)) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
    }

    static func shows(_ p: KeyPress, _ show: KeystrokeSettings.Show) -> Bool {
        switch show {
        case .shortcuts: p.isShortcut
        // A plain space is part of typing, never a key of its own here.
        case .keys: !p.isTyped && !(p.key == "Space" && p.modifiers.isEmpty)
        case .typing: true
        }
    }

    public var isEmpty: Bool { groups.isEmpty }

    /// Oldest first, so the newest is drawn on top.
    public func states(at t: Double) -> [KeystrokeState] {
        guard let i = groups.lastIndex(where: { $0.presses[0] <= t }) else { return [] }
        guard stacked else { return [i - 2, i - 1, i].compactMap { $0 >= 0 ? state(groups[$0], at: t) : nil } }
        var shown: [KeystrokeState] = []
        var slot = 0.0
        for g in groups[...i].reversed() {
            guard shown.count < Self.stackLimit else { break }
            guard var s = state(g, at: t) else {
                // Stacked presses leave in the order they came, so once one has gone, so have all before it.
                if t >= g.outStart + g.outDuration { break }
                continue
            }
            s.slot = slot
            // A press coming in pushes the rest up as it arrives.
            slot += 1 - pow(1 - min(max((t - g.inStart) / Self.inDuration, 0), 1), 3)
            shown.append(s)
        }
        return shown.reversed()
    }

    private func state(_ g: Group, at t: Double) -> KeystrokeState? {
        guard t >= g.inStart, t < g.outStart + g.outDuration else { return nil }
        let a = min((t - g.inStart) / Self.inDuration, 1)
        let o = min(max((t - g.outStart) / g.outDuration, 0), 1)
        let settle = 1 - pow(1 - a, 3)
        let shown = 1 - pow(1 - min(a / 0.6, 1), 2)
        let blurOut = 1 - pow(1 - o, 2)
        var blur = max(1 - settle, blurOut)
        var scale = (0.92 + 0.08 * settle) * (1 - 0.06 * o * o)
        var count = 1
        var label = g.label
        var reveal: [Int: Double] = [:]
        if let lines = g.lines {
            // A line grows in place: no pulse for each letter, which would shake it. Its newest letters come into
            // focus instead, and backspaced ones go out of it.
            let k = (g.presses.lastIndex { $0 <= t }) ?? 0
            let shownLines = g.shown ?? lines
            // Letters backspaced away fade out rather than vanish. They're the latest run of presses that each took
            // one off the end, still within their fade; letters typed since go before them, so the line's width only
            // ever eases, however fast it's corrected.
            var j = k
            while j > 0, t - g.presses[j] < Self.typeOut, lines[j].count == lines[j - 1].count + 1, lines[j].hasPrefix(lines[j - 1]) {
                j -= 1
            }
            var d = j
            var fading: [(index: Int, p: Double)] = []
            while d > 0, t - g.presses[d] < Self.typeOut, lines[d].count + 1 == lines[d - 1].count, lines[d - 1].hasPrefix(lines[d]) {
                fading.append((lines[d].count - lines[j].count, 1 - (t - g.presses[d]) / Self.typeOut))
                d -= 1
            }
            let ghosts = String(shownLines[d].dropFirst(shownLines[j].count))
            let typedNow = shownLines[k]
            let line = typedNow + (lines[k].hasPrefix(lines[j]) ? ghosts : "")
            guard !line.isEmpty else { return nil }
            let cut = max(line.count - Self.lineLength, 0)
            label = String(line.suffix(Self.lineLength))
            var leaving: [Int: Double] = [:]
            if line.count > typedNow.count {
                for (i, p) in fading { leaving[typedNow.count + i] = p }
            }
            for j in stride(from: k, through: max(k - 12, 0), by: -1) {
                let age = t - g.presses[j]
                guard age < Self.typeIn else { break }
                let now = lines[j], before = j > 0 ? lines[j - 1] : ""
                guard now.count == before.count + 1, now.hasPrefix(before), lines[k].hasPrefix(now) else { continue }
                let index = now.count - 1 - cut
                if index >= 0 { reveal[index] = min(reveal[index] ?? 1, age / Self.typeIn) }
            }
            for (i, p) in leaving where i - cut >= 0 { reveal[i - cut] = min(reveal[i - cut] ?? 1, p) }
        } else {
            for (k, p) in g.presses.enumerated().dropFirst() where t >= p {
                let b = (t - p) / Self.pulse
                if b >= 0.5 { count = k + 1 }
                if b < 1 {
                    let bump = sin(.pi * b)
                    blur = max(blur, 0.4 * bump)
                    scale *= 1 - 0.05 * bump
                }
            }
        }
        return KeystrokeState(label: label, count: count, opacity: shown * (1 - o * o * (3 - 2 * o)), blur: blur,
                              scale: scale, drop: 0.18 * (1 - settle), isText: g.lines != nil, reveal: reveal)
    }
}
