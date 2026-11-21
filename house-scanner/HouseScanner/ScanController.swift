import ARKit
import RoomPlan
import SwiftUI

/// Drives the RoomPlan scanner. All rooms are scanned in one AR session, so they share
/// the same coordinate system and line up with each other in the floor plan and 3D model.
///
/// To add rooms to an earlier scan, pass its saved ARWorldMap: ARKit first recognises the
/// place again (relocalisation) and then carries on in the earlier scan's coordinates.
///
/// RoomPlan runs without its own camera view: the screen is a black canvas (`CoverageCanvas`)
/// that shows only what has been fully captured, filling in as you scan.
final class ScanController: NSObject, ObservableObject, RoomCaptureSessionDelegate {
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
    /// Surface fully captured so far, in m².
    @Published var capturedArea: Float = 0
    /// RoomPlan's advice, such as "Move closer to the wall", or nil when all is well.
    @Published var instruction: String?

    let canvas = CoverageCanvas()
    let coverage = CoverageMap()
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

    private(set) lazy var captureSession: RoomCaptureSession = {
        let session = RoomCaptureSession(arSession: arSession)
        session.delegate = self
        return session
    }()

    init(worldMap: ARWorldMap? = nil) {
        self.worldMap = worldMap
        self.isContinuing = worldMap != nil
        self.phase = worldMap == nil ? .idle : .relocalizing
        super.init()
        coverage.onUpdate = { [weak self] chunks, area in
            guard let self else { return }
            self.canvas.apply(chunks)
            self.capturedArea = area
        }
    }

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
        captureSession.run(configuration: RoomCaptureSession.Configuration())
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
        instruction = nil
        // Keep the AR session running so the next room lines up with this one.
        captureSession.stop(pauseARSession: false)
    }

    func shutdown() {
        displayLink?.invalidate()
        displayLink = nil
        recorder?.cancel()
        recorder = nil
        if phase == .scanning {
            captureSession.stop()
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
        canvas.follow(frame.camera)

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
            recorder.coverage = coverage
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

    // MARK: - RoomCaptureSessionDelegate

    func captureSession(_ session: RoomCaptureSession, didProvide instruction: RoomCaptureSession.Instruction) {
        let text: String?
        switch instruction {
        case .moveCloseToWall: text = "Move closer to the wall"
        case .moveAwayFromWall: text = "Move away from the wall"
        case .slowDown: text = "Slow down"
        case .turnOnLight: text = "Turn on more light"
        case .lowTexture: text = "Point at something with more detail"
        case .normal: text = nil
        @unknown default: text = nil
        }
        DispatchQueue.main.async {
            if self.phase == .scanning, text != self.instruction { self.instruction = text }
        }
    }

    /// RoomPlan has the raw data for the room: build the finished room model from it.
    func captureSession(_ session: RoomCaptureSession, didEndWith data: CapturedRoomData, error: Error?) {
        if let error {
            DispatchQueue.main.async { self.roomFailed(error) }
            return
        }
        Task {
            do {
                let room = try await RoomBuilder(options: [.beautifyObjects]).capturedRoom(from: data)
                await MainActor.run {
                    self.rooms.append(room)
                    self.phase = .roomDone
                }
            } catch {
                await MainActor.run { self.roomFailed(error) }
            }
        }
    }

    private func roomFailed(_ error: Error) {
        errorMessage = "This room could not be processed: \(error.localizedDescription)"
        phase = rooms.isEmpty ? .idle : .roomDone
    }
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
