//
//  EditorModel+DeviceImport.swift
//  Slice
//
//  Created by rit3zh CX on 10/29/26.
//

import Foundation
import SliceCore

extension EditorModel {
    /// A video taken in as a take. An iPhone's screen recording (the Simulator's, or the phone's own) goes into a
    /// device frame, so it shows in the flat mockup like a take recorded through Slice. Headed for the 3D phone
    /// (`onto3D`, or while it's showing) it goes in as it is: the phone is its frame, and a frame's island drawn into
    /// the picture would cover whatever the recording has under it (an app's own island, say) for good.
    func importTake(_ url: URL, onto3D: Bool = false) async throws -> Clip {
        guard let size = try? await ClipImporter.videoSize(of: url) else { return try await ClipImporter.importVideo(url, into: bundle) }
        // The 3D devices are an iPhone and a Mac: what's added from the 3D tab goes on one of them.
        if !onto3D, let android = await DeviceVideoImporter.androidPhone(forVideo: url, size: size, catalog: DeviceManager.shared.androidCatalog) {
            deviceImportProgress = 0
            defer { deviceImportProgress = nil }
            let frame = androidFramesOn ? await androidFrame(forVideo: size) : nil
            return try await DeviceVideoImporter.importAndroidVideo(url, into: bundle, phone: android, frame: frame,
                                                                    progress: reportingImportProgress(of: 0, in: 1))
        }
        guard let phone = DeviceVideoImporter.phone(forVideo: size) else { return try await ClipImporter.importVideo(url, into: bundle) }
        deviceImportProgress = 0
        defer { deviceImportProgress = nil }
        let showing3D = project.device3D.enabled && project.device3D.model.kind == .phone
        let frame = onto3D || showing3D ? nil : await importFrame(for: phone)
        return try await DeviceVideoImporter.importVideo(url, into: bundle, phone: phone, frame: frame,
                                                         progress: reportingImportProgress(of: 0, in: 1))
    }

    private func reportingImportProgress(of index: Int, in count: Int) -> @Sendable (Double) -> Void {
        { p in
            Task { @MainActor [weak self] in
                guard let self, self.deviceImportProgress != nil else { return }
                self.deviceImportProgress = (Double(index) + p) / Double(count)
            }
        }
    }

    // MARK: - Android frames

    /// Whether Android takes go in a frame: as this project's already do, or else as last chosen.
    var androidFramesOn: Bool {
        project.clips.last(where: \.isAndroid)?.device.map { $0.frame != nil }
            ?? UserDefaults.standard.object(forKey: AndroidFrames.enabledKey) as? Bool ?? true
    }

    /// The frame for an Android recording of `size`: the model chosen in the Frame tab, or the closest to its screen,
    /// in the colour last chosen for that model.
    private func androidFrame(forVideo size: CGSize) async -> DeviceFrameDefinition? {
        let catalog = DeviceManager.shared.androidCatalog
        return await Task.detached {
            let defaults = UserDefaults.standard
            guard let model = defaults.string(forKey: AndroidFrames.modelKey).flatMap({ catalog.frames[$0] == nil ? nil : $0 })
                ?? catalog.frame(for: .android(screenPixels: size), aspectTolerance: DeviceVideoImporter.androidAspectTolerance)?.model
            else { return nil }
            let colors = catalog.colors(for: model)
            let last = defaults.string(forKey: "deviceFrame.color.\(model)").map { DeviceColor($0) }
            guard let color = last.flatMap({ colors.contains($0) ? $0 : nil }) ?? colors.first else { return nil }
            return try? catalog.definition(model: model, color: color)
        }.value
    }

    /// Puts the project's Android takes in the frame now chosen, or none, as one undo step. Frames are drawn into the
    /// video, so this takes as long as importing them did, the first time.
    func reframeAndroidTakes() async {
        let takes = project.clips.filter(\.isAndroid)
        guard !takes.isEmpty, deviceImportProgress == nil else { return }
        let on = UserDefaults.standard.object(forKey: AndroidFrames.enabledKey) as? Bool ?? true
        deviceImportProgress = 0
        defer { deviceImportProgress = nil }
        var framed: [Clip] = []
        do {
            for (i, clip) in takes.enumerated() {
                guard let file = clip.device?.unframedFile else { continue }
                let size = try await ClipImporter.videoSize(of: bundle.file(file))
                let frame = on ? await androidFrame(forVideo: size) : nil
                framed.append(try await DeviceVideoImporter.reframed(clip, in: bundle, frame: frame,
                                                                     progress: reportingImportProgress(of: i, in: takes.count)))
            }
        } catch {
            transcribeError = "Couldn't change the Android frame: \(error.localizedDescription)"
            return
        }
        var updated = project
        framed.forEach { updated.applyFraming(of: $0) }
        project = updated
        saveNow()
    }

    /// A recording added from the 3D tab, shown on the device it's of (an iPhone's screen recording on the 3D iPhone,
    /// anything else on the Mac), with the playhead on it.
    func importOnto3D(_ url: URL) async {
        let before = Set(project.clips.map(\.id))
        await importClips([url], onto3D: true)
        guard let i = project.clips.lastIndex(where: { !before.contains($0.id) }) else { return }
        let kind: Device3DKind = project.clips[i].device == nil ? .laptop : .phone
        if project.device3D.model.kind != kind { select3DModel(Device3DModel.models(kind)[0]) }
        project.device3D.enabled = true
        selection = nil
        seek(to: project.clipStarts[i])
    }

    /// The frame an imported phone recording goes in: none when the project's phone takes have none, else that
    /// iPhone's, in the colour the project's takes in it have (or the one last chosen for it).
    private func importFrame(for phone: DeviceModel) async -> DeviceFrameDefinition? {
        let taken = project.clips.compactMap(\.device).filter { !$0.isAndroid }
        if let last = taken.last, last.frame == nil { return nil }
        let catalog = DeviceManager.shared.catalog
        guard let pick = catalog.frame(for: phone) else { return nil }
        let colors = catalog.colors(for: pick.model)
        let own = taken.last { $0.frame == pick.model }?.color.map { DeviceColor($0) }
        let chosen = UserDefaults.standard.string(forKey: "deviceFrame.color.\(pick.model)").map { DeviceColor($0) }
        guard let color = [own, chosen].compactMap({ $0 }).first(where: colors.contains) ?? colors.first else { return nil }
        return await Task.detached { try? catalog.definition(model: pick.model, color: color) }.value
    }
}
