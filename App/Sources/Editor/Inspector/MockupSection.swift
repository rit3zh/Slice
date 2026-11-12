//
//  MockupSection.swift
//  Slice
//
//  Created by rit3zh CX on 11/12/26.
//

import SliceCore
import SwiftUI

/// The Frame tab's browser window around the screen recording, and how it looks.
struct MockupSection: View {
    @ObservedObject var editor: EditorModel

    private var mockup: ScreenMockup { editor.project.style.mockup }

    var body: some View {
        PanelSection("Mockup") {
            SegmentedControl(selection: $editor.project.style.mockup.kind, options: MockupKind.allCases, title: Self.label)
            if mockup.isBrowser {
                PanelToggle("Dark toolbar", isOn: $editor.project.style.mockup.dark)
                    .transition(.opacity)
                AddressField(text: $editor.project.style.mockup.url)
                    .transition(.opacity)
            }
            if let note {
                PanelNote(note).transition(.opacity)
            }
        }
        .animation(Theme.swap, value: mockup.kind)
    }

    /// Only said when the mockup won't show.
    private var note: String? {
        guard mockup.kind != .none else { return nil }
        let clips = editor.project.clips
        if !clips.isEmpty, !clips.contains(where: { $0.device == nil }) {
            return "Mockups go around screen recordings. Phone takes keep their own frame."
        }
        if editor.project.shows3D { return "Hidden while the 3D device is on." }
        return nil
    }

    static func label(_ kind: MockupKind) -> String {
        switch kind {
        case .none: "None"
        case .safari: "Safari"
        case .safariMinimal: "Minimal"
        }
    }
}

private struct AddressField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            TextField("Address", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1))
        .animation(Theme.hover, value: focused)
        .help("Shown in the address bar. Leave it empty for a blank bar.")
    }
}
