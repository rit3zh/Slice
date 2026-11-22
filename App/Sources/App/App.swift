//
//  App.swift
//  Slice
//
//  Created by rit3zh CX on 10/3/26.
//

import Combine
import SliceCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct SliceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("Record", id: AppModel.captureBarID) {
            CaptureBar()
                .environmentObject(model)
                .modifier(WindowActions(model: model))
        }
        .windowStyle(.plain)
        .windowLevel(.floating)
        // Project files are opened by AppDelegate; without this SwiftUI would also bring up the bar for them.
        .handlesExternalEvents(matching: [])
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.presented)
        .defaultWindowPlacement { content, context in
            let display = context.defaultDisplay.visibleRect
            let size = content.sizeThatFits(.unspecified)
            return WindowPlacement(CGPoint(x: display.midX - size.width / 2, y: display.maxY - size.height - 60), size: size)
        }

        Window("Slice", id: AppModel.mainWindowID) {
            RootView()
                .environmentObject(model)
                .modifier(WindowActions(model: model))
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { model.newRecording() }.keyboardShortcut("n")
                Button("Open…") { model.chooseProjectToOpen() }.keyboardShortcut("o")
                Button("Projects") { model.showProjects() }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.openEditor?.saveNow() }.keyboardShortcut("s")
                    .disabled(model.openEditor == nil)
                Button("Show in Finder") {
                    if let url = model.openEditor?.bundle.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                .disabled(model.openEditor == nil)
            }
        }

        Settings {
            SettingsView()
        }
    }
}

private struct WindowActions: ViewModifier {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            model.openWindow = openWindow
            model.dismissWindow = dismissWindow
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launched = false
    /// Installed at launch. `applicationWillTerminate` calls it directly instead of re-entering the main
    /// actor through `MainActor.assumeIsolated`: that runtime check faults inside an AppKit callback on
    /// macOS 26 (SIGSEGV in libswift_Concurrency), which crashed every quit.
    private var closeEditorOnQuit: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            if !launched { AppModel.shared.launchedWithProject = true }
            AppModel.shared.openFiles(urls)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        closeEditorOnQuit?()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        MainActor.assumeIsolated {
            closeEditorOnQuit = { AppModel.shared.openEditor?.close() }
            DeviceManager.shared.start()
            AnnotationController.shared.install()
        }
        // Once the bar is on screen, so opening Slice never waits on the network.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { Updater.shared.start() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MainActor.assumeIsolated {
            if AppModel.shared.recording == nil { AppModel.shared.newRecording() }
        }
        return false
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            switch model.screen {
            case .home:
                ProjectsView()
            case let .editor(editor):
                EditorView(editor: editor)
                    .id(ObjectIdentifier(editor))
            }
        }
        .alert("Recording recovered", isPresented: Binding(get: { model.recovered != nil }, set: { if !$0 { model.recovered = nil } })) {
            Button("Open") {
                if let bundle = model.recovered { model.open(bundle) }
                model.recovered = nil
            }
            Button("Not Now", role: .cancel) { model.recovered = nil }
        } message: {
            Text("Slice stopped while “\(model.recovered?.displayName ?? "")” was recording. The take is back in the project, "
                + "up to the last couple of seconds before it stopped.")
        }
        .overlay {
            Theme.window
                .opacity(model.covered ? 1 : 0)
                .allowsHitTesting(model.covered)
        }
        .background(Theme.window)
        .background(MainWindowProbe())
        .preferredColorScheme(.dark)
        .alert("Something went wrong", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }
}

private struct MainWindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        private var closeObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            AppModel.mainWindow = window
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                                   queue: .main) { [weak window] _ in
                MainActor.assumeIsolated { if AppModel.mainWindow === window { AppModel.mainWindow = nil } }
            }
            if AppModel.prewarming {
                AppModel.prewarming = false
                window.alphaValue = 0
                DispatchQueue.main.async {
                    window.orderOut(nil)
                    window.alphaValue = 1
                    if let bar = AppModel.captureBarWindow, bar.isVisible { bar.makeKeyAndOrderFront(nil) }
                }
            } else if let reveal = AppModel.pendingReveal {
                AppModel.pendingReveal = nil
                window.alphaValue = 0
                DispatchQueue.main.async { WindowMorph.reveal(window, from: reveal.rect, radius: reveal.radius) }
            }
        }

        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        }
    }
}

extension UTType {
    static let sliceProject = UTType(filenameExtension: ProjectBundle.fileExtension, conformingTo: .package)!
}
