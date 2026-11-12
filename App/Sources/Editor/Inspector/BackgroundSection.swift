//
//  BackgroundSection.swift
//  Slice
//
//  Created by rit3zh CX on 10/9/26.
//

import SliceCore
import SwiftUI

private struct GradientPreset: Identifiable {
    let id: String
    let top: RGBA
    let bottom: RGBA
}

private let gradientPresets: [GradientPreset] = [
    .init(id: "Dusk", top: RGBA(0.36, 0.30, 0.85), bottom: RGBA(0.92, 0.45, 0.62)),
    .init(id: "Midnight", top: RGBA(0.09, 0.10, 0.24), bottom: RGBA(0.33, 0.20, 0.62)),
    .init(id: "Ocean", top: RGBA(0.10, 0.36, 0.80), bottom: RGBA(0.30, 0.78, 0.92)),
    .init(id: "Sunset", top: RGBA(0.98, 0.55, 0.24), bottom: RGBA(0.86, 0.22, 0.42)),
    .init(id: "Meadow", top: RGBA(0.20, 0.62, 0.38), bottom: RGBA(0.80, 0.86, 0.32)),
    .init(id: "Peach", top: RGBA(1.00, 0.78, 0.55), bottom: RGBA(0.98, 0.50, 0.50)),
    .init(id: "Aurora", top: RGBA(0.12, 0.70, 0.62), bottom: RGBA(0.40, 0.25, 0.85)),
    .init(id: "Graphite", top: RGBA(0.22, 0.23, 0.26), bottom: RGBA(0.06, 0.06, 0.08)),
    .init(id: "Candy", top: RGBA(0.98, 0.40, 0.70), bottom: RGBA(0.98, 0.78, 0.40)),
    .init(id: "Steel", top: RGBA(0.55, 0.62, 0.72), bottom: RGBA(0.24, 0.28, 0.36)),
    .init(id: "Lagoon", top: RGBA(0.02, 0.45, 0.55), bottom: RGBA(0.05, 0.15, 0.32)),
    .init(id: "Ember", top: RGBA(0.45, 0.08, 0.10), bottom: RGBA(0.95, 0.42, 0.12)),
]

private enum BackgroundTab: Hashable { case wallpaper, gradient, custom }

struct BackgroundSection: View {
    @ObservedObject var editor: EditorModel
    @State private var library: [URL] = BackgroundLibrary.list()
    @State private var chosenTab: BackgroundTab?

    private var style: FrameStyle { editor.project.style }
    private var hasMockup: Bool { style.mockup.kind != .none }

    private var tab: BackgroundTab {
        if let chosenTab { return chosenTab }
        guard let image = style.backgroundImage else { return .gradient }
        let name = (image as NSString).lastPathComponent
        return Self.wallpapers.contains { $0.lastPathComponent == name } ? .wallpaper : .custom
    }

    var body: some View {
        Group {
            PanelSection("Background", trailing: AnyView(shuffleButton)) {
                SegmentedControl(selection: Binding(get: { tab }, set: { chosenTab = $0 }),
                                 options: Self.wallpapers.isEmpty ? [.gradient, .custom] : [.wallpaper, .gradient, .custom],
                                 title: { t in
                                     switch t {
                                     case .wallpaper: "Wallpaper"
                                     case .gradient: "Gradient"
                                     case .custom: "Custom"
                                     }
                                 })
                ZStack(alignment: .top) {
                    switch tab {
                    case .wallpaper: wallpapers.transition(.opacity)
                    case .gradient: gradients.transition(.opacity)
                    case .custom: custom.transition(.opacity)
                    }
                }
                .animation(Theme.swap, value: tab)
                if style.backgroundImage != nil, tab != .gradient {
                    PanelSlider("Blur", value: $editor.project.style.backgroundBlur, in: 0 ... 1, default: 0) {
                        $0 < 0.005 ? "None" : percent($0, of: 0 ... 1)
                    }
                    .help("Softens the background image so the screen stands out")
                    .transition(.opacity)
                }
            }

            PanelDivider()

            PanelSection("Frame") {
                PanelSlider("Padding", value: $editor.project.style.padding, in: 0 ... 0.15, default: FrameStyle().padding) {
                    $0 < 0.0005 ? "None" : percent($0, of: 0 ... 0.15)
                }
                .help("Space around the screen. With none the screen fills the frame edge to edge.")
                Group {
                    PanelSlider("Corner radius", value: $editor.project.style.screenCornerRadius, in: 0 ... 0.05,
                                default: FrameStyle().screenCornerRadius) { percent($0, of: 0 ... 0.05) }
                        .disabled(hasMockup)
                        .opacity(hasMockup ? 0.45 : 1)
                        .help(hasMockup ? "The mockup has its own corners" : "")
                    PanelSlider("Shadow", value: $editor.project.style.shadow, in: 0 ... 1, default: FrameStyle().shadow) {
                        percent($0, of: 0 ... 1)
                    }
                    PanelSlider("Border", value: $editor.project.style.screenBorder, in: 0 ... 1, default: 0) {
                        $0 < 0.01 ? "None" : percent($0, of: 0 ... 1)
                    }
                    .disabled(hasMockup)
                    .opacity(hasMockup ? 0.45 : 1)
                    .help(hasMockup ? "The mockup has its own edge" : "A thin light edge around the screen, like a bezel catching the light")
                }
                .disabled(style.padding < 0.0005)
                .opacity(style.padding < 0.0005 ? 0.45 : 1)
                .help(style.padding < 0.0005 ? "Add some padding to round the corners or cast a shadow" : "")
            }

            PanelDivider()

            MockupSection(editor: editor)

            PanelDivider()

            PanelSection("Zoom") {
                PanelSlider("Zoom speed", value: $editor.project.style.zoomTransitionDuration, in: 0.3 ... 2,
                            default: FrameStyle().zoomTransitionDuration) { String(format: "%.1fs", $0) }
                PanelToggle("Motion blur", isOn: $editor.project.style.motionBlur)
                    .help("Blurs the screen while it zooms and the camera while it moves, like a camera exposure")
                if style.motionBlur {
                    PanelSlider("Amount", value: $editor.project.style.motionBlurAmount, in: 0.1 ... 1,
                                default: FrameStyle().motionBlurAmount) { "\(Int(($0 * 100).rounded()))%" }
                }
            }

            PanelDivider()

            SmartZoomSection(editor: editor)

            PanelDivider()

            SpeedUpSection(editor: editor)
        }
        .animation(.snappy, value: style.padding < 0.0005)
        .animation(Theme.swap, value: style.backgroundImage != nil && tab != .gradient)
        .animation(.snappy, value: style.motionBlur)
        .onAppear { library = BackgroundLibrary.list() }
    }

    private var shuffleButton: some View {
        Button {
            let all = Self.wallpapers + library
            if let url = all.filter({ !isSelected($0) }).randomElement() ?? all.first {
                chosenTab = nil
                withAnimation(.snappy) { editor.useBackground(url) }
            }
        } label: { Image(systemName: "shuffle") }
            .buttonStyle(IconButtonStyle(size: 24, iconSize: 11))
            .disabled(Self.wallpapers.isEmpty && library.isEmpty)
            .help("Random image")
    }

    private var wallpapers: some View {
        PagedGrid(items: Self.wallpapers) { url in
            Tile(selected: isSelected(url)) { editor.useBackground(url) } content: { Thumbnail(url: url) }
                .help(url.deletingPathExtension().lastPathComponent)
        }
    }

    private var gradients: some View {
        VStack(alignment: .leading, spacing: 12) {
            PagedGrid(items: gradientPresets.map(\.id)) { id in
                let preset = gradientPresets.first { $0.id == id }!
                Tile(selected: style.backgroundImage == nil && style.backgroundTop == preset.top
                    && style.backgroundBottom == preset.bottom) {
                    editor.project.style.backgroundTop = preset.top
                    editor.project.style.backgroundBottom = preset.bottom
                    editor.useGradientBackground()
                } content: {
                    LinearGradient(colors: [Color(rgba: preset.top), Color(rgba: preset.bottom)], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                .help(id)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom colours").font(.system(size: 13))
                MorphColorPicker(fields: [
                    .init(id: "top", label: "Top", color: $editor.project.style.backgroundTop),
                    .init(id: "bottom", label: "Bottom", color: $editor.project.style.backgroundBottom),
                ]) { editor.useGradientBackground() }
            }
        }
    }

    private var custom: some View {
        PagedGrid(items: [nil] + library.map(Optional.some)) { url in
            if let url {
                Tile(selected: isSelected(url)) { editor.useBackground(url) } content: { Thumbnail(url: url) }
                    .help(url.deletingPathExtension().lastPathComponent)
                    .contextMenu {
                        Button("Remove from library") {
                            try? BackgroundLibrary.remove(url)
                            library = BackgroundLibrary.list()
                        }
                    }
            } else {
                Tile(selected: false, action: addImages) {
                    ZStack {
                        Theme.control
                        Image(systemName: "plus").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .help("Add images to your library, for use in any project")
            }
        }
    }

    private static var wallpapers: [URL] { Wallpapers.bundled }

    private func isSelected(_ url: URL) -> Bool { style.backgroundImage == "backgrounds/\(url.lastPathComponent)" }

    private func addImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Images are added to your background library for use in any project."
        guard panel.runModal() == .OK else { return }
        editor.addToLibrary(panel.urls)
        library = BackgroundLibrary.list()
    }
}

struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.primary.opacity(0.08)
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: image != nil)
        .task(id: url) {
            let url = url
            image = await Task.detached {
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 240,
                      ] as CFDictionary) else { return nil }
                return NSImage(cgImage: cg, size: .zero)
            }.value
        }
    }
}
