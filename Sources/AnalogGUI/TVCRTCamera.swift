import Foundation
import SwiftUI
@preconcurrency import AVFoundation
import CoreVideo

extension Notification.Name {
    static let crtCameraFrameReady = Notification.Name("AnaLine.CRTCameraFrameReady")
}

/// Only the newest local frame is retained. No file, recording output or audio
/// input is created. Core Video buffers are immutable after delivery.
final class TVCRTCameraFrames: @unchecked Sendable {
    struct Frame: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let serial: UInt64
        let time: Double
    }
    private let lock = NSLock()
    private var frame: Frame?
    private var serial: UInt64 = 0
    func publish(_ buffer: CVPixelBuffer, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        serial &+= 1; frame = Frame(buffer: buffer, serial: serial, time: now)
    }
    func latest(now: Double = ProcessInfo.processInfo.systemUptime) -> Frame? {
        lock.lock(); defer { lock.unlock() }
        guard let frame, now >= frame.time, now - frame.time < 1 else { return nil }
        return frame
    }
    func clear() { lock.lock(); frame = nil; lock.unlock() }
}

/// Session configuration and callbacks all belong to this serial queue. Only
/// the lock-protected frame slot crosses to the main/Metal rendering thread.
private final class TVCRTCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let frames = TVCRTCameraFrames()
    private let queue = DispatchQueue(label: "AnaLine.CRTCamera", qos: .userInitiated)
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var observers: [NSObjectProtocol] = []
    private var lastFrame = -Double.infinity
    private let onFrame: @Sendable () -> Void
    private let onError: @Sendable (Int) -> Void

    init(onFrame: @escaping @Sendable () -> Void, onError: @escaping @Sendable (Int) -> Void) {
        self.onFrame = onFrame; self.onError = onError
    }
    func start(requestID: Int) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    stopOnQueue()
                    // Prefer the actual built-in camera over virtual cameras.
                    let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                        mediaType: .video, position: .unspecified).devices.first
                    guard let camera = builtIn ?? AVCaptureDevice.default(for: .video) else {
                        throw NSError(domain: "AnaLine.CRTCamera", code: 1)
                    }
                    let capture = AVCaptureSession()
                    capture.beginConfiguration()
                    if capture.canSetSessionPreset(.vga640x480) { capture.sessionPreset = .vga640x480 }
                    else if capture.canSetSessionPreset(.low) { capture.sessionPreset = .low }
                    let input = try AVCaptureDeviceInput(device: camera)
                    let video = AVCaptureVideoDataOutput()
                    video.alwaysDiscardsLateVideoFrames = true
                    video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferMetalCompatibilityKey as String: true]
                    guard capture.canAddInput(input), capture.canAddOutput(video) else {
                        capture.commitConfiguration()
                        throw NSError(domain: "AnaLine.CRTCamera", code: 2)
                    }
                    capture.addInput(input); capture.addOutput(video)
                    video.setSampleBufferDelegate(self, queue: queue)
                    if let connection = video.connection(with: .video), connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
                    }
                    capture.commitConfiguration()
                    if camera.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 15 && $0.maxFrameRate >= 15 }) {
                        if (try? camera.lockForConfiguration()) != nil {
                            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 15)
                            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 15)
                            camera.unlockForConfiguration()
                        }
                    }
                    session = capture; output = video
                    for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification] {
                        observers.append(NotificationCenter.default.addObserver(forName: name, object: capture, queue: nil) { [weak self] _ in
                            guard let self else { return }
                            self.queue.async { self.frames.clear(); self.onError(requestID) }
                        })
                    }
                    capture.startRunning()
                    guard capture.isRunning else { throw NSError(domain: "AnaLine.CRTCamera", code: 3) }
                    continuation.resume(returning: camera.localizedName)
                } catch { stopOnQueue(); continuation.resume(throwing: error) }
            }
        }
    }
    func stop() {
        frames.clear()
        queue.async { [self] in stopOnQueue() }
    }
    private func stopOnQueue() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        output?.setSampleBufferDelegate(nil, queue: nil)
        session?.stopRunning(); session = nil; output = nil
        lastFrame = -.infinity; frames.clear()
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastFrame >= 1.0 / 16, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now; frames.publish(buffer, now: now); onFrame()
    }
}

/// One capture session shared by any visible CRT outputs. No camera is opened
/// until a user enables its dedicated switch and a CRT view requests frames.
@MainActor
final class TVCRTCameraReflection: ObservableObject {
    static let shared = TVCRTCameraReflection()
    enum Status: Equatable {
        case off, requesting, running, denied, unavailable, packagedAppRequired
        var text: String {
            switch self {
            case .off: return "Camera reflection is off."
            case .requesting: return "Requesting camera access…"
            case .running: return "Camera reflection is live; processed only on this Mac."
            case .denied: return "Camera access denied. Enable it in System Settings → Privacy & Security → Camera."
            case .unavailable: return "Camera unavailable or interrupted. Switch reflection off and on to retry."
            case .packagedAppRequired: return "Run the packaged AnaLine app to enable camera reflection."
            }
        }
    }
    @Published private(set) var status: Status = .off
    @Published private(set) var deviceName = ""
    private var consumers = Set<UUID>()
    private var generation = 0
    private var request: Task<Void, Never>?
    private lazy var capture: TVCRTCapture = TVCRTCapture(onFrame: {
        Task { @MainActor in NotificationCenter.default.post(name: .crtCameraFrameReady, object: nil) }
    }, onError: { [weak self] requestID in
        Task { @MainActor [weak self] in
            guard let self, self.generation == requestID, !self.consumers.isEmpty else { return }
            self.generation += 1; self.request?.cancel(); self.request = nil
            self.status = .unavailable; self.capture.stop()
            NotificationCenter.default.post(name: .crtCameraFrameReady, object: nil)
        }
    })
    var latestFrame: TVCRTCameraFrames.Frame? { status == .running ? capture.frames.latest() : nil }

    func setConsumer(_ id: UUID, active: Bool) {
        let wasEmpty = consumers.isEmpty
        if active { guard consumers.insert(id).inserted else { return } }
        else { guard consumers.remove(id) != nil else { return } }
        if consumers.isEmpty {
            generation += 1; request?.cancel(); request = nil
            capture.stop(); status = .off; deviceName = ""
            NotificationCenter.default.post(name: .crtCameraFrameReady, object: nil)
        } else if wasEmpty { start() }
    }
    private func start() {
        generation += 1; let token = generation
        // A SwiftPM executable/test runner has no camera usage description;
        // requesting TCC access there would terminate the process.
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            status = .packagedAppRequired; return
        }
        status = .requesting
        request = Task { [weak self] in
            guard let self else { return }
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
            default: granted = false
            }
            guard token == self.generation, !Task.isCancelled else { return }
            guard granted else { self.status = .denied; return }
            do {
                let name = try await self.capture.start(requestID: token)
                guard token == self.generation, !Task.isCancelled else { return }
                self.deviceName = name; self.status = .running
            } catch {
                guard token == self.generation else { return }
                self.status = .unavailable
            }
            NotificationCenter.default.post(name: .crtCameraFrameReady, object: nil)
        }
    }
}
