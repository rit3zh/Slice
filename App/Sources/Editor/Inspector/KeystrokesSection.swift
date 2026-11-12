//
//  KeystrokesSection.swift
//  Slice
//
//  Created by rit3zh CX on 10/11/26.
//

import AVFoundation
import SliceCore
import SwiftUI

struct KeystrokesSection: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        let keys = editor.project.keystrokes
        let d = KeystrokeSettings()
        let subs = editor.project.subtitles
        PanelSection("Keystrokes", trailing: AnyView(visibleToggle)) {
            KeystrokePreview(settings: $editor.project.keystrokes,
                             captions: subs.burnIn && !editor.captions.isEmpty && subs.position.rawValue == keys.position.rawValue)
            if keys.visible {
                SegmentedControl(selection: $editor.project.keystrokes.show, options: KeystrokeSettings.Show.allCases,
                                 title: Self.title)
                SegmentedControl(selection: $editor.project.keystrokes.layout, options: KeystrokeSettings.Layout.allCases,
                                 title: { $0 == .single ? "One at a time" : "Stacked" },
                                 symbol: { $0 == .single ? "rectangle" : "rectangle.stack" })
                    .help("Stacked keeps each press up for its own time, newer ones pushing older ones up, as KeyCastr does")
                if let note { PanelNote(note).transition(.opacity) }
                SegmentedControl(selection: $editor.project.keystrokes.style, options: KeystrokeSettings.Style.allCases,
                                 title: { $0.rawValue.capitalized })
                PanelSlider("Size", value: $editor.project.keystrokes.size, in: 0.02 ... 0.08, default: d.size) {
                    String(format: "%.1f×", $0 / d.size)
                }
                PanelSlider("Duration", value: $editor.project.keystrokes.hold, in: 0.5 ... 4, default: d.hold) {
                    String(format: "%.1fs", $0)
                }
                .help("How long a press stays up. Pressing it again keeps it up and counts it.")
            } else if !editor.hasKeystrokes {
                PanelNote(Self.notRecorded)
            }
        }
        .animation(Theme.swap, value: keys.visible)
        .animation(Theme.swap, value: note)
        if keys.visible, keys.show == .typing, editor.hasTypedKeys {
            PanelDivider()
            HiddenWordsSection(words: editor.typedWords, hidden: $editor.project.keystrokes.hiddenWords)
        }
        PanelDivider()
        PanelSection("Typing sound") {
            SoundPicker(selection: $editor.project.keystrokes.sound, options: KeyboardSound.allCases,
                        label: \.label, detail: \.detail) { sound in
                KeyboardSoundPreview.play(sound, volume: editor.project.keystrokes.soundVolume)
            }
            if keys.sound != .none {
                SoundVolumeRow(value: $editor.project.keystrokes.soundVolume, default: d.soundVolume, icon: "keyboard")
                    .transition(.opacity.combined(with: .move(edge: .top)))
                Button {
                    KeyboardSoundPreview.play(keys.sound, volume: keys.soundVolume)
                } label: {
                    Label("Play typing preview", systemImage: "speaker.wave.2")
                }
                .buttonStyle(PillButtonStyle(fullWidth: true))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !editor.hasKeyHits {
                PanelNote(Self.notRecorded)
            }
        }
        .animation(Theme.swap, value: keys.sound == .none)
    }

    private var visibleToggle: some View {
        Toggle("Show keystrokes", isOn: $editor.project.keystrokes.visible.animation(.snappy))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.accent)
    }

    /// Only said when what's chosen has nothing to show.
    private var note: String? {
        let show = editor.project.keystrokes.show
        if !editor.hasKeystrokes { return Self.notRecorded }
        if show == .typing, !editor.hasTypedKeys {
            return "These takes were recorded without typed text. Turn on Include typed text under Record keyboard to show it."
        }
        return nil
    }

    private static let notRecorded = "Nothing was recorded from the keyboard in these takes. Turn on Record keyboard in the capture bar's options."

    static func title(_ show: KeystrokeSettings.Show) -> String {
        switch show {
        case .shortcuts: "Shortcuts"
        case .keys: "Keys"
        case .typing: "Everything"
        }
    }
}

/// The words typed in the takes; clicking one hides it, as dots, wherever it was typed.
private struct HiddenWordsSection: View {
    let words: [String]
    @Binding var hidden: [String]

    private var hiddenSet: Set<String> { Set(hidden.map(KeystrokeTimeline.normalized)) }

    var body: some View {
        PanelSection("Hide words", trailing: hidden.isEmpty ? nil : AnyView(
            Button("Show all") { withAnimation(.snappy) { hidden = [] } }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
        )) {
            ScrollView {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(words, id: \.self) { word in
                        WordChip(word: word, hidden: hiddenSet.contains(word)) { toggle(word) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .scrollIndicators(.never)
            PanelNote("Click a word to hide it. It shows as dots in the video, from its first letter.")
        }
    }

    private func toggle(_ word: String) {
        withAnimation(.snappy) {
            if hiddenSet.contains(word) {
                hidden.removeAll { KeystrokeTimeline.normalized($0) == word }
            } else {
                hidden.append(word)
            }
        }
    }
}

private struct WordChip: View {
    let word: String
    let hidden: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if hidden { Image(systemName: "eye.slash").font(.system(size: 9, weight: .semibold)) }
                Text(word).strikethrough(hidden, color: .secondary)
            }
            .font(.system(size: 12))
            .foregroundStyle(hidden ? Color.secondary : Color.primary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(hidden ? Theme.accent.opacity(0.14) : (hovering ? Theme.controlHover : Theme.control)))
            .overlay(Capsule().strokeBorder(hidden ? Theme.accent.opacity(0.45) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.hover, value: hovering)
        .help(hidden ? "Show “\(word)”" : "Hide “\(word)”")
    }
}

@MainActor
enum KeyboardSoundPreview {
    private static var players: [AVAudioPlayer] = []

    private static let phrase: [(gap: Double, kind: KeyHit.Kind)] = [
        (0, .modifier), (0.07, .key), (0.12, .key), (0.1, .key), (0.11, .key), (0.13, .key), (0.15, .space),
        (0.13, .key), (0.1, .key), (0.11, .key), (0.1, .key), (0.12, .key), (0.24, .enter),
    ]

    static func play(_ sound: KeyboardSound, volume: Double) {
        players.forEach { $0.stop() }
        players = []
        let files = sound.files
        let picks = sound.picks(for: phrase.map(\.kind))
        guard !picks.isEmpty else { return }
        var times: [Double] = []
        var at = 0.05
        for (step, pick) in zip(phrase, picks) {
            at += step.gap
            guard let player = try? AVAudioPlayer(contentsOf: files[pick]) else { continue }
            player.volume = Float(min(max(volume, 0), 1))
            player.prepareToPlay()
            players.append(player)
            times.append(at)
        }
        guard let now = players.first?.deviceCurrentTime else { return }
        for (player, t) in zip(players, times) { player.play(atTime: now + t) }
    }
}
