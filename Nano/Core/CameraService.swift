@preconcurrency import AVFoundation
import AppKit
import Foundation
import SwiftUI

enum CameraAvailability: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
    case unavailable
}

struct CameraDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

@MainActor
final class CameraService: ObservableObject {
    @Published private(set) var availability: CameraAvailability = .notDetermined
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var devices: [CameraDevice] = []
    @Published private(set) var selectedDeviceID: String?

    let session: AVCaptureSession
    let previewLayer: AVCaptureVideoPreviewLayer
    private let worker: CameraSessionWorker
    private var isModuleOpen = false
    /// The camera the session is really running, which can trail the choice
    /// after a failed switch or a reopen.
    private var activeDeviceID: String?
    private nonisolated(unsafe) var runtimeErrorObserver: NSObjectProtocol?

    init() {
        let worker = CameraSessionWorker()
        self.worker = worker
        self.session = worker.session
        self.previewLayer = AVCaptureVideoPreviewLayer(session: worker.session)
        previewLayer.videoGravity = .resizeAspectFill
        updateAuthorization()
        observeRuntimeErrors()
    }

    deinit {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
    }

    func activate() {
        isModuleOpen = true
        updateAuthorization()
        refreshDevices()
        switch availability {
        case .authorized:
            start()
        case .notDetermined, .denied, .restricted, .unavailable:
            break
        }
    }

    func requestAccess() {
        guard availability == .notDetermined else {
            if isModuleOpen { activate() } else { updateAuthorization() }
            return
        }

        errorMessage = nil
        Task {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            updateAuthorization()
            if granted {
                if isModuleOpen { start() }
            } else {
                errorMessage = "Camera access was not granted."
            }
        }
    }

    func deactivate() {
        isModuleOpen = false
        activeDeviceID = nil
        worker.stop { [weak self] in
            Task { @MainActor in
                self?.isRunning = false
            }
        }
    }

    private func start() {
        errorMessage = nil
        // Reopen with the camera that was picked, not the system default.
        let stillThere = devices.contains { $0.id == selectedDeviceID }
        let deviceID = stillThere ? selectedDeviceID : nil
        worker.start(deviceID: deviceID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(activeID):
                    self.activeDeviceID = activeID
                    self.isRunning = true
                    self.errorMessage = nil
                case let .failure(error):
                    self.activeDeviceID = nil
                    self.isRunning = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func select(_ device: CameraDevice) {
        // Picking the checked camera still switches when the session is on another one.
        guard device.id != selectedDeviceID || device.id != activeDeviceID else { return }
        selectedDeviceID = device.id
        errorMessage = nil

        worker.select(deviceID: device.id) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case let .success(activeID):
                    self.activeDeviceID = activeID
                    self.isRunning = true
                    self.errorMessage = nil
                case let .failure(error):
                    self.activeDeviceID = nil
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func refreshDevices() {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera,
                .deskViewCamera,
            ],
            mediaType: .video,
            position: .unspecified
        ).devices

        devices = discovered.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }

        if selectedDeviceID == nil || !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = AVCaptureDevice.default(for: .video)?.uniqueID ?? devices.first?.id
        }
    }

    private func observeRuntimeErrors() {
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
                .localizedDescription
            Task { @MainActor in
                self?.handleRuntimeError(message)
            }
        }
    }

    private func handleRuntimeError(_ message: String?) {
        isRunning = false
        errorMessage = message ?? "The camera stopped unexpectedly."
        activeDeviceID = nil
        // The session's inputs are no longer usable; force a rebuild on next start.
        worker.invalidateConfiguration()
    }

    private func updateAuthorization() {
        availability = switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized:
            AVCaptureDevice.default(for: .video) == nil ? .unavailable : .authorized
        @unknown default: .unavailable
        }
    }
}

private final class CameraSessionWorker: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.nanoapp.camera-session", qos: .userInitiated)
    private var isConfigured = false
    /// The camera behind the session's input, set by `configure`.
    private var configuredDeviceID: String?

    /// Both completions report the camera the session ended up on.
    func start(
        deviceID: String?,
        completion: @escaping @Sendable (Result<String?, Error>) -> Void
    ) {
        queue.async { [self] in
            do {
                if !isConfigured {
                    try configure(deviceID: deviceID)
                }
                guard !session.isRunning else {
                    completion(.success(configuredDeviceID))
                    return
                }
                session.startRunning()
                completion(.success(configuredDeviceID))
            } catch {
                completion(.failure(error))
            }
        }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
            // Stopping tears down the capture graph behind the input, so the
            // next start has to attach a fresh one rather than reuse this port.
            isConfigured = false
            completion()
        }
    }

    func invalidateConfiguration() {
        queue.async { [self] in
            isConfigured = false
        }
    }

    func select(
        deviceID: String,
        completion: @escaping @Sendable (Result<String?, Error>) -> Void
    ) {
        queue.async { [self] in
            do {
                try configure(deviceID: deviceID)
                if !session.isRunning {
                    session.startRunning()
                }
                completion(.success(configuredDeviceID))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private func configure(deviceID: String? = nil) throws {
        let device: AVCaptureDevice?
        if let deviceID {
            device = AVCaptureDevice(uniqueID: deviceID) ?? AVCaptureDevice.default(for: .video)
        } else {
            device = AVCaptureDevice.default(for: .video)
        }

        guard let device else { throw CameraSessionError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for input in session.inputs {
            session.removeInput(input)
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraSessionError.cannotAddInput
        }
        session.addInput(input)
        applyLandscapeFormat(to: device)
        configuredDeviceID = device.uniqueID
        isConfigured = true
    }

    /// Some cameras advertise portrait formats alongside landscape ones and let
    /// the session preset pick. The Osmo Action, for one, answers a portrait
    /// request by letterboxing its landscape image into the taller frame, which
    /// shows up as black bars in the preview. Pin a landscape format instead.
    private func applyLandscapeFormat(to device: AVCaptureDevice) {
        func width(_ format: AVCaptureDevice.Format) -> Int32 {
            CMVideoFormatDescriptionGetDimensions(format.formatDescription).width
        }

        let landscape = device.formats.filter {
            let size = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return size.width >= size.height
        }

        // The preview is a few hundred points wide, so 720p is ample.
        guard let best = landscape.min(by: {
            abs(width($0) - 1280) < abs(width($1) - 1280)
        }), best != device.activeFormat else { return }

        do {
            try device.lockForConfiguration()
            // Assigning activeFormat moves the session to .inputPriority.
            device.activeFormat = best
            device.unlockForConfiguration()
        } catch {
            // Keep whatever the session negotiated rather than failing the open.
        }
    }
}

private enum CameraSessionError: LocalizedError {
    case noCamera
    case cannotAddInput

    var errorDescription: String? {
        switch self {
        case .noCamera: "No camera is available."
        case .cannotAddInput: "Nano could not connect to the selected camera."
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeNSView(context: Context) -> CameraPreviewView {
        CameraPreviewView(previewLayer: previewLayer)
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {}
}

final class CameraPreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        // The layer outlives this view, so a plain frame assignment would
        // implicitly animate every time the module reopens at a new size.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}
