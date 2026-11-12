//
//  CaptureBar.swift
//  Slice
//
//  Created by rit3zh CX on 10/1/26.
//

import ApplicationServices
import AVFoundation
import BorderBeamKit
import ScreenCaptureKit
import SwiftUI

struct CaptureBar: View {
    @EnvironmentObject var model: AppModel

    enum Kind: String, CaseIterable { case display = "Display", window = "Window", area = "Area", device = "Device" }

    enum Picker: Hashable { case source(Kind), mic, camera, options }

    @AppStorage("setup.kind") var kind: Kind = .display
    @AppStorage("setup.camera") var cameraID = ""
    @AppStorage("setup.mic") var micID = ""
    /// Picked by hand, "None" included: kept as it is next time instead of falling back to the first device.
    @AppStorage("setup.cameraChosen") var cameraChosen = false
    @AppStorage("setup.micChosen") var micChosen = false
    @AppStorage("setup.frameRate") var fps = Recorder.Settings.best
    @AppStorage("setup.screenAudio") var screenAudio = true
    @AppStorage("setup.keys") var keys = true
    @AppStorage("setup.typing") var typing = false
    @AppStorage("setup.showCamera") var showCamera = true
    @State var keysAllowed = AXIsProcessTrusted()
    @State var displayID: CGDirectDisplayID?
    @AppStorage("setup.display") var savedDisplay = 0
    @State var displays = DisplayInfo.all()
    @State var windowID: CGWindowID?
    @State var deviceID: String?
    @ObservedObject var areaOverlay = AreaOverlay.shared
    let windowPicker = WindowPicker.shared
    @State var windows: [SCWindow] = []
    @State var loadError: String?
    @State var picker: Picker?
    @State var appeared = false
    @State var starting = false
    @State var glide = HoverGlide()
    @Namespace var hoverSpace
    @State var optionsGlide = HoverGlide()
    @Namespace var optionsSpace
    @StateObject var cameraPreview = CameraPreviewModel()
    @StateObject var micPreview = MicPreviewModel()
    @ObservedObject var deviceManager = DeviceManager.shared
    @Namespace var selection

    @ObservedObject var captureDevices = CaptureDevices.shared

    var cameras: [AVCaptureDevice] { captureDevices.cameras }
    var mics: [AVCaptureDevice] { captureDevices.mics }

    var selectedDevice: DeviceConnection? {
        guard kind == .device, let deviceID else { return nil }
        return deviceManager.connection(for: deviceID)
    }

    var body: some View {
        let compact = stage != .setup
        controls
            .opacity(compact ? 0 : 1)
            .scaleEffect(compact ? 0.97 : 1)
            .animation(.easeOut(duration: compact ? 0.16 : 0.3), value: compact)
            .disabled(compact)
            .background(MorphSurface(size: stage.surfaceSize))
            .overlay { stageContent }
            .animation(stage == .drawing || stage == .live(canDraw: true) ? LiveBar.expand : .spring(response: 0.5, dampingFraction: 0.68),
                       value: stage)
            .padding(Bar.inset)
            .environment(\.colorScheme, .dark)
            .scaleEffect(appeared ? 1 : 0.97, anchor: .bottom)
            .offset(y: appeared ? 0 : 10)
            .opacity(appeared ? 1 : 0)
            .background(BarWindowConfigurator())
            .onAppear {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { appeared = true }
            }
            .onChange(of: compact) { if compact { picker = nil } }
            .onChange(of: stage, initial: true) { BarClickThrough.track(stage == .setup ? nil : stage.surfaceSize) }
            .onChange(of: areaMode, initial: true) { areaOverlay.present(areaMode) }
            .onChange(of: kind == .window && stage == .setup, initial: true) { windowPicker.present(kind == .window && stage == .setup) }
            .onChange(of: windows.map(\.windowID), initial: true) { windowPicker.recordable = Set(windows.map(\.windowID)) }
            .onChange(of: windowID, initial: true) { windowPicker.select(windowID) }
            .onChange(of: picker) { if picker != .source(.window) { windowPicker.clearPreview() } }
            .onAppear {
                windowPicker.onPick = { id in windowID = id }
                windowPicker.onRecord = { id in
                    windowID = id
                    Task { await record(.window(id)) }
                }
                windowPicker.onUnknown = { Task { await loadWindows() } }
            }
            .onDisappear {
                if model.recordingPhase == nil { CameraBubble.shared.hide() }
                BarClickThrough.track(nil)
                areaOverlay.present(.hidden)
                windowPicker.present(false)
            }
            .onChange(of: setupBubble, initial: true) { updateSetupBubble() }
            .onChange(of: model.recordingPhase == nil) { if model.recordingPhase == nil { starting = false } }
            .onAppear { if model.recordingPhase == nil { starting = false } }
    }

    var controls: some View {
        HStack(spacing: 0) {
            BarGrip()
                .padding(.leading, 6)
            CloseButton { model.cancelSetup() }
                .padding(.leading, 4)
                .padding(.trailing, 14)
            BarDivider()
            HStack(spacing: 2) {
                ForEach(Kind.allCases, id: \.self) { k in
                    SourceTile(kind: k, selected: kind == k, hasChoices: hasChoices(k),
                               enabled: k != .device || !deviceManager.devices.isEmpty, namespace: selection) { choose(k) }
                        .help(help(for: k))
                        .popover(isPresented: shown(.source(k)), arrowEdge: .top) { sourcePicker(k) }
                }
            }
            .padding(.horizontal, 8)
            BarDivider()
            HStack(spacing: 4) {
                micPill
                cameraPill
                optionsButton
            }
            .padding(.horizontal, 8)
            BarDivider()
            RecordButton(title: recordTitle, ready: source != nil, enabled: recordEnabled) {
                if source == nil { choose(kind) } else { Task { await record() } }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 72)
        .barDragBackground()
        .fixedSize()
        .environment(\.barGlide, BarGlide(tracker: glide, namespace: hoverSpace))
        .onChange(of: picker) { if picker == .mic || picker == .camera { captureDevices.refresh() } }
        .onChange(of: deviceManager.devices.map(\.id), initial: true) {
            captureDevices.refresh()
            if deviceID.flatMap(deviceManager.connection(for:)) == nil { deviceID = deviceManager.devices.first?.id }
            if kind == .device, deviceManager.devices.isEmpty { kind = .display }
        }
        .onChange(of: selectedDevice?.id, initial: true) {
            selectedDevice?.showWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshDisplays()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if !keysAllowed { keysAllowed = AXIsProcessTrusted() }
        }
        .onChange(of: cameraID, initial: true) { cameraPreview.show(cameraID: cameraID.isEmpty ? nil : cameraID) }
        .onChange(of: micID, initial: true) { micPreview.show(micID: micID.isEmpty ? nil : micID) }
        .onDisappear {
            cameraPreview.stop()
            micPreview.stop()
        }
        .task {
            refreshDisplays()
            if kind == .area, areaOverlay.area == nil { kind = .display }
            await loadWindows()
            captureDevices.refresh()
            // Off stays off. Only a first run, or a picked device that's been unplugged, falls back to what's there.
            if !(cameraChosen && cameraID.isEmpty), !cameras.contains(where: { $0.uniqueID == cameraID }) {
                cameraID = cameras.first?.uniqueID ?? ""
            }
            if !(micChosen && micID.isEmpty), !mics.contains(where: { $0.uniqueID == micID }) {
                micID = AVCaptureDevice.default(for: .audio)?.uniqueID ?? ""
            }
        }
    }

    // MARK: - Camera bubble

    /// The camera preview to show in the bubble while setting up, so you can see how you look and where it sits
    /// before pressing Record.
    var setupBubble: ObjectIdentifier? {
        guard stage == .setup, showCamera, cameraName != nil else { return nil }
        return cameraPreview.session.map(ObjectIdentifier.init)
    }

    func updateSetupBubble() {
        if setupBubble != nil, let session = cameraPreview.session {
            CameraBubble.shared.show(session: session)
        } else if model.recordingPhase == nil, !starting {
            // Once Record is pressed the recording takes the bubble over, or puts it away.
            CameraBubble.shared.hide()
        }
    }

    // MARK: - Recording stages

    static func surface(for phase: RecordingController.Phase?) -> (rect: CGRect, radius: CGFloat)? {
        guard let window = AppModel.captureBarWindow, window.isVisible else { return nil }
        let bar = window.frame.insetBy(dx: Bar.inset, dy: Bar.inset)
        guard let size = BarStage(phase: phase).surfaceSize else { return (bar, Bar.radius) }
        return (CGRect(x: bar.midX - size.width / 2, y: bar.midY - size.height / 2, width: size.width, height: size.height),
                Bar.radius)
    }

    var stage: BarStage {
        model.recordingPhase == nil && starting ? .countdown(3) : BarStage(phase: model.recordingPhase, annotating: model.annotating)
    }

    @ViewBuilder var stageContent: some View {
        ZStack {
            switch stage {
            case .setup:
                EmptyView()
            case let .countdown(n):
                Text("\(n)")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.spring(response: 0.42, dampingFraction: 0.62), value: n)
                    .transition(.stageContent)
            case .live, .drawing:
                if let recording = model.recording {
                    LiveBar(recording: recording, drawing: stage == .drawing,
                            session: model.annotating == nil ? nil : AnnotationController.shared.session)
                        .transition(.stageContent)
                }
            case .saving:
                ProgressView()
                    .controlSize(.small)
                    .transition(.stageContent)
            }
        }
    }

    // MARK: - Recording

    func loadWindows() async {
        do {
            let content = try await SourceResolver.shareableContent()
            let myPID = ProcessInfo.processInfo.processIdentifier
            windows = content.windows
                .filter { w in
                    guard w.windowLayer == 0, w.frame.width > 120, w.frame.height > 80, let app = w.owningApplication,
                          app.processID != myPID,
                          NSRunningApplication(processIdentifier: app.processID)?.activationPolicy == .regular else { return false }
                    return w.isOnScreen || !(w.title ?? "").isEmpty
                }
                .sorted {
                    let a = $0.owningApplication?.applicationName ?? "", b = $1.owningApplication?.applicationName ?? ""
                    return a == b ? ($0.title ?? "") < ($1.title ?? "") : a.localizedStandardCompare(b) == .orderedAscending
                }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func record(_ picked: CaptureSource? = nil) async {
        guard let source = picked ?? source, !starting else { return }
        starting = true
        cameraPreview.stop()
        micPreview.stop()
        if !cameraID.isEmpty, !(await AVCaptureDevice.requestAccess(for: .video)) {
            model.error = "Camera access was denied. Enable it in System Settings > Privacy & Security > Camera."
            starting = false
            model.showProjects()
            return
        }
        if !micID.isEmpty, !(await AVCaptureDevice.requestAccess(for: .audio)) {
            model.error = "Microphone access was denied. Enable it in System Settings > Privacy & Security > Microphone."
            starting = false
            model.showProjects()
            return
        }
        let settings = Recorder.Settings(source: source, cameraID: cameraID.isEmpty ? nil : cameraID,
                                         micID: micID.isEmpty ? nil : micID, fps: fps, screenAudio: screenAudio,
                                         keys: keys, typing: typing, showCamera: showCamera)
        model.startRecording(settings: settings, appendTo: model.setupAppendTo)
    }
}

private struct BarDivider: View {
    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.14), .white.opacity(0)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: 1, height: 44)
    }
}
