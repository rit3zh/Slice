//
//  Device3DModelPicker.swift
//  Slice
//
//  Created by rit3zh CX on 10/15/26.
//

import SliceCore
import SwiftUI

struct ModelPicker: View {
    @ObservedObject var editor: EditorModel

    private var s: Device3DSettings { editor.project.device3D }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Model").font(.system(size: 13))
                Spacer()
                modelMenu
            }
            finishes
            if s.model.kind == .phone {
                PanelToggle("Dynamic Island", isOn: Binding(get: { s.dynamicIsland }, set: { editor.project.device3D.dynamicIsland = $0 }))
                if s.dynamicIsland {
                    // For lining it up over an island that's in the recording itself.
                    PanelSlider("Island size", value: Binding(get: { s.islandSize }, set: { editor.project.device3D.islandSize = $0 }),
                                in: Device3DSettings.islandSizeRange, default: 1) { "\(Int(($0 * 100).rounded()))%" }
                    PanelSlider("Island position", value: Binding(get: { s.islandOffset }, set: { editor.project.device3D.islandOffset = $0 }),
                                in: Device3DSettings.islandOffsetRange, default: 0) { v in
                        abs(v) < 0.01 ? "Default" : "\(v < 0 ? "Up" : "Down") \(Int((abs(v) * 100).rounded()))%"
                    }
                }
            }
        }
    }

    /// The canvas shows the chosen device large, so the choice itself is a name.
    private var modelMenu: some View {
        let kinds = editor.available3DKinds
        return Menu {
            ForEach(kinds, id: \.self) { kind in
                Section(kinds.count > 1 ? kind.label : "") {
                    ForEach(Device3DModel.models(kind), id: \.self) { model in
                        Toggle(model.label, isOn: Binding(get: { model == s.model }, set: { _ in
                            withAnimation(Theme.swap) { editor.select3DModel(model) }
                        }))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(s.model.label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.6)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.control))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var finishes: some View {
        HStack(spacing: 6) {
            Text("Colour").font(.system(size: 13))
            Text(s.finish.label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
            Spacer(minLength: 4)
            HStack(spacing: 2) {
                ForEach(s.model.finishes, id: \.self) { finish in
                    FinishSwatch(finish: finish, selected: s.finish == finish) {
                        withAnimation(.smooth(duration: 0.25)) { editor.project.device3D.finish = finish }
                    }
                }
            }
        }
        .animation(.smooth(duration: 0.25), value: s.finish)
    }
}

/// A small quiet button for the 3D tab's one-click actions.
struct SmallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { SmallButtonBody(configuration: configuration) }
}

private struct SmallButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(hovering ? Color.primary : Color.primary.opacity(0.8))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(configuration.isPressed ? Theme.thumb : hovering ? Theme.controlHover : Theme.control))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering = $0 && isEnabled }
            .animation(Theme.hover, value: hovering)
            .animation(Theme.press, value: configuration.isPressed)
    }
}

private struct FinishSwatch: View {
    let finish: Device3DFinish
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let c = finish.swatch
        Button(action: action) {
            Circle()
                .fill(Color(.sRGB, red: c.r, green: c.g, blue: c.b))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Theme.accent : Color.white.opacity(hovering ? 0.25 : 0), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(finish.label)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: selected)
        .animation(.smooth(duration: 0.15), value: hovering)
    }
}
