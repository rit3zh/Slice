//
//  AndroidFrameSection.swift
//  Slice
//
//  Created by rit3zh CX on 11/12/26.
//

import SliceCore
import SwiftUI

enum AndroidFrames {
    static let enabledKey = "androidFrames.enabled"
    static let modelKey = "androidFrames.model"
}

/// The Frame tab's switch for the phone drawn around Android screen recordings, and which phone.
struct AndroidFrameSection: View {
    @ObservedObject var editor: EditorModel
    @AppStorage(AndroidFrames.enabledKey) private var preferred = true
    @AppStorage(AndroidFrames.modelKey) private var chosenModel = ""
    @State private var pickedColor: DeviceColor?

    private var catalog: DeviceFrameCatalog { DeviceManager.shared.androidCatalog }
    private var latest: RecordedDevice? { editor.project.clips.last(where: \.isAndroid)?.device }
    private var isOn: Bool { latest.map { $0.frame != nil } ?? preferred }
    private var busy: Bool { editor.deviceImportProgress != nil }
    private var shownModel: String? { latest?.frame ?? (chosenModel.isEmpty ? nil : chosenModel) }

    var body: some View {
        PanelSection("Android frame", trailing: AnyView(toggle)) {
            if isOn {
                HStack {
                    Text("Phone").font(.system(size: 13))
                    Spacer()
                    modelMenu
                }
                if let model = shownModel { colors(of: model) }
            }
            PanelNote(isOn ? "Android screen recordings are shown in this phone when you import them."
                : "Android screen recordings are shown on their own, without a phone around them.")
        }
        .disabled(busy)
        .animation(Theme.swap, value: isOn)
    }

    private var toggle: some View {
        Toggle("Android frame", isOn: Binding(get: { isOn }, set: { on in
            preferred = on
            Task { await editor.reframeAndroidTakes() }
        }))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
        .tint(Theme.accent)
    }

    private var modelMenu: some View {
        Menu {
            Toggle("Automatic", isOn: Binding(get: { chosenModel.isEmpty }, set: { _ in choose("") }))
            Divider()
            ForEach(catalog.models, id: \.self) { model in
                Toggle(model, isOn: Binding(get: { chosenModel == model }, set: { _ in choose(model) }))
            }
        } label: {
            HStack(spacing: 5) {
                Text(chosenModel.isEmpty ? "Automatic" : chosenModel).lineLimit(1)
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

    private func colors(of model: String) -> some View {
        let all = catalog.colors(for: model)
        let saved = UserDefaults.standard.string(forKey: "deviceFrame.color.\(model)").map { DeviceColor($0) }
        let selected = latest?.color.map { DeviceColor($0) } ?? pickedColor ?? saved ?? all.first
        return HStack(spacing: 8) {
            ForEach(all, id: \.self) { color in
                ColorSwatch(model: model, color: color, url: catalog.frames[model]?[color], selected: color == selected) {
                    pickedColor = color
                    UserDefaults.standard.set(color.rawValue, forKey: "deviceFrame.color.\(model)")
                    Task { await editor.reframeAndroidTakes() }
                }
            }
            if let selected { Text(selected.rawValue).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer(minLength: 0)
        }
    }

    private func choose(_ model: String) {
        chosenModel = model
        pickedColor = nil
        Task { await editor.reframeAndroidTakes() }
    }
}
