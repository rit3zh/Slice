//
//  DeviceManager.swift
//  Slice
//
//  Created by rit3zh CX on 10/1/26.
//

import AVFoundation
import Combine
import OSLog
import SliceCore
import SwiftUI

/// Device events, for diagnosing connections: `log stream --predicate 'subsystem == "Slice"'`.
let log = Logger(subsystem: "Slice", category: "Devices")

enum DeviceState: Equatable {
    case waitingForTrust
    case waitingForStream
    case connecting
    case screenAsleep
    case streaming
    case permissionDenied
    case unavailable(String)

    var title: String {
        switch self {
        case .waitingForTrust: "Tap Trust on iPhone"
        case .waitingForStream: "Unlock iPhone"
        case .connecting: "Connecting…"
        case .screenAsleep: "Wake iPhone"
        case .streaming: "Connected"
        case .permissionDenied: "Capture permission unavailable"
        case .unavailable: "Screen stream unavailable"
        }
    }

    var detail: String {
        switch self {
        case .waitingForTrust:
            "Unlock your iPhone and tap Trust when it asks whether to trust this Mac, then enter your passcode."
        case .waitingForStream:
            "Waiting for device authorization. Unlock your iPhone; its screen appears here a moment later."
        case .connecting: "Opening the screen stream."
        case .screenAsleep: "The iPhone isn't sending a picture. Wake or unlock it."
        case .streaming: ""
        case .permissionDenied:
            "Slice needs Camera access to show an iPhone's screen. Allow it in System Settings > Privacy & Security > Camera."
        case let .unavailable(reason): reason
        }
    }

    var systemImage: String {
        switch self {
        case .waitingForTrust: "hand.tap"
        case .waitingForStream: "lock.iphone"
        case .connecting: "cable.connector"
        case .screenAsleep: "iphone.slash"
        case .streaming: "iphone"
        case .permissionDenied: "hand.raised"
        case .unavailable: "exclamationmark.triangle"
        }
    }
}

struct ConnectedDevice: Identifiable, Equatable {
    let id: String
    var identifier: String
    var name: String
    var deviceName: String?
    var model: DeviceModel?
    var state: DeviceState
}

@MainActor
final class DeviceManager: ObservableObject {
    static let shared = DeviceManager()

    @Published private(set) var connections: [DeviceConnection] = []

    let catalog: DeviceFrameCatalog
    /// Kept apart from the iPhone frames, which connected iPhones choose among.
    let androidCatalog: DeviceFrameCatalog
    private var listener: Usbmux.Listener?
    private var observers: [NSObjectProtocol] = []
    private var forwarding: [String: AnyCancellable] = [:]
    private var removals: [String: Task<Void, Never>] = [:]
    private var started = false

    private init() {
        let dir = Bundle.main.url(forResource: "DeviceFrames", withExtension: nil) ?? Bundle.main.bundleURL
        catalog = DeviceFrameCatalog(directory: dir)
        androidCatalog = DeviceFrameCatalog(directory: Bundle.main.url(forResource: "AndroidFrames", withExtension: nil) ?? Bundle.main.bundleURL)
    }

    var devices: [ConnectedDevice] { connections.map(\.info) }

    func connection(for id: String) -> DeviceConnection? { connections.first { $0.id == id } }

    func start() {
        guard !started else { return }
        started = true
        DeviceStream.allowScreenCaptureDevices()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { note in
            guard let device = note.object as? AVCaptureDevice else { return }
            MainActor.assumeIsolated { self.captureDeviceAppeared(device) }
        })
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { note in
            guard let device = note.object as? AVCaptureDevice else { return }
            MainActor.assumeIsolated { self.captureDeviceDisappeared(device) }
        })
        listenToUsbmux()
        DeviceStream.screenDevices().forEach(captureDeviceAppeared)
    }

    // MARK: - usbmuxd

    private func listenToUsbmux() {
        do {
            listener = try Usbmux.listen({ event in
                Task { @MainActor in DeviceManager.shared.handle(event) }
            }, onEnd: {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    DeviceManager.shared.listenToUsbmux()
                }
            })
        } catch {
            log.error("usbmuxd unavailable: \(error, privacy: .public)")
        }
    }

    private func handle(_ event: Usbmux.Event) {
        switch event {
        case let .attached(device):
            guard device.isUSB else { return }
            log.notice("USB attached: \(device.serial, privacy: .public) (mux \(device.id))")
            let id = Self.normalise(device.serial)
            let connection = connections.first { $0.id == id || $0.serial == device.serial }
                ?? unmatchedCaptureOnlyConnection() ?? add(id: id)
            removals[connection.id]?.cancel()
            connection.attachUSB(muxID: device.id, serial: device.serial)
        case let .detached(muxID):
            log.notice("USB detached (mux \(muxID))")
            guard let connection = connections.first(where: { $0.muxID == muxID }) else { return }
            connection.usbDetached()
            // A device can drop off USB for a moment (it re-enumerates when its screen starts streaming); only an
            // unplugging that lasts is a disconnection.
            removals[connection.id] = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled, connection.muxID == nil, !self.isPresent(connection.captureDevice) else { return }
                self.remove(connection)
            }
        case let .paired(muxID):
            log.notice("Paired (mux \(muxID))")
            connections.first { $0.muxID == muxID }?.trusted()
        }
    }

    // MARK: - Capture devices

    private func captureDeviceAppeared(_ device: AVCaptureDevice) {
        guard DeviceStream.isScreenDevice(device) else { return }
        log.notice("Screen device appeared: \(device.localizedName, privacy: .public) \(device.uniqueID, privacy: .public)")
        let id = Self.normalise(device.uniqueID)
        // AVFoundation's ID for a device's screen isn't its UDID, so it's matched to the USB device by the name the
        // device reports to both, then by elimination.
        let existing = connections.first { $0.captureDevice?.uniqueID == device.uniqueID || $0.id == id }
            ?? connections.first { $0.captureDevice == nil && $0.info.deviceName == device.localizedName }
            ?? unmatchedUSBOnlyConnection()
        (existing ?? add(id: id)).attachCapture(device)
    }

    private func captureDeviceDisappeared(_ device: AVCaptureDevice) {
        guard DeviceStream.isScreenDevice(device) || connections.contains(where: { $0.captureDevice === device }) else { return }
        log.notice("Screen device disappeared: \(device.localizedName, privacy: .public) \(device.uniqueID, privacy: .public)")
        guard let connection = connections.first(where: { $0.captureDevice === device })
            ?? connections.first(where: { $0.captureDevice?.uniqueID == device.uniqueID }) else { return }
        // The screen device is replaced when its stream starts, and the new one can be announced before the old one
        // goes: if it's still there, carry on with it.
        if let current = DeviceStream.screenDevices().first(where: { $0.uniqueID == device.uniqueID }), current.isConnected {
            log.notice("…still present; reattaching")
            connection.attachCapture(current)
            return
        }
        if connection.muxID == nil {
            remove(connection)
        } else {
            connection.detachCapture()
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.attachUnclaimedScreens()
        }
    }

    private func attachUnclaimedScreens() {
        for device in DeviceStream.screenDevices() where !connections.contains(where: { $0.captureDevice?.uniqueID == device.uniqueID }) {
            captureDeviceAppeared(device)
        }
    }

    private func isPresent(_ device: AVCaptureDevice?) -> Bool {
        guard let device else { return false }
        return DeviceStream.screenDevices().contains { $0.uniqueID == device.uniqueID }
    }

    func identityChanged(_ connection: DeviceConnection) {
        guard connection.muxID != nil, connection.captureDevice == nil, let name = connection.info.deviceName,
              let other = connections.first(where: { $0 !== connection && $0.muxID == nil && $0.captureDevice?.localizedName == name }),
              let device = other.captureDevice else { return }
        log.notice("Joining screen device \(device.uniqueID, privacy: .public) to USB device \(connection.id, privacy: .public)")
        remove(other)
        connection.attachCapture(device)
    }

    private func unmatchedUSBOnlyConnection() -> DeviceConnection? {
        let usbOnly = connections.filter { $0.captureDevice == nil && $0.muxID != nil }
        return usbOnly.count == 1 ? usbOnly[0] : nil
    }

    private func unmatchedCaptureOnlyConnection() -> DeviceConnection? {
        let captureOnly = connections.filter { $0.captureDevice != nil && $0.muxID == nil }
        return captureOnly.count == 1 ? captureOnly[0] : nil
    }

    static func normalise(_ udid: String) -> String { udid.replacingOccurrences(of: "-", with: "").uppercased() }

    // MARK: - Connections

    private func add(id: String) -> DeviceConnection {
        let connection = DeviceConnection(id: id, catalog: catalog)
        connections.append(connection)
        forwarding[id] = connection.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        return connection
    }

    private func remove(_ connection: DeviceConnection) {
        log.notice("Removing \(connection.info.name, privacy: .public)")
        removals[connection.id]?.cancel()
        removals[connection.id] = nil
        connection.disconnect()
        connections.removeAll { $0 === connection }
        forwarding[connection.id] = nil
    }
}
