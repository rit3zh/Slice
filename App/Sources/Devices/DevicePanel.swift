//
//  DevicePanel.swift
//  Slice
//
//  Created by rit3zh CX on 10/11/26.
//

import AppKit
import ImageIO
import SliceCore
import SwiftUI

struct DevicePanel: View {
    @Binding var deviceID: String?
    @ObservedObject private var manager = DeviceManager.shared
    @State private var glide = HoverGlide()
    @Namespace private var hoverSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if manager.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector").font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                    Text("Connect an iPhone with a USB cable").font(.system(size: 12.5, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                if manager.devices.count > 1 {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle("Device").padding(.horizontal, 8)
                        VStack(spacing: 2) {
                            ForEach(manager.devices) { d in
                                PickerRow(title: d.name, subtitle: d.deviceName ?? d.state.title, selected: deviceID == d.id,
                                          symbol: "iphone") { deviceID = d.id }
                            }
                        }
                    }
                    .padding(.horizontal, -8)
                    Divider()
                }
                if let connection = deviceID.flatMap(manager.connection(for:)) {
                    DeviceDetails(connection: connection)
                        .id(connection.id)
                }
            }
        }
        .font(.system(size: 12.5))
        .padding(16)
        .frame(width: 320)
        .environment(\.barGlide, BarGlide(tracker: glide, namespace: hoverSpace))
        .barPopoverAppearance()
    }
}

private struct DeviceDetails: View {
    @ObservedObject var connection: DeviceConnection
    @AppStorage("device.floatsOnTop") private var floatsOnTop = true
    @AppStorage(DeviceConnection.opensIn3DKey) private var opensIn3D = false
    @State private var windowVisible = true

    private var catalog: DeviceFrameCatalog { DeviceManager.shared.catalog }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            frameSection
            threeDSection
            MoreOptions(id: "devicePanel") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Play the iPhone's sound on this Mac", isOn: $connection.playsSound)
                    Toggle("Keep the iPhone above other windows", isOn: $floatsOnTop)
                    HStack(spacing: 6) {
                        Text("Size").foregroundStyle(.secondary)
                        Spacer()
                        ForEach([("Actual", 1.0), ("Half", 0.5), ("Third", 0.34)] as [(String, CGFloat)], id: \.0) { title, fraction in
                            Button(title) { connection.setWindowScale(fraction) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
        }
        .onChange(of: floatsOnTop) { connection.setFloatsOnTop(floatsOnTop) }
        .onAppear { windowVisible = connection.isWindowVisible }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            LiveDeviceThumbnail(connection: connection)
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.info.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                if let name = connection.info.deviceName, name != connection.info.name {
                    Text(name).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(connection.info.state == .streaming ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                .padding(.top, 2)
                if !windowVisible {
                    Button("Show on Desktop") {
                        connection.showWindow()
                        windowVisible = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 6)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var status: String {
        guard connection.info.state == .streaming else { return connection.info.state.title }
        return connection.frameRate > 0 ? "Live · \(connection.frameRate) fps" : "Live"
    }

    // MARK: - Frame

    private var frameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Frame")
                Spacer()
                frameMenu
            }
            if let frame = connection.frame, !frame.isFrameless {
                let colors = catalog.colors(for: frame.model)
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        ForEach(colors, id: \.self) { color in
                            ColorSwatch(model: frame.model, color: color, url: catalog.frames[frame.model]?[color],
                                        selected: color == frame.color) { connection.useColor(color) }
                        }
                    }
                    Text(frame.color.rawValue)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    Spacer(minLength: 0)
                }
                .animation(.smooth(duration: 0.25), value: frame.color)
            } else if connection.frame?.isFrameless == true {
                Text(connection.frameChoiceIsAutomatic ? "No frame fits this iPhone's screen, so it's shown on its own."
                                                       : "The screen is shown on its own.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if connection.frame != nil, !connection.frameIsExact, connection.frameChoiceIsAutomatic, connection.frame?.isFrameless == false {
                Text("There's no frame for this exact model; this one has the same screen.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 3D

    private var threeDSection: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit on a 3D iPhone").font(.system(size: 12.5, weight: .medium))
                Text("Records as usual. The editor then shows the take on a 3D phone, which you can turn off at any time.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("Edit on a 3D iPhone", isOn: $opensIn3D)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var frameMenu: some View {
        let automatic = connection.frameChoiceIsAutomatic
        let current = connection.frame
        return Menu {
            Toggle(automaticTitle, isOn: Binding(get: { automatic }, set: { _ in connection.useFrame(model: nil) }))
            Divider()
            ForEach(catalog.models, id: \.self) { model in
                Toggle(Self.displayName(model), isOn: Binding(
                    get: { !automatic && current?.isFrameless == false && current?.model == model },
                    set: { _ in connection.useFrame(model: model) }))
            }
            Divider()
            Toggle("No Frame", isOn: Binding(get: { !automatic && current?.isFrameless == true },
                                             set: { _ in connection.useFrame(model: "") }))
        } label: {
            HStack(spacing: 5) {
                Text(menuTitle).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).opacity(0.6)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var automaticTitle: String {
        guard let model = connection.info.model else { return "Automatic" }
        return "Automatic (\(model.name))"
    }

    private var menuTitle: String {
        guard let frame = connection.frame else { return "Automatic" }
        if frame.isFrameless { return "No Frame" }
        return Self.displayName(frame.model)
    }

    static func displayName(_ model: String) -> String { "iPhone \(model)" }
}

private struct LiveDeviceThumbnail: View {
    @ObservedObject var connection: DeviceConnection

    var body: some View {
        let canvas = connection.layout?.canvas ?? CGSize(width: 1, height: 2.05)
        let height: CGFloat = 132
        let width = min(height * canvas.width / max(canvas.height, 1), 150)
        ZStack {
            if connection.frame != nil {
                PhonePreview(source: connection.preview)
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                Image(systemName: "iphone").font(.system(size: 22, weight: .light)).foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: width * canvas.height / max(canvas.width, 1))
        .frame(height: height)
        .animation(.smooth(duration: 0.3), value: canvas)
    }
}

struct ColorSwatch: View {
    let model: String
    let color: DeviceColor
    let url: URL?
    let selected: Bool
    let action: () -> Void
    @State private var fill: Color?
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill ?? Color.gray.opacity(0.4))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .frame(width: 20, height: 20)
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Theme.accent : Color.white.opacity(hovering ? 0.25 : 0), lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(color.rawValue)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: selected)
        .animation(.smooth(duration: 0.15), value: hovering)
        .task(id: url) { fill = await FrameSwatch.color(model: model, color: color, url: url) }
    }
}

enum FrameSwatch {
    private static let known: [String: (Double, Double, Double)] = [
        "Black": (0x32, 0x34, 0x36), "Space Black": (0x3B, 0x3A, 0x3C), "Black Titanium": (0x3C, 0x3C, 0x3D),
        "Silver": (0xDC, 0xDD, 0xDF), "White": (0xEE, 0xEE, 0xEC), "Cloud White": (0xEF, 0xEF, 0xEA),
        "White Titanium": (0xE4, 0xE2, 0xDD), "Natural Titanium": (0xB5, 0xAF, 0xA5), "Desert Titanium": (0xC4, 0xA9, 0x94),
        "Blue Titanium": (0x47, 0x4E, 0x5D), "Starlight": (0xEA, 0xE4, 0xDC), "Gold": (0xF1, 0xE5, 0xCB),
        "Light Gold": (0xE9, 0xDD, 0xC4), "Deep Purple": (0x5E, 0x54, 0x69), "Product (RED)": (0xE8, 0x2D, 0x3A),
        "Cosmic Orange": (0xEE, 0x85, 0x48), "Deep Blue": (0x3E, 0x4A, 0x63), "Sky Blue": (0xBF, 0xD6, 0xE8),
        "Ultramarine": (0x8C, 0x9E, 0xEB), "Teal": (0xA5, 0xCC, 0xCB),
    ]

    @MainActor private static var measured: [URL: Color] = [:]

    @MainActor static func color(model: String, color: DeviceColor, url: URL?) async -> Color? {
        if let rgb = known[color.rawValue] { return Color(red: rgb.0 / 255, green: rgb.1 / 255, blue: rgb.2 / 255) }
        guard let url else { return nil }
        if let cached = measured[url] { return cached }
        guard let rgb = await Task.detached(operation: { rimColor(url) }).value else { return nil }
        let c = Color(red: rgb.0, green: rgb.1, blue: rgb.2)
        measured[url] = c
        return c
    }

    private static func rimColor(_ url: URL) -> (Double, Double, Double)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                          kCGImageSourceThumbnailMaxPixelSize: 900] as CFDictionary)
        else { return nil }
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var sum = (0.0, 0.0, 0.0), n = 0.0
        for y in stride(from: h * 6 / 10, to: h * 9 / 10, by: 2) {
            var x = w - 1
            while x > w / 2, px[(y * w + x) * 4 + 3] < 250 { x -= 1 }
            for k in 1 ..< 4 where x - k > 0 {
                let i = (y * w + x - k) * 4
                guard px[i + 3] > 250 else { continue }
                sum.0 += Double(px[i]); sum.1 += Double(px[i + 1]); sum.2 += Double(px[i + 2]); n += 1
            }
        }
        guard n > 0 else { return nil }
        return (sum.0 / n / 255, sum.1 / n / 255, sum.2 / n / 255)
    }
}
