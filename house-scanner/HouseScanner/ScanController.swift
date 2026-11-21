import ARKit
import RoomPlan
import SwiftUI

/// Drives the RoomPlan scanner. All rooms are scanned in one AR session, so they share
/// the same coordinate system and line up with each other in the floor plan and 3D model.
///
/// To add rooms to an earlier scan, pass its saved ARWorldMap: ARKit first recognises the
/// place again (relocalisation) and then carries on in the earlier scan's coordinates.
final class ScanController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    enum Phase {
        case relocalizing // continuing an earlier scan: waiting for ARKit to recognise the place
        case idle         // ready to scan
        case scanning     // the camera is capturing a room
        case processing   // RoomPlan is building the room model
        case roomDone     // a room is finished; scan another or save
    }

    enum CaptureHint: Equatable {
        case none
        case holdStill
        case photoSaved
    }

    @Published var phase: Phase
    @Published var rooms: [CapturedRoom] = []
    @Published var errorMessage: String?
    @Published var captureHint: CaptureHint = .none
    @Published var photoCount = 0
    @Published var relocalizationMessage = "Starting the camera…"
    /// True once ARKit has seen enough of the place for this scan to be continued later.
    @Published var mapIsGoodForContinuing = false
    /// Triangles in ARKit's LiDAR mesh so far (shown so you can see the mesh is being captured).
    @Published var meshFaceCount = 0

    let arSession = ARSession()
    let isContinuing: Bool
    private let worldMap: ARWorldMap?
    private var recorder: FrameRecorder?
    private var displayLink: CADisplayLink?
    private var relocalizedSince: TimeInterval?
    private var photoSavedUntil: TimeInterval = 0
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private var lastMeshCheck: TimeInterval = 0

    private(set) lazy var captureView: RoomCaptureView = {
        let view = RoomCaptureView(frame: .zero, arSession: arSession)
        view.delegate = self
        return view
    }()

    init(worldMap: ARWorldMap? = nil) {
        self.worldMap = worldMap
        self.isContinuing = worldMap != nil
        self.phase = worldMap == nil ? .idle : .relocalizing
        super.init()
    }

    // RoomCaptureViewDelegate requires NSCoding; there is nothing to encode.
    required init?(coder: NSCoder) {
        worldMap = nil
        isContinuing = false
        phase = .idle
        super.init()
    }

    func encode(with coder: NSCoder) {}

    // MARK: - Controls

    /// Called when the scan screen appears.
    func begin() {
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
        haptics.prepare()

        if let worldMap {
            let configuration = ARWorldTrackingConfiguration()
            configuration.initialWorldMap = worldMap
            arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else {
            startRoom()
        }
    }

    func startRoom() {
        guard phase == .idle || phase == .roomDone else { return }
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
        startRecordingIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.ensureLiDARCapture() }
    }

    /// RoomPlan runs the AR session with its own settings. If those don't include ARKit's LiDAR
    /// mesh and per-frame depth, switch them on without resetting tracking, so RoomPlan carries on.
    private func ensureLiDARCapture() {
        guard phase == .scanning,
              let configuration = arSession.configuration as? ARWorldTrackingConfiguration else { return }
        var changed = false
        if configuration.sceneReconstruction.isEmpty,
           ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
            changed = true
        }
        if !configuration.frameSemantics.contains(.sceneDepth),
           ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
            changed = true
        }
        if changed { arSession.run(configuration) }
    }

    /// Keeps the latest version of every mesh piece, including ones RoomPlan may drop between rooms.
    private func collectMesh() {
        for anchor in arSession.currentFrame?.anchors ?? [] {
            if let mesh = anchor as? ARMeshAnchor { meshAnchors[mesh.identifier] = mesh }
        }
        let faces = meshAnchors.values.reduce(0) { $0 + $1.geometry.faces.count }
        if faces != meshFaceCount { meshFaceCount = faces }
    }

    func finishRoom() {
        guard phase == .scanning else { return }
        phase = .processing
        captureHint = .none
        collectMesh()
        // Keep the AR session running so the next room lines up with this one.
        captureView.captureSession.stop(pauseARSession: false)
    }

    func shutdown() {
        displayLink?.invalidate()
        displayLink = nil
        recorder?.cancel()
        recorder = nil
        if phase == .scanning {
            captureView.captureSession.stop()
        }
        arSession.pause()
    }

    // MARK: - Every frame

    @objc private func tick() {
        guard let frame = arSession.currentFrame else { return }

        let mapGood: Bool
        switch frame.worldMappingStatus {
        case .mapped, .extending: mapGood = true
        default: mapGood = false
        }
        if mapGood != mapIsGoodForContinuing { mapIsGoodForContinuing = mapGood }

        if phase == .relocalizing {
            updateRelocalization(frame)
            return
        }

        if frame.timestamp - lastMeshCheck > 1 {
            lastMeshCheck = frame.timestamp
            collectMesh()
        }

        guard let recorder else { return }
        let hint = recorder.process(frame)
        let now = CACurrentMediaTime()
        let wanted: CaptureHint
        if now < photoSavedUntil {
            wanted = .photoSaved
        } else if phase == .scanning, hint == .holdStill {
            wanted = .holdStill
        } else {
            wanted = .none
        }
        if wanted != captureHint { captureHint = wanted }
    }

    private func updateRelocalization(_ frame: ARFrame) {
        let message: String
        switch frame.camera.trackingState {
        case .normal:
            let since = relocalizedSince ?? frame.timestamp
            relocalizedSince = since
            // Require a stable fix for a moment before trusting it.
            if frame.timestamp - since > 1.0 {
                phase = .idle
                haptics.impactOccurred()
                return
            }
            message = "Found it. Hold on…"
        case .limited(.relocalizing):
            relocalizedSince = nil
            message = "Point the camera at a room you already scanned and move slowly around it."
        case .limited(.insufficientFeatures):
            relocalizedSince = nil
            message = "Not enough detail to recognise. Turn on lights or point at furniture."
        case .limited(.excessiveMotion):
            relocalizedSince = nil
            message = "Move more slowly."
        case .limited(.initializing):
            relocalizedSince = nil
            message = "Starting the camera…"
        default:
            relocalizedSince = nil
            message = "Point the camera at a room you already scanned."
        }
        if message != relocalizationMessage { relocalizationMessage = message }
    }

    // MARK: - Video and photo recording

    /// Records from the first room until the scan is saved, including walking between rooms.
    private func startRecordingIfNeeded() {
        guard recorder == nil else { return }
        do {
            let recorder = try FrameRecorder()
            recorder.onPhotoSaved = { [weak self] in
                guard let self else { return }
                self.photoCount += 1
                self.photoSavedUntil = CACurrentMediaTime() + 0.7
                self.captureHint = .photoSaved
                self.haptics.impactOccurred()
            }
            self.recorder = recorder
        } catch {
            print("Camera recording unavailable: \(error)")
        }
    }

    /// Stops recording and returns the folder with the video and photos, if anything was recorded.
    func finishRecording() async -> URL? {
        displayLink?.invalidate()
        displayLink = nil
        guard let recorder else { return nil }
        self.recorder = nil
        collectMesh()
        let folder = await recorder.finish()
        if !meshAnchors.isEmpty {
            do {
                try MeshExporter.writePLY(anchors: Array(meshAnchors.values), to: folder.appending(path: "mesh.ply"))
            } catch {
                print("Could not save the LiDAR mesh: \(error)")
            }
        }
        return folder
    }

    /// ARKit's map of the place, saved so this scan can be continued later.
    func currentWorldMap() async -> ARWorldMap? {
        await withCheckedContinuation { (done: CheckedContinuation<ARWorldMap?, Never>) in
            arSession.getCurrentWorldMap { map, _ in done.resume(returning: map) }
        }
    }

    // MARK: - RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        DispatchQueue.main.async {
            if let error {
                self.errorMessage = "This room could not be processed: \(error.localizedDescription)"
                self.phase = self.rooms.isEmpty ? .idle : .roomDone
            } else {
                self.rooms.append(processedResult)
                self.phase = .roomDone
            }
        }
    }
}

/// Puts Apple's RoomCaptureView (camera + live 3D outline + coaching) into SwiftUI.
struct RoomCaptureViewRepresentable: UIViewRepresentable {
    let controller: ScanController

    func makeUIView(context: Context) -> RoomCaptureView {
        controller.captureView
    }

    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}

/// Plain camera view, used while ARKit recognises the place before RoomPlan starts.
struct CameraPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        view.automaticallyUpdatesLighting = false
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
