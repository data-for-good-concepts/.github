import ARKit
import AVFoundation
import CoreImage
import ImageIO

/// Records the camera while scanning, in the same AR session as RoomPlan, so every image
/// lines up with the scanned walls:
/// - video.mp4          the camera feed (HEVC, full sensor resolution)
/// - video-poses.json   camera position and lens data for every video frame
/// - keyframes/*.jpg    sharp still photos at full sensor resolution, taken when the phone has reached a
///                      new viewpoint and is held still
/// - depth/*.png        LiDAR depth for each photo (16-bit, millimetres, 0 = no reading)
/// - confidence/*.png   ARKit's confidence in each depth reading (0 low, 1 medium, 2 high)
/// - keyframes.json     camera position, lens, exposure and file names for every still photo
///
/// Call every method on the main thread. Photo encoding runs on `jpegQueue`; the state it touches
/// (`keyframes`, `sharpnessHistory`) is only used on that queue, so the class is safe to share.
final class FrameRecorder: @unchecked Sendable {
    struct Frame: Codable {
        let file: String?
        let time: Double
        let width: Int
        let height: Int
        /// [fx, fy, cx, cy] in pixels of this image.
        let intrinsics: [Float]
        /// Camera-to-world transform, 16 numbers, column-major (ARKit convention).
        let transform: [Float]
        var depthFile: String? = nil
        var confidenceFile: String? = nil
        /// Seconds the sensor was exposed for this image.
        var exposureDuration: Double? = nil
        /// Exposure compensation ARKit applied, in EV.
        var exposureOffset: Float? = nil
        /// ARKit's light estimate, when available (lumens, ~1000 = neutral; Kelvin).
        var ambientIntensity: Float? = nil
        var colorTemperature: Float? = nil
    }

    struct FrameFile: Encodable {
        let format: String
        let version = 1
        let notes = [
            "transform is the camera-to-world matrix (column-major) in the same world space as house-scene.json.",
            "ARKit camera convention: the camera looks down -Z, +Y is up, +X is right, in the sensor's landscape image orientation.",
            "Project a world point P: (X, Y, Z) = inverse(transform) * P; u = fx * X / -Z + cx; v = fy * -Y / -Z + cy (pixels, origin top-left).",
            "depthFile: 16-bit PNG, millimetres, 0 = no reading, 256x192 (scale to the image size; same camera). confidenceFile: 8-bit PNG, 0 low, 1 medium, 2 high.",
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
    /// True when a photo from here would fill a gap (LiDAR walk). Then a small move is enough for a new photo.
    var wantsPhoto: ((ARFrame) -> Bool)?
    /// Called on the main thread with the camera and LiDAR depth of each photo saved with depth.
    var onDepthPhoto: ((ARCamera, Plane) -> Void)?
    /// Receives every saved photo's depth, so the screen can show what has been captured.
    var coverage: CoverageMap?
    /// Called on the main thread for a photo without LiDAR depth. Returns work, run on a background
    /// queue, that makes depth for the screen from another source (ARKit's mesh or RoomPlan's room
    /// model). It is never exported: the package only contains real depth.
    var fallbackDepth: ((ARFrame) -> () -> Plane?)?

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

    private static let maxKeyframes = 600
    /// A new photo is wanted after moving this far or turning this much since the last one.
    /// Dense enough for photoreal reconstruction (Gaussian splatting) when combined with the video.
    private static let newViewDistance: Float = 0.3
    private static let newViewAngle: Float = 0.26      // about 15°
    /// Aiming at a gap during the LiDAR walk: a new photo after this small a move.
    private static let gapViewDistance: Float = 0.08
    private static let gapViewAngle: Float = 0.07      // about 4°
    /// "Still" means slower than this, for at least `stillDuration` seconds.
    private static let stillMoveSpeed: Float = 0.2      // m/s
    private static let stillTurnSpeed: Float = 0.3      // rad/s
    private static let stillDuration: TimeInterval = 0.2

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        for sub in ["keyframes", "depth", "confidence"] {
            try FileManager.default.createDirectory(at: folder.appending(path: sub), withIntermediateDirectories: true)
        }
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
            let newView = moved > Self.newViewDistance || turned > Self.newViewAngle
            let fillsGap = (moved > Self.gapViewDistance || turned > Self.gapViewAngle) && (wantsPhoto?(frame) ?? false)
            guard newView || fillsGap else {
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
        let number = String(format: "%04d", nextIndex + 1)
        let name = "keyframes/\(number).jpg"
        let camera = frame.camera
        let intrinsics = camera.intrinsics
        let transform = camera.transform
        let time = frame.timestamp - (startTime ?? frame.timestamp)
        let folder = self.folder

        // Depth buffers are reused by ARKit, so copy them now.
        let depth = frame.sceneDepth.flatMap { Self.copyPlane($0.depthMap) }
        let confidence = frame.sceneDepth?.confidenceMap.flatMap { Self.copyPlane($0) }
        let makeFallbackDepth = depth == nil ? fallbackDepth?(frame) : nil

        var record = Frame(
            file: name, time: time,
            width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
            intrinsics: Self.intrinsics(intrinsics, scale: 1),
            transform: Self.flatten(transform))
        record.exposureDuration = camera.exposureDuration
        record.exposureOffset = camera.exposureOffset
        record.ambientIntensity = frame.lightEstimate.map { Float($0.ambientIntensity) }
        record.colorTemperature = frame.lightEstimate.map { Float($0.ambientColorTemperature) }

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

            // Full sensor resolution, high quality: photoreal reconstruction needs every pixel.
            let options = [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.9]
            guard let data = ciContext.jpegRepresentation(of: CIImage(cvPixelBuffer: buffer),
                                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, options: options),
                  (try? data.write(to: folder.appending(path: name))) != nil else { return }

            if let depth, let png = Self.depthPNG(depth) {
                let depthName = "depth/\(number).png"
                if (try? png.write(to: folder.appending(path: depthName))) != nil {
                    record.depthFile = depthName
                    DispatchQueue.main.async { self.onDepthPhoto?(camera, depth) }
                }
            }
            if let confidence, let png = Self.grayPNG(confidence) {
                let confidenceName = "confidence/\(number).png"
                if (try? png.write(to: folder.appending(path: confidenceName))) != nil { record.confidenceFile = confidenceName }
            }

            if let coverage = self.coverage, let coverageDepth = depth ?? makeFallbackDepth?(),
               let rgba = Self.smallRGBA(buffer, width: coverageDepth.width, height: coverageDepth.height, context: ciContext) {
                coverage.integrate(depth: coverageDepth, confidence: depth != nil ? confidence : nil, rgba: rgba,
                                   intrinsics: record.intrinsics, fullWidth: record.width, transform: transform)
            }

            self.keyframes.append(record)
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

    /// A copy of a single-plane pixel buffer: width, height, bytes per pixel, tightly packed rows.
    struct Plane {
        let width: Int
        let height: Int
        let bytesPerPixel: Int
        let data: Data
    }

    private static func copyPlane(_ buffer: CVPixelBuffer) -> Plane? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bpp: Int
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_DepthFloat32: bpp = 4
        case kCVPixelFormatType_OneComponent8: bpp = 1
        default: return nil
        }
        var data = Data(capacity: width * height * bpp)
        for row in 0..<height {
            data.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width * bpp)
        }
        return Plane(width: width, height: height, bytesPerPixel: bpp, data: data)
    }

    /// The photo shrunk to the depth map's size, as RGBA bytes with the top row first.
    private static func smallRGBA(_ buffer: CVPixelBuffer, width: Int, height: Int, context: CIContext) -> [UInt8]? {
        let full = CIImage(cvPixelBuffer: buffer)
        let small = full.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / full.extent.width,
                                                           y: CGFloat(height) / full.extent.height))
        guard let image = context.createCGImage(small, from: CGRect(x: 0, y: 0, width: width, height: height)) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let bitmap = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                         bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }

    /// Float metres → 16-bit PNG in millimetres (0 = no reading).
    private static func depthPNG(_ plane: Plane) -> Data? {
        guard plane.bytesPerPixel == 4 else { return nil }
        var millimetres = [UInt16](repeating: 0, count: plane.width * plane.height)
        plane.data.withUnsafeBytes { raw in
            let metres = raw.bindMemory(to: Float32.self)
            for i in 0..<millimetres.count {
                let m = metres[i]
                millimetres[i] = m.isFinite && m > 0 ? UInt16(min(m * 1000, 65535)) : 0
            }
        }
        let data = millimetres.withUnsafeBytes { Data($0) }
        return png(data, width: plane.width, height: plane.height, bits: 16,
                   info: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue))
    }

    private static func grayPNG(_ plane: Plane) -> Data? {
        guard plane.bytesPerPixel == 1 else { return nil }
        return png(plane.data, width: plane.width, height: plane.height, bits: 8,
                   info: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))
    }

    private static func png(_ pixels: Data, width: Int, height: Int, bits: Int, info: CGBitmapInfo) -> Data? {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: bits, bitsPerPixel: bits,
                                  bytesPerRow: width * bits / 8, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
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
