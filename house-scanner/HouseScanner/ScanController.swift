import ARKit
import RoomPlan
import SwiftUI

/// Drives the RoomPlan scanner. All rooms are scanned in one AR session, so they share
/// the same coordinate system and line up with each other in the floor plan and 3D model.
final class ScanController: NSObject, ObservableObject, RoomCaptureViewDelegate {
    enum Phase {
        case idle        // not scanning yet
        case scanning    // the camera is capturing a room
        case processing  // RoomPlan is building the room model
        case roomDone    // a room is finished; scan another or save
    }

    @Published var phase: Phase = .idle
    @Published var rooms: [CapturedRoom] = []
    @Published var errorMessage: String?

    private let arSession = ARSession()
    private var recorder: FrameRecorder?
    private var displayLink: CADisplayLink?

    private(set) lazy var captureView: RoomCaptureView = {
        let view = RoomCaptureView(frame: .zero, arSession: arSession)
        view.delegate = self
        return view
    }()

    override init() {
        super.init()
    }

    // RoomCaptureViewDelegate requires NSCoding; there is nothing to encode.
    required init?(coder: NSCoder) {
        super.init()
    }

    func encode(with coder: NSCoder) {}

    // MARK: - Controls

    func startRoom() {
        guard phase == .idle || phase == .roomDone else { return }
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        phase = .scanning
        startRecordingIfNeeded()
    }

    // MARK: - Video and photo recording

    /// Records from the first room until the scan is saved, including walking between rooms.
    private func startRecordingIfNeeded() {
        guard recorder == nil else { return }
        do {
            recorder = try FrameRecorder()
        } catch {
            print("Camera recording unavailable: \(error)")
            return
        }
        let link = CADisplayLink(target: self, selector: #selector(captureFrame))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func captureFrame() {
        guard let frame = arSession.currentFrame else { return }
        recorder?.process(frame)
    }

    /// Stops recording and returns the folder with the video and photos, if anything was recorded.
    func finishRecording() async -> URL? {
        displayLink?.invalidate()
        displayLink = nil
        guard let recorder else { return nil }
        self.recorder = nil
        return await recorder.finish()
    }

    func finishRoom() {
        guard phase == .scanning else { return }
        phase = .processing
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
