//
//  CaptureBar+Options.swift
//  Slice
//
//  Created by rit3zh CX on 10/1/26.
//

import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

/// An app whose sound can be recorded on its own.
struct AudioApp: Identifiable, Hashable {
    let id: String
    let name: String
}

extension CaptureBar {
    var micName: String? { mics.first { $0.uniqueID == micID }?.localizedName }
    var cameraName: String? { cameras.first { $0.uniqueID == cameraID }?.localizedName }

    var micPill: some View {
        BarPill(id: "mic", width: 200, open: picker == .mic, action: { picker = .mic }) {
            Image(systemName: micName == nil ? "mic.slash" : "mic.fill")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 22)
            PillLabel(caption: "Microphone", value: micName ?? "Off")
            if micName != nil {
                LevelBars(level: micPreview.level).transition(.scale.combined(with: .opacity))
            }
        }
        .help("Microphone")
        .popover(isPresented: shown(.mic), arrowEdge: .top) {
            PickerList(title: "Microphone") {
                PickerRow(title: "No microphone", selected: micID.isEmpty, symbol: "mic.slash") { micID = ""; micChosen = true; picker = nil }
                ForEach(mics, id: \.uniqueID) { m in
                    PickerRow(title: m.localizedName, selected: micID == m.uniqueID, symbol: "mic") { micID = m.uniqueID; micChosen = true; picker = nil }
                }
            }
        }
    }

    var cameraPill: some View {
        BarPill(id: "camera", width: 200, open: picker == .camera, action: { picker = .camera }) {
            ZStack {
                if cameraName != nil, let session = cameraPreview.session {
                    CameraPreview(session: session)
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                } else {
                    Image(systemName: cameraName == nil ? "video.slash" : "video.fill")
                        .font(.system(size: 14, weight: .medium))
                        .transition(.opacity)
                }
            }
            .frame(width: 24, height: 24)
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: cameraPreview.session != nil)
            PillLabel(caption: "Camera", value: cameraName ?? "Off")
        }
        .help("Camera")
        .popover(isPresented: shown(.camera), arrowEdge: .top) {
            PickerList(title: "Camera") {
                PickerRow(title: "No camera", selected: cameraID.isEmpty, symbol: "video.slash") { cameraID = ""; cameraChosen = true; picker = nil }
                ForEach(cameras, id: \.uniqueID) { c in
                    PickerRow(title: c.localizedName, selected: cameraID == c.uniqueID, symbol: "video") { cameraID = c.uniqueID; cameraChosen = true; picker = nil }
                }
            }
        }
    }

    var optionsButton: some View {
        BarPill(id: "options", open: picker == .options, action: { picker = .options }) {
            Text("Options").lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
        }
        .overlay(alignment: .topTrailing) {
            if keys && !keysAllowed && kind != .device {
                Circle().fill(.orange).frame(width: 7, height: 7).offset(x: -4, y: 6)
            }
        }
        .popover(isPresented: shown(.options), arrowEdge: .top) { options }
    }

    var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                SectionTitle("Frame rate")
                SwiftUI.Picker("Frame rate", selection: $fps) {
                    Text(bestRateLabel).tag(Recorder.Settings.best)
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Best records at 120 fps on ProMotion displays when the encoder can keep up at that size, otherwise 60.")
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Camera")
                OptionToggle("Show camera bubble", isOn: $showCamera)
                    .disabled(cameraName == nil)
                    .help(cameraName == nil ? "Pick a camera first"
                        : "Shows you on screen as you set up and while you record. Drag it anywhere and double-click to resize. It's left out of the recording.")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle("Audio & keys")
                OptionToggle(kind != .device ? "Record sound from apps" : "Record the iPhone's sound", isOn: $screenAudio)
                if screenAudio, kind != .device {
                    audioAppPicker
                }
                if kind != .device {
                    OptionToggle("Record keyboard", isOn: $keys.animation(.snappy))
                        .help("For showing the shortcuts you press over the video, and for typing sounds. Shortcuts (⌘, ⌃ or ⌥ with a key) and keys like esc and the arrows are recorded; for typing, only when a key went down, never which one.")
                    if keys {
                        OptionToggle("Include typed text", isOn: $typing, nested: true)
                            .transition(.opacity)
                            .help("Also records the letters you type, so the video can show them as you type. Password fields are never recorded.")
                    }
                    if keys && !keysAllowed {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text("Needs Accessibility access").foregroundStyle(.secondary)
                            Spacer()
                            Button("Allow…") {
                                let prompt = "AXTrustedCheckOptionPrompt" as CFString
                                keysAllowed = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
                            }
                            .controlSize(.small)
                        }
                        .font(.system(size: 11))
                    }
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Divider()
            PickerRow(title: "Open Projects", selected: false, symbol: "square.grid.2x2") {
                picker = nil
                model.openProjectsFromBar()
            }
            .padding(.horizontal, -8)
        }
        .font(.system(size: 12.5))
        .padding(14)
        .frame(width: 290)
        .environment(\.barGlide, BarGlide(tracker: optionsGlide, namespace: optionsSpace))
        .barPopoverAppearance()
        .task { await loadAudioApps() }
        .onChange(of: audioApp) { syncAudioAppName() }
    }

    /// Which app's sound is recorded: the whole system mix, or one app on its own. Picking one app keeps every other
    /// sound out of the file — including the delayed copy a monitoring or room-correction audio device adds back.
    var audioAppPicker: some View {
        let picked = !audioApp.isEmpty
        return HStack(spacing: 8) {
            Image(systemName: "speaker.wave.2")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text("Sound from").foregroundStyle(.secondary)
            Spacer(minLength: 6)
            // A menu, not a Picker(.menu): a picker measures itself by its widest item, which made the popover
            // wider than its 290 points and pushed the options out of view on the left.
            Menu {
                audioAppMenuItem("All apps", selected: !picked) { audioApp = "" }
                if !audioApps.isEmpty { Divider() }
                ForEach(audioApps) { app in
                    audioAppMenuItem(app.name, selected: audioApp == app.id) { audioApp = app.id }
                }
            } label: {
                HStack(spacing: 5) {
                    if picked {
                        Circle().fill(Color.green).frame(width: 7, height: 7)
                    }
                    Text(picked ? (audioAppName.isEmpty ? audioApp : audioAppName) : "All apps")
                        .fontWeight(picked ? .semibold : .regular)
                        .foregroundStyle(picked ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.5)
                }
                .frame(width: 116, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .help(picked
            ? "Only \(audioAppName.isEmpty ? "the chosen app" : audioAppName) is recorded. Set it back to All apps to record the system mix."
            : "Records one app's sound instead of the system mix. Audio devices that add a delayed copy to the output — ListenHub and the like — stay out of the recording.")
    }

    private func audioAppMenuItem(_ title: String, selected: Bool, choose: @escaping () -> Void) -> some View {
        // Only the picked row carries the checkmark. A hidden one (`opacity(0)`) doesn't work: menus draw the
        // item's image whatever its opacity, so every row came out ticked.
        Button(action: choose) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    func loadAudioApps() async {
        guard let content = try? await SourceResolver.shareableContent() else { return }
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var apps: [AudioApp] = []
        // Only apps a person runs: Screen Capture Kit also lists helpers, agents and XPC services (AutoFill,
        // CursorUIViewService, Open and Save Panel Service, the Dock…), and none of those have sound of their own.
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated && app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != me, app.bundleURL?.pathExtension == "app",
                  seen.insert(id).inserted,
                  content.applications.contains(where: { $0.bundleIdentifier == id }) else { continue }
            apps.append(AudioApp(id: id, name: app.localizedName ?? id))
        }
        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        // The app picked last time may not be running now: still offer it, so the choice isn't silently lost.
        if !audioApp.isEmpty, !apps.contains(where: { $0.id == audioApp }) {
            apps.insert(AudioApp(id: audioApp, name: audioAppName.isEmpty ? audioApp : audioAppName), at: 0)
        }
        audioApps = apps
        syncAudioAppName()
    }

    func syncAudioAppName() {
        guard !audioApp.isEmpty else {
            audioAppName = ""
            return
        }
        if let name = audioApps.first(where: { $0.id == audioApp })?.name, name != audioAppName { audioAppName = name }
    }

    var bestRateLabel: String {
        if let stream = selectedDevice?.stream { return "Best (\(max(stream.maxFrameRate, 30)))" }
        let rate: Int? = switch source {
        case let .display(id), let .area(id, _): displays.first { $0.id == id }?.refreshRate
        default: NSScreen.main?.maximumFramesPerSecond
        }
        return (rate ?? 60) >= 120 ? "Best (120)" : "Best (60)"
    }

    func shown(_ p: Picker) -> Binding<Bool> {
        Binding(get: { picker == p }, set: { if !$0, picker == p { picker = nil } })
    }
}

/// A setting in the options: its name on the left, the switch lined up with the others on the right. A nested one
/// belongs to the setting above it.
private struct OptionToggle: View {
    let title: String
    @Binding var isOn: Bool
    var nested = false

    init(_ title: String, isOn: Binding<Bool>, nested: Bool = false) {
        self.title = title
        _isOn = isOn
        self.nested = nested
    }

    var body: some View {
        HStack(spacing: 8) {
            if nested {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Text(title).foregroundStyle(nested ? .secondary : .primary)
            Spacer(minLength: 12)
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .padding(.leading, nested ? 4 : 0)
    }
}
