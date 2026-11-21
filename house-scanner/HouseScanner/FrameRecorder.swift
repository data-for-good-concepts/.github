import ARKit
import AVFoundation
import CoreImage

/// Records the camera while scanning, in the same AR session as RoomPlan, so every image
/// lines up with the scanned walls:
/// - video.mp4          the camera feed (HEVC, full sensor resolution)
/// - video-poses.json   camera position and lens data for every video frame
/// - keyframes/*.jpg    sharp still photos, taken when the phone has reached a new viewpoint and is held still
/// - keyframes.json     camera position and lens data for every still photo (used for textures)
///
/// Call every method on the main thread.
final class FrameRecorder {
    struct Frame: Codable {
        let file: String?
        let time: Double
        let width: Int
        let height: Int
        /// [fx, fy, cx, cy] in pixels of this image.
        let intrinsics: [Float]
        /// Camera-to-world transform, 16 numbers, column-major (ARKit convention).
        let transform: [Float]
    }

    struct FrameFile: Encodable {
        let format: String
        let version = 1
        let notes = [
            "transform is the camera-to-world matrix (column-major) in the same world space as house-scene.json.",
            "ARKit camera convention: the camera looks down -Z, +Y is up, +X is right, in the sensor's landscape image orientation.",
            "Project a world point P: (X, Y, Z) = inverse(transform) * P; u = fx * X / -Z + cx; v = fy * -Y / -Z + cy (pixels, origin top-left).",
        ]
        let frames: [Frame]
    }

    struct StoredFrames: Decodable {
        let frames: [Frame]
    }

    /// What the person should do right now.
    enum Hint {
        case none       // nothing needed
        case holdStill  // a new viewpoint needs a photo: hold the phone still
    }

    let folder: URL
    /// Called on the main thread each time a sharp photo has been saved.
    var onPhotoSaved: (() -> Void)?

    // Video
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: TimeInterval?
    private var lastFrameTime: TimeInterval = -1
    private var lastHint: Hint = .none
    private var videoPoses: [Frame] = []

    // Still photos
    private var previousTransform: simd_float4x4?
    private var lastKeyTransform: simd_float4x4?
    private var stillSince: TimeInterval?
    private var nextIndex = 0
    private var savedCount = 0
    private var encodingKeyframe = false
    private var keyframes: [Frame] = []        // only touched on jpegQueue
    private var sharpnessHistory: [Float] = [] // only touched on jpegQueue
    private let jpegQueue = DispatchQueue(label: "house-scanner.keyframes", qos: .userInitiated)
    private let ciContext = CIContext()

    private static let keyframeWidth: CGFloat = 960
    private static let maxKeyframes = 500
    /// A new photo is wanted after moving this far or turning this much since the last one.
    private static let newViewDistance: Float = 0.45
    private static let newViewAngle: Float = 0.35      // about 20°
    /// "Still" means slower than this, for at least `stillDuration` seconds.
    private static let stillMoveSpeed: Float = 0.2      // m/s
    private static let stillTurnSpeed: Float = 0.3      // rad/s
    private static let stillDuration: TimeInterval = 0.2

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "keyframes"), withIntermediateDirectories: true)
    }

    // MARK: - Per frame

    /// Records the frame and returns what the person should do.
    func process(_ frame: ARFrame) -> Hint {
        guard frame.timestamp != lastFrameTime else { return lastHint }
        let dt = lastFrameTime < 0 ? 0 : frame.timestamp - lastFrameTime
        lastFrameTime = frame.timestamp
        let transform = frame.camera.transform
        let previous = previousTransform
        previousTransform = transform

        appendVideoFrame(frame)
        lastHint = photoHint(frame, transform: transform, previous: previous, dt: dt)
        return lastHint
    }

    private func photoHint(_ frame: ARFrame, transform: simd_float4x4, previous: simd_float4x4?, dt: TimeInterval) -> Hint {
        guard case .normal = frame.camera.trackingState, nextIndex < Self.maxKeyframes else {
            stillSince = nil
            return .none
        }

        // Has the phone reached a viewpoint we don't have a photo of yet?
        if let last = lastKeyTransform {
            let moved = simd_distance(transform.columns.3, last.columns.3)
            let turned = angle(between: transform, and: last)
            guard moved > Self.newViewDistance || turned > Self.newViewAngle else {
                stillSince = nil
                return .none
            }
        }

        // Is it being held still?
        var still = true
        if let previous, dt > 0 {
            let turnSpeed = angle(between: transform, and: previous) / Float(dt)
            let moveSpeed = simd_distance(transform.columns.3, previous.columns.3) / Float(dt)
            still = turnSpeed < Self.stillTurnSpeed && moveSpeed < Self.stillMoveSpeed
        }
        if still {
            let since = stillSince ?? frame.timestamp
            stillSince = since
            if frame.timestamp - since >= Self.stillDuration, !encodingKeyframe {
                saveKeyframe(frame)
            }
        } else {
            stillSince = nil
        }
        return .holdStill
    }

    private func appendVideoFrame(_ frame: ARFrame) {
        let buffer = frame.capturedImage
        if writer == nil { setUpWriter(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) }
        guard let writer, let input, let adaptor, writer.status == .writing, input.isReadyForMoreMediaData else { return }

        let start = startTime ?? frame.timestamp
        startTime = start
        let time = frame.timestamp - start
        guard adaptor.append(buffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 600)) else { return }

        videoPoses.append(Frame(
            file: nil, time: time,
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            intrinsics: Self.intrinsics(frame.camera.intrinsics, scale: 1),
            transform: Self.flatten(frame.camera.transform)))
    }

    private func setUpWriter(width: Int, height: Int) {
        do {
            let writer = try AVAssetWriter(outputURL: folder.appending(path: "video.mp4"), fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
            input.expectsMediaDataInRealTime = true
            // The sensor image is landscape; rotate so the video plays upright for a phone held in portrait.
            input.transform = CGAffineTransform(rotationAngle: .pi / 2)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
            guard writer.canAdd(input) else { return }
            writer.add(input)
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: .zero)
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
        } catch {
            print("Video recording unavailable: \(error)")
        }
    }

    private func saveKeyframe(_ frame: ARFrame) {
        encodingKeyframe = true
        let buffer = frame.capturedImage
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(buffer))
        let scale = Self.keyframeWidth / sourceWidth
        let name = String(format: "keyframes/%04d.jpg", nextIndex + 1)
        let intrinsics = frame.camera.intrinsics
        let transform = frame.camera.transform
        let time = frame.timestamp - (startTime ?? frame.timestamp)
        let url = folder.appending(path: name)

        jpegQueue.async { [ciContext] in
            var saved = false
            defer {
                DispatchQueue.main.async {
                    self.encodingKeyframe = false
                    if saved {
                        self.nextIndex += 1
                        self.savedCount += 1
                        self.lastKeyTransform = transform
                        self.stillSince = nil
                        self.onPhotoSaved?()
                    }
                }
            }

            // Reject photos that are noticeably blurrier than the recent ones.
            let sharpness = Self.sharpness(buffer)
            let recent = self.sharpnessHistory.suffix(30).sorted()
            self.sharpnessHistory.append(sharpness)
            if recent.count >= 5, sharpness < recent[recent.count / 2] * 0.55 { return }

            let image = CIImage(cvPixelBuffer: buffer)
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            let extent = image.extent.integral
            let cropped = image.cropped(to: extent).transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.82]
            guard let data = ciContext.jpegRepresentation(of: cropped, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: options),
                  (try? data.write(to: url)) != nil else { return }

            let realScale = Float(extent.width / sourceWidth)
            self.keyframes.append(Frame(
                file: name, time: time,
                width: Int(extent.width), height: Int(extent.height),
                intrinsics: Self.intrinsics(intrinsics, scale: realScale),
                transform: Self.flatten(transform)))
            saved = true
        }
    }

    // MARK: - Finish

    /// Stops recording and writes the JSON files. Returns the folder with everything in it.
    func finish() async -> URL {
        if let writer, let input, writer.status == .writing {
            input.markAsFinished()
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                writer.finishWriting { done.resume() }
            }
        }
        let encoder = JSONEncoder()
        let poses = FrameFile(format: "house-scanner-video-poses", frames: videoPoses)
        try? encoder.encode(poses).write(to: folder.appending(path: "video-poses.json"))

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            jpegQueue.async {
                let file = FrameFile(format: "house-scanner-keyframes", frames: self.keyframes)
                try? encoder.encode(file).write(to: self.folder.appending(path: "keyframes.json"))
                done.resume()
            }
        }
        return folder
    }

    func cancel() {
        writer?.cancelWriting()
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Helpers

    private func angle(between a: simd_float4x4, and b: simd_float4x4) -> Float {
        let fa = simd_normalize(simd_make_float3(a.columns.2))
        let fb = simd_normalize(simd_make_float3(b.columns.2))
        return acos(min(1, max(-1, simd_dot(fa, fb))))
    }

    /// Variance of the Laplacian over the centre of the brightness plane: higher means sharper.
    private static func sharpness(_ buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return 0 }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let p = base.assumingMemoryBound(to: UInt8.self)

        var sum: Float = 0, sumSquares: Float = 0, count: Float = 0
        var y = height / 8
        while y < height - height / 8 {
            var x = width / 8
            while x < width - width / 8 {
                let i = y * stride + x
                let lap = 4 * Float(p[i]) - Float(p[i - 1]) - Float(p[i + 1]) - Float(p[i - stride]) - Float(p[i + stride])
                sum += lap
                sumSquares += lap * lap
                count += 1
                x += 4
            }
            y += 4
        }
        guard count > 0 else { return 0 }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }

    private static func intrinsics(_ k: simd_float3x3, scale: Float) -> [Float] {
        [k.columns.0.x * scale, k.columns.1.y * scale, k.columns.2.x * scale, k.columns.2.y * scale]
    }

    private static func flatten(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}
