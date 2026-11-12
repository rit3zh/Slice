//
//  Wallpapers.swift
//  Slice
//
//  Created by rit3zh CX on 10/9/26.
//

import Foundation
import SliceCore

enum Wallpapers {
    static let bundled: [URL] = {
        guard let dir = Bundle.main.url(forResource: "Wallpapers", withExtension: nil) else { return [] }
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }()

    /// A new project on a random wallpaper, exporting as the last export did.
    static func newProject(name: String) throws -> (ProjectBundle, Project) {
        var (bundle, project) = try ProjectBundle.create(name: name)
        var changed = false
        if let url = bundled.randomElement(), let image = try? bundle.importBackground(from: url) {
            project.style.backgroundImage = image
            changed = true
        }
        if let export = ExportDefaults.last {
            project.export = export
            changed = true
        }
        if changed { try bundle.save(project) }
        return (bundle, project)
    }
}
