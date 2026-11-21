import Foundation
import simd

/// Keeps track of which parts of the home have been fully captured.
///
/// Every saved photo comes with a LiDAR depth map. Each confident depth reading is turned into a
/// 3D point and dropped into a 3 cm voxel grid, coloured from the photo. A voxel counts as
/// **fully captured** once it has been seen in `requiredViews` different photos (photos are
/// at least 30 cm or 15° apart, so these are different viewpoints). Only fully captured voxels
/// are shown on the scanning screen.
///
/// Voxels are grouped in 1 m chunks so the screen only rebuilds the parts that changed.
/// All work runs on its own serial queue; results reach `onUpdate` on the main thread.
final class CoverageMap: @unchecked Sendable {
    struct Points {
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
    }

    static let voxelSize: Float = 0.03
    static let chunkSize: Float = 1.0
    static let requiredViews: UInt8 = 2
    private static let minDepth: Float = 0.2
    private static let maxDepth: Float = 4.0

    /// Called on the main thread with the chunks that changed and the captured surface in m².
    var onUpdate: (([Int64: Points], Float) -> Void)?

    private struct Voxel {
        var position: SIMD3<Float>
        var color: SIMD3<Float>
        var views: UInt8
        var lastFrame: Int32
    }

    private var voxels: [Int64: Voxel] = [:]
    private var chunks: [Int64: [Int64]] = [:]      // chunk → its fully captured voxels
    private var frameCount: Int32 = 0
    private var capturedCount = 0
    private let queue = DispatchQueue(label: "house-scanner.coverage", qos: .utility)

    /// Adds one photo's depth readings.
    /// - Parameters:
    ///   - depth: Float32 metres, depth-map resolution.
    ///   - confidence: UInt8 per depth pixel (0 low, 1 medium, 2 high), same resolution.
    ///   - rgba: the photo scaled to the depth-map resolution, RGBA8, top row first.
    ///   - intrinsics: [fx, fy, cx, cy] of the full-resolution photo, `fullWidth` pixels wide.
    ///   - transform: camera-to-world (ARKit).
    func integrate(depth: FrameRecorder.Plane, confidence: FrameRecorder.Plane?, rgba: [UInt8],
                   intrinsics: [Float], fullWidth: Int, transform: simd_float4x4) {
        queue.async { self.add(depth, confidence, rgba, intrinsics, fullWidth, transform) }
    }

    private func add(_ depth: FrameRecorder.Plane, _ confidence: FrameRecorder.Plane?, _ rgba: [UInt8],
                     _ intrinsics: [Float], _ fullWidth: Int, _ transform: simd_float4x4) {
        guard depth.bytesPerPixel == 4, intrinsics.count == 4, fullWidth > 0,
              rgba.count == depth.width * depth.height * 4 else { return }
        frameCount += 1
        let frame = frameCount
        let w = depth.width, h = depth.height
        let s = Float(w) / Float(fullWidth)
        let fx = intrinsics[0] * s, fy = intrinsics[1] * s, cx = intrinsics[2] * s, cy = intrinsics[3] * s
        var dirty = Set<Int64>()
        let conf: [UInt8]? = confidence.flatMap { $0.width == w && $0.height == h ? [UInt8]($0.data) : nil }

        depth.data.withUnsafeBytes { raw in
            let metres = raw.bindMemory(to: Float32.self)
            for j in stride(from: 0, to: h, by: 2) {
                for i in stride(from: 0, to: w, by: 2) {
                    let index = j * w + i
                    if let conf, conf[index] < 2 { continue }              // high confidence only
                    let d = metres[index]
                    guard d.isFinite, d > Self.minDepth, d < Self.maxDepth else { continue }
                    let u = Float(i) + 0.5, v = Float(j) + 0.5
                    let local = simd_float4((u - cx) / fx * d, -(v - cy) / fy * d, -d, 1)
                    let world4 = transform * local
                    let p = SIMD3<Float>(world4.x, world4.y, world4.z)
                    let c = SIMD3<Float>(Float(rgba[index * 4]), Float(rgba[index * 4 + 1]), Float(rgba[index * 4 + 2])) / 255

                    let key = Self.key(p, size: Self.voxelSize)
                    var voxel = voxels[key] ?? Voxel(position: p, color: c, views: 0, lastFrame: -1)
                    guard voxel.lastFrame != frame else { continue }      // count each photo once
                    voxel.lastFrame = frame
                    if voxel.views < 255 { voxel.views += 1 }
                    voxel.color += (c - voxel.color) / Float(voxel.views)
                    voxels[key] = voxel

                    if voxel.views == Self.requiredViews {
                        let chunk = Self.key(voxel.position, size: Self.chunkSize)
                        chunks[chunk, default: []].append(key)
                        capturedCount += 1
                        dirty.insert(chunk)
                    } else if voxel.views > Self.requiredViews {
                        dirty.insert(Self.key(voxel.position, size: Self.chunkSize))  // colour refined
                    }
                }
            }
        }

        guard !dirty.isEmpty else { return }
        var changed: [Int64: Points] = [:]
        for chunk in dirty {
            var points = Points()
            for key in chunks[chunk] ?? [] {
                guard let voxel = voxels[key] else { continue }
                points.positions.append(voxel.position)
                points.colors.append(voxel.color)
            }
            changed[chunk] = points
        }
        let area = Float(capturedCount) * Self.voxelSize * Self.voxelSize
        DispatchQueue.main.async { self.onUpdate?(changed, area) }
    }

    /// Packs a grid cell into one integer (21 bits per axis).
    private static func key(_ p: SIMD3<Float>, size: Float) -> Int64 {
        let offset: Int64 = 1 << 20
        let x = Int64((p.x / size).rounded(.down)) + offset
        let y = Int64((p.y / size).rounded(.down)) + offset
        let z = Int64((p.z / size).rounded(.down)) + offset
        return (x & 0x1FFFFF) | ((y & 0x1FFFFF) << 21) | ((z & 0x1FFFFF) << 42)
    }
}
