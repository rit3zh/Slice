//
//  Keystrokes.swift
//  SliceCore
//
//  Created by rit3zh CX on 10/2/26.
//

import Foundation

public struct KeystrokeSettings: Codable, Equatable {
    public enum Position: String, Codable, CaseIterable { case bottom, top }

    /// Which presses are shown. Raw values are saved in projects, so never rename them.
    public enum Show: String, Codable, CaseIterable {
        /// Presses with ⌘, ⌃ or ⌥.
        case shortcuts
        /// Those and keys like esc, return and the arrows on their own.
        case keys
        /// Those and what's typed, as a line of text; only in takes recorded with typed text.
        case typing
    }

    /// How a press is drawn. Raw values are saved in projects, so never rename them.
    public enum Style: String, Codable, CaseIterable {
        case dark, light, keycaps, minimal
    }

    public enum Alignment: String, Codable, CaseIterable { case leading, center, trailing }

    /// One press at a time, each replacing the last, or a stack of them, newest nearest the edge, as KeyCastr shows
    /// them. Raw values are saved in projects, so never rename them.
    public enum Layout: String, Codable, CaseIterable { case single, stack }

    public var visible = true
    public var show: Show = .shortcuts
    public var style: Style = .dark
    public var position: Position = .bottom
    public var alignment: Alignment = .center
    public var layout: Layout = .single
    /// Typed words shown as dots instead, compared without case or punctuation.
    public var hiddenWords: [String] = []
    public var size = 0.04
    public var hold = 1.4
    public var sound: KeyboardSound = .none
    public var soundVolume = 0.5

    public init() {}

    /// Single keys shown along with shortcuts, as the setting was before typing could be shown.
    public var singleKeys: Bool {
        get { show != .shortcuts }
        set { show = newValue ? max(show, .keys) : .shortcuts }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = KeystrokeSettings()
        visible = try c.decodeIfPresent(Bool.self, forKey: .visible) ?? d.visible
        if let show = try? c.decodeIfPresent(Show.self, forKey: .show) {
            self.show = show
        } else {
            show = try c.decodeIfPresent(Bool.self, forKey: .singleKeys) == true ? .keys : d.show
        }
        style = (try? c.decodeIfPresent(Style.self, forKey: .style)) ?? d.style
        position = (try? c.decodeIfPresent(Position.self, forKey: .position)) ?? d.position
        alignment = (try? c.decodeIfPresent(Alignment.self, forKey: .alignment)) ?? d.alignment
        layout = (try? c.decodeIfPresent(Layout.self, forKey: .layout)) ?? d.layout
        hiddenWords = try c.decodeIfPresent([String].self, forKey: .hiddenWords) ?? d.hiddenWords
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? d.size
        hold = try c.decodeIfPresent(Double.self, forKey: .hold) ?? d.hold
        sound = (try? c.decodeIfPresent(KeyboardSound.self, forKey: .sound)) ?? d.sound
        soundVolume = try c.decodeIfPresent(Double.self, forKey: .soundVolume) ?? d.soundVolume
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(visible, forKey: .visible)
        try c.encode(show, forKey: .show)
        // Kept for older versions, which read only this.
        try c.encode(singleKeys, forKey: .singleKeys)
        try c.encode(style, forKey: .style)
        try c.encode(position, forKey: .position)
        try c.encode(alignment, forKey: .alignment)
        try c.encode(layout, forKey: .layout)
        try c.encode(hiddenWords, forKey: .hiddenWords)
        try c.encode(size, forKey: .size)
        try c.encode(hold, forKey: .hold)
        try c.encode(sound, forKey: .sound)
        try c.encode(soundVolume, forKey: .soundVolume)
    }

    private enum CodingKeys: String, CodingKey {
        case visible, show, singleKeys, style, position, alignment, layout, hiddenWords, size, hold, sound, soundVolume
    }
}

extension KeystrokeSettings.Show: Comparable {
    public static func < (a: Self, b: Self) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

public struct KeyHit: Codable, Equatable {
    /// Raw values are saved in takes and name the pack's own recordings, so never rename them.
    public enum Kind: String, Codable { case key, space, enter, backspace, modifier }

    public var t: Double
    public var kind: Kind

    public init(t: Double, kind: Kind) {
        self.t = t
        self.kind = kind
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t)
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .key
    }

    public static func kind(keyCode: UInt16) -> Kind {
        switch keyCode {
        case 49: .space
        case 36, 76: .enter
        case 51, 117: .backspace
        case 54 ... 63: .modifier
        default: .key
        }
    }

    static func kind(named key: String) -> Kind {
        switch key {
        case "Space": .space
        case "↩", "⌅": .enter
        case "⌫", "⌦": .backspace
        default: .key
        }
    }
}

/// The keyboard heard as keys are pressed. Raw values are saved in projects, so never rename them.
public enum KeyboardSound: String, Codable, CaseIterable {
    case none
    case cherryBlue
    case apexPro
    case holyPanda

    public var label: String {
        switch self {
        case .none: "None"
        case .cherryBlue: "Cherry MX Blue"
        case .apexPro: "Apex Pro"
        case .holyPanda: "Holy Panda"
        }
    }

    public var detail: String {
        switch self {
        case .none: "Silent typing"
        case .cherryBlue: "Clicky"
        case .apexPro: "Smooth"
        case .holyPanda: "Deep"
        }
    }

    private var folder: String? {
        switch self {
        case .none: nil
        case .cherryBlue: "cherry-mx-blue"
        case .apexPro: "apex-pro"
        case .holyPanda: "holy-panda"
        }
    }

    public var files: [URL] {
        guard let folder else { return [] }
        return (Bundle.module.urls(forResourcesWithExtension: "wav", subdirectory: "Sounds/Keyboards/\(folder)") ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func picks(for kinds: [KeyHit.Kind]) -> [Int] {
        let names = files.map { $0.deletingPathExtension().lastPathComponent }
        let keys = names.indices.filter { names[$0].hasPrefix("key") }
        guard !keys.isEmpty else { return [] }
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        var last = 0
        return kinds.map { kind in
            if kind != .key, kind != .modifier, let own = names.firstIndex(of: kind.rawValue) { return own }
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            last = (last + 1 + Int((seed >> 33) % UInt64(max(keys.count - 1, 1)))) % keys.count
            return keys[last]
        }
    }
}

public struct KeyPress: Codable, Equatable {
    public var t: Double
    public var modifiers: String
    public var key: String

    public init(t: Double, modifiers: String, key: String) {
        self.t = t
        self.modifiers = modifiers
        self.key = key
    }

    public var isShortcut: Bool { modifiers.contains { "⌘⌃⌥".contains($0) } }

    /// A character typed as text, rather than a shortcut or a named key: only in takes recorded with typed text.
    public var isTyped: Bool { !isShortcut && !Self.names.contains(key) }

    public var label: String { modifiers.isEmpty ? key : "\(modifiers) \(key)" }

    /// `text`, what the press typed, is given only when typed text is being recorded; without it plain typing is
    /// never kept.
    public static func make(t: Double, keyCode: UInt16, characters: String?, text: String? = nil,
                            control: Bool, option: Bool, shift: Bool, command: Bool) -> KeyPress? {
        let modifiers = (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
        let shortcut = control || option || command
        if let named = namedKeys[keyCode] {
            if keyCode == 49, !shortcut, text == nil { return nil }
            return KeyPress(t: t, modifiers: keyCode == 49 && !shortcut ? "" : modifiers, key: named)
        }
        if !shortcut {
            // The character as typed, shift and all, so "A" and "?" come out as they did on screen.
            guard let text, !text.isEmpty, text.count <= 4, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            return KeyPress(t: t, modifiers: "", key: text)
        }
        guard let c = characters?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !c.isEmpty,
              c.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return KeyPress(t: t, modifiers: modifiers, key: c)
    }

    static let names = Set(namedKeys.values)

    static let namedKeys: [UInt16: String] = [
        36: "↩", 76: "⌅", 48: "⇥", 49: "Space", 51: "⌫", 117: "⌦", 53: "esc",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        90: "F20",
    ]
}
