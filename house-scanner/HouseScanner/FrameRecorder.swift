import ARKit
import AVFoundation
import CoreImage

/// Records the camera while scanning, in the same AR session as RoomPlan, so every image
/// lines up with the scanned walls:
/// - video.mp4          the camera feed (HEVC, full sensor resolution)
/// - video-poses.json   camera position and lens data for every video frame
/// - keyframes/*.jpg    sharp still frames, taken whenever the phone has moved or turned enough
/// - keyframes.json     camera position and lens data for every still frame (used for textures)
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

    let folder: URL

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: TimeInterval?
    private var lastFrameTime: TimeInterval = -1
    private var videoPoses: [Frame] = []

    private var previousTransform: simd_float4x4?
    private var lastKeyTransform: simd_float4x4?
    private var lastKeyTime: TimeInterval = 0
    private var keyframeCount = 0
    private var encodingKeyframe = false
    private var keyframes: [Frame] = []        // only touched on jpegQueue
    private let jpegQueue = DispatchQueue(label: "house-scanner.keyframes", qos: .userInitiated)
    private let ciContext = CIContext()

    private static let keyframeWidth: CGFloat = 960
    private static let maxKeyframes = 400

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "keyframes"), withIntermediateDirectories: true)
    }

    // MARK: - Per frame

    func process(_ frame: ARFrame) {
        guard frame.timestamp != lastFrameTime else { return }
        let dt = lastFrameTime < 0 ? 0 : frame.timestamp - lastFrameTime
        lastFrameTime = frame.timestamp
        let transform = frame.camera.transform
        defer { previousTransform = transform }

        appendVideoFrame(frame)

        // Keyframes: only while tracking is good and the phone is fairly still (sharp image).
        guard case .normal = frame.camera.trackingState,
              keyframeCount < Self.maxKeyframes,
              !encodingKeyframe else { return }
        if let previous = previousTransform, dt > 0 {
            let turnSpeed = angle(between: transform, and: previous) / Float(dt)
            let moveSpeed = simd_distance(transform.columns.3, previous.columns.3) / Float(dt)
            guard turnSpeed < 0.6, moveSpeed < 0.6 else { return }
        }
        if let last = lastKeyTransform {
            let moved = simd_distance(transform.columns.3, last.columns.3)
            let turned = angle(between: transform, and: last)
            guard frame.timestamp - lastKeyTime > 0.35, moved > 0.3 || turned > 0.26 else { return }
        }
        saveKeyframe(frame)
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
        keyframeCount += 1
        encodingKeyframe = true
        lastKeyTransform = frame.camera.transform
        lastKeyTime = frame.timestamp

        let buffer = frame.capturedImage
        let sourceWidth = CGFloat(CVPixelBufferGetWidth(buffer))
        let scale = Self.keyframeWidth / sourceWidth
        let name = String(format: "keyframes/%04d.jpg", keyframeCount)
        let intrinsics = frame.camera.intrinsics
        let transform = frame.camera.transform
        let time = frame.timestamp - (startTime ?? frame.timestamp)
        let url = folder.appending(path: name)

        jpegQueue.async { [ciContext] in
            let image = CIImage(cvPixelBuffer: buffer)
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            let extent = image.extent.integral
            let cropped = image.cropped(to: extent).transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.82]
            if let data = ciContext.jpegRepresentation(of: cropped, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: options),
               (try? data.write(to: url)) != nil {
                let realScale = Float(extent.width / sourceWidth)
                self.keyframes.append(Frame(
                    file: name, time: time,
                    width: Int(extent.width), height: Int(extent.height),
                    intrinsics: Self.intrinsics(intrinsics, scale: realScale),
                    transform: Self.flatten(transform)))
            }
            DispatchQueue.main.async { self.encodingKeyframe = false }
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

    private static func intrinsics(_ k: simd_float3x3, scale: Float) -> [Float] {
        [k.columns.0.x * scale, k.columns.1.y * scale, k.columns.2.x * scale, k.columns.2.y * scale]
    }

    private static func flatten(_ m: simd_float4x4) -> [Float] {
        [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }
}
