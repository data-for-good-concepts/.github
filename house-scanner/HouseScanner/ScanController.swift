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
    /// Whether RoomPlan's session delivers LiDAR depth per frame and a mesh (shown while testing).
    @Published var lidarStatus = ""

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
    /// RoomPlan's model of the finished rooms plus the one being scanned, used to fill the canvas.
    private var roomDepth = RoomDepth(rooms: [])
    private var lastPosition: SIMD3<Float>?

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
        // Nobody touches the screen while scanning: don't let the phone lock and interrupt tracking.
        UIApplication.shared.isIdleTimerDisabled = true

        if let worldMap {
            let configuration = Self.lidarConfiguration()
            configuration.initialWorldMap = worldMap
            arSession.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        } else {
            startRoom()
        }
    }

    func startRoom() {
        guard phase == .idle || phase == .roomDone else { return }
        // Start the session with ARKit's mesh switched on before RoomPlan takes it over: RoomPlan
        // keeps the mesh running (it drops per-frame depth). Between rooms the session already runs
        // `lidarConfiguration` (see `startLiDARWalk`), and after relocalising it was started with it.
        if arSession.configuration == nil {
            arSession.run(Self.lidarConfiguration())
        }
        print("[HouseScanner] RoomPlan starting room \(rooms.count + 1) at \(Self.position(arSession.currentFrame))")
        captureSession.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
        startRecordingIfNeeded()
    }

    /// ARKit with LiDAR depth per frame and the labelled mesh.
    private static func lidarConfiguration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        }
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }
        return configuration
    }

    /// After each room RoomPlan isn't running, so the app takes the session over with LiDAR depth and
    /// mesh, keeping tracking and the world origin so everything stays in the same coordinates.
    /// Photos taken now (the "LiDAR walk") are saved with real depth and confidence maps.
    private func startLiDARWalk() {
        print("[HouseScanner] LiDAR walk starting at \(Self.position(arSession.currentFrame))")
        arSession.run(Self.lidarConfiguration())
    }

    private static func position(_ frame: ARFrame?) -> String {
        guard let t = frame?.camera.transform else { return "(no frame)" }
        return String(format: "(%.2f, %.2f, %.2f)", t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }

    /// What the session provides, for the status chip. The app must not change RoomPlan's session
    /// settings while it scans: that makes RoomPlan stop with "World tracking failure".
    private func updateLiDARStatus(_ frame: ARFrame) {
        let depth = frame.sceneDepth != nil || frame.smoothedSceneDepth != nil
        // RoomPlan switches on a reconstruction mode of its own, but that gives the app no mesh
        // anchors: only count the mesh as on when there really is one.
        let mesh = frame.anchors.contains { $0 is ARMeshAnchor }
        let status = phase == .scanning
            ? "Room scan · mesh \(mesh ? "✓" : "✗") · \(roomDepth.count) surfaces"
            : "LiDAR walk · depth \(depth ? "✓" : "✗") · mesh \(mesh ? "✓" : "✗")"
        if status != lidarStatus { lidarStatus = status }
    }

    /// A 256×192 depth map made by projecting the LiDAR mesh's vertices into the camera
    /// (nearest vertex wins). Used for the black canvas when RoomPlan's session gives no depth.
    private static func depthFromMesh(_ anchors: [ARMeshAnchor], camera: ARCamera) -> FrameRecorder.Plane? {
        guard !anchors.isEmpty else { return nil }
        let width = 256, height = 192
        let scale = Float(width) / Float(camera.imageResolution.width)
        let k = camera.intrinsics
        let fx = k.columns.0.x * scale, fy = k.columns.1.y * scale
        let cx = k.columns.2.x * scale, cy = k.columns.2.y * scale
        let worldToCamera = camera.transform.inverse
        var depth = [Float32](repeating: 0, count: width * height)
        for anchor in anchors {
            let toCamera = worldToCamera * anchor.transform
            let vertices = anchor.geometry.vertices
            let base = vertices.buffer.contents().advanced(by: vertices.offset)
            for i in 0..<vertices.count {
                let p = base.advanced(by: i * vertices.stride).assumingMemoryBound(to: Float.self)
                let c = toCamera * simd_float4(p[0], p[1], p[2], 1)
                let d = -c.z
                guard d > 0.1 else { continue }
                let u = Int(fx * c.x / d + cx), v = Int(fy * -c.y / d + cy)
                guard u >= 0, u < width, v >= 0, v < height else { continue }
                let index = v * width + u
                if depth[index] == 0 || d < depth[index] { depth[index] = d }
            }
        }
        let data = depth.withUnsafeBytes { Data($0) }
        return FrameRecorder.Plane(width: width, height: height, bytesPerPixel: 4, data: data)
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
        UIApplication.shared.isIdleTimerDisabled = false
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
        #if DEBUG
        let p = SIMD3<Float>(frame.camera.transform.columns.3.x, frame.camera.transform.columns.3.y, frame.camera.transform.columns.3.z)
        if let last = lastPosition, simd_distance(p, last) > 0.3 {
            print("[HouseScanner] JUMP \(String(format: "%.2f", simd_distance(p, last))) m in one frame, phase=\(phase)")
        }
        lastPosition = p
        #endif

        if frame.timestamp - lastMeshCheck > 1 {
            lastMeshCheck = frame.timestamp
            collectMesh()
            if phase == .scanning || phase == .roomDone { updateLiDARStatus(frame) }
            logDiagnostics(frame)
        }

        guard let recorder else { return }
        let hint = recorder.process(frame)
        let now = CACurrentMediaTime()
        let wanted: CaptureHint
        if now < photoSavedUntil {
            wanted = .photoSaved
        } else if phase == .scanning || phase == .roomDone, hint == .holdStill {
            wanted = .holdStill
        } else {
            wanted = .none
        }
        if wanted != captureHint { captureHint = wanted }
    }

    /// Debug builds: one line per second in the device console (Xcode or `devicectl … --console`) for testing.
    private func logDiagnostics(_ frame: ARFrame) {
        #if DEBUG
        let tracking: String
        switch frame.camera.trackingState {
        case .normal: tracking = "normal"
        case .notAvailable: tracking = "notAvailable"
        case .limited(let reason): tracking = "limited(\(reason))"
        }
        let configuration = arSession.configuration as? ARWorldTrackingConfiguration
        print("[HouseScanner] phase=\(phase) tracking=\(tracking) \(lidarStatus.isEmpty ? "status=-" : lidarStatus)"
              + " sceneDepth=\(frame.sceneDepth != nil) reconstruction=\(configuration?.sceneReconstruction.rawValue ?? 0)"
              + " semantics=\(configuration?.frameSemantics.rawValue ?? 0)"
              + " photos=\(photoCount) meshFaces=\(meshFaceCount) area=\(String(format: "%.2f", capturedArea))m²"
              + " recorder=\(recorder != nil)")
        #endif
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
            recorder.fallbackDepth = { [weak self] frame in
                let room = self?.roomDepth ?? RoomDepth(rooms: [])
                let mesh = frame.anchors.compactMap { $0 as? ARMeshAnchor }
                let camera = frame.camera
                return { Self.depthFromMesh(mesh, camera: camera) ?? room.depthMap(for: camera) }
            }
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

    /// RoomPlan's model of the room so far: the canvas is filled in from it.
    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        DispatchQueue.main.async {
            guard self.phase == .scanning else { return }
            self.roomDepth = RoomDepth(rooms: self.rooms + [room])
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
                    self.roomDepth = RoomDepth(rooms: self.rooms)
                    self.phase = .roomDone
                    self.startLiDARWalk()
                }
            } catch {
                await MainActor.run { self.roomFailed(error) }
            }
        }
    }

    private func roomFailed(_ error: Error) {
        print("[HouseScanner] room failed: \(error)")
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
