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
    }

    func finishRoom() {
        guard phase == .scanning else { return }
        phase = .processing
        // Keep the AR session running so the next room lines up with this one.
        captureView.captureSession.stop(pauseARSession: false)
    }

    func shutdown() {
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
