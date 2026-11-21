import ARKit
import RoomPlan
import simd

/// Guides the LiDAR walk after a room: which parts of its walls and floor still lack a photo with
/// LiDAR depth, shown as red tiles on the canvas, plus an arrow when none is on screen.
///
/// The room's walls and floor (from RoomPlan) are split into patches of about 1 m. Each patch holds
/// sample points every 25 cm. A sample counts as seen once a photo's LiDAR depth at its pixel
/// matches its distance from the camera. A patch is done when most of its samples are seen, or when
/// several photos aimed at it still can't see it (hidden behind furniture). Main thread only.
final class WalkGuide {
    struct Direction: Equatable {
        /// Clockwise from straight up on the screen, in radians.
        var angle: Double
        /// A missing patch is on screen: no arrow, just the text.
        var inView: Bool
        var text: String
    }

    private struct Patch {
        var corners: [SIMD3<Float>]    // the tile to draw, slightly inset
        var center: SIMD3<Float>
        var samples: [SIMD3<Float>]
        var seen: [Bool]
        var seenCount = 0
        var attempts = 0               // depth photos that looked at it without seeing it
        var done = false
    }

    private static let patchSize: Float = 1.0
    private static let sampleSpacing: Float = 0.25
    private static let doneShare: Float = 0.5
    private static let maxAttempts = 3
    private static let tolerance: Float = 0.15       // metres between expected and measured depth
    static let goodRange: ClosedRange<Float> = 0.5...3.5   // LiDAR depth is best in this range

    private var patches: [Patch] = []

    /// Called with the tiles still missing (id → corners) whenever they change.
    var onTilesChanged: (([Int: [SIMD3<Float>]]) -> Void)?

    var isActive: Bool { !patches.isEmpty }
    var doneCount: Int { patches.filter(\.done).count }
    var totalCount: Int { patches.count }

    // MARK: - Setting up

    /// Starts guiding for this room's walls and floor.
    func start(room: CapturedRoom?) {
        patches = []
        for surface in (room?.walls ?? []) + (room?.floors ?? []) { split(surface) }
        publishTiles()
    }

    func stop() {
        patches = []
        publishTiles()
    }

    private func split(_ surface: CapturedRoom.Surface) {
        let d = surface.dimensions
        let flat = d.x <= d.y && d.x <= d.z ? 0 : (d.y <= d.z ? 1 : 2)
        let (a, b) = flat == 0 ? (1, 2) : (flat == 1 ? (0, 2) : (0, 1))
        let polygon = surface.polygonCorners.map { SIMD2<Float>($0[a], $0[b]) }
        let lengthA = d[a], lengthB = d[b]
        guard lengthA > 0.3, lengthB > 0.3 else { return }
        let countA = max(1, Int((lengthA / Self.patchSize).rounded()))
        let countB = max(1, Int((lengthB / Self.patchSize).rounded()))
        let sizeA = lengthA / Float(countA), sizeB = lengthB / Float(countB)

        func world(_ x: Float, _ y: Float) -> SIMD3<Float> {
            var local = SIMD4<Float>(0, 0, 0, 1)
            local[a] = x
            local[b] = y
            let p = surface.transform * local
            return SIMD3(p.x, p.y, p.z)
        }
        func inside(_ x: Float, _ y: Float) -> Bool {
            polygon.count < 3 || Self.contains(polygon, SIMD2(x, y))
        }

        for i in 0..<countA {
            for j in 0..<countB {
                let x0 = -lengthA / 2 + Float(i) * sizeA, y0 = -lengthB / 2 + Float(j) * sizeB
                var samples: [SIMD3<Float>] = []
                var x = x0 + Self.sampleSpacing / 2
                while x < x0 + sizeA {
                    var y = y0 + Self.sampleSpacing / 2
                    while y < y0 + sizeB {
                        if inside(x, y) { samples.append(world(x, y)) }
                        y += Self.sampleSpacing
                    }
                    x += Self.sampleSpacing
                }
                guard samples.count >= 3 else { continue }   // outside an irregular floor
                let inset: Float = 0.04
                let corners = [world(x0 + inset, y0 + inset), world(x0 + sizeA - inset, y0 + inset),
                               world(x0 + sizeA - inset, y0 + sizeB - inset), world(x0 + inset, y0 + sizeB - inset)]
                patches.append(Patch(corners: corners, center: world(x0 + sizeA / 2, y0 + sizeB / 2),
                                     samples: samples, seen: Array(repeating: false, count: samples.count)))
            }
        }
    }

    private func publishTiles() {
        var tiles: [Int: [SIMD3<Float>]] = [:]
        for (index, patch) in patches.enumerated() where !patch.done { tiles[index] = patch.corners }
        onTilesChanged?(tiles)
    }

    // MARK: - Photos

    /// Marks what this photo's LiDAR depth saw.
    /// - Parameter depth: Float32 metres in the camera image's own (landscape) orientation.
    func markCovered(camera: ARCamera, depth: FrameRecorder.Plane) {
        guard isActive, depth.bytesPerPixel == 4 else { return }
        let w = depth.width, h = depth.height
        let scale = Float(w) / Float(camera.imageResolution.width)
        let k = camera.intrinsics
        let fx = k.columns.0.x * scale, fy = k.columns.1.y * scale
        let cx = k.columns.2.x * scale, cy = k.columns.2.y * scale
        let worldToCamera = camera.transform.inverse
        var changed = false

        depth.data.withUnsafeBytes { raw in
            let metres = raw.bindMemory(to: Float32.self)
            func pixel(_ p: SIMD3<Float>) -> (index: Int, distance: Float)? {
                let c = worldToCamera * SIMD4(p, 1)
                let distance = -c.z
                guard distance > 0.2 else { return nil }
                let u = Int(fx * c.x / distance + cx), v = Int(fy * -c.y / distance + cy)
                guard u >= 0, u < w, v >= 0, v < h else { return nil }
                return (v * w + u, distance)
            }
            for p in patches.indices where !patches[p].done {
                guard let centre = pixel(patches[p].center) else { continue }
                let before = patches[p].seenCount
                for s in patches[p].samples.indices where !patches[p].seen[s] {
                    guard let (index, distance) = pixel(patches[p].samples[s]) else { continue }
                    let measured = metres[index]
                    if measured.isFinite, abs(measured - distance) < Self.tolerance {
                        patches[p].seen[s] = true
                        patches[p].seenCount += 1
                    }
                }
                if Float(patches[p].seenCount) >= Float(patches[p].samples.count) * Self.doneShare {
                    patches[p].done = true
                } else if patches[p].seenCount == before, Self.goodRange.contains(centre.distance) {
                    // Aimed at it from a good distance but nothing new seen: probably hidden.
                    patches[p].attempts += 1
                    if patches[p].attempts >= Self.maxAttempts { patches[p].done = true }
                }
                if patches[p].done { changed = true }
            }
        }
        if changed { publishTiles() }
    }

    /// True when a missing patch is in the middle of the camera's view at a good distance, so a
    /// photo now would fill it in.
    func wantsPhoto(camera: ARCamera) -> Bool {
        guard let distance = nearestInView(camera: camera, inner: 0.7)?.distance else { return false }
        return Self.goodRange.contains(distance)
    }

    // MARK: - Directions

    private func nearestInView(camera: ARCamera, inner: Float) -> (index: Int, distance: Float)? {
        let size = camera.imageResolution
        let worldToCamera = camera.transform.inverse
        var best: (index: Int, distance: Float)?
        for p in patches.indices where !patches[p].done {
            let c = worldToCamera * SIMD4(patches[p].center, 1)
            guard c.z < 0 else { continue }
            let point = camera.projectPoint(patches[p].center, orientation: .landscapeRight, viewportSize: size)
            let mx = size.width * CGFloat(1 - inner) / 2, my = size.height * CGFloat(1 - inner) / 2
            guard point.x > mx, point.x < size.width - mx, point.y > my, point.y < size.height - my else { continue }
            let distance = -c.z
            if best == nil || distance < best!.distance { best = (p, distance) }
        }
        return best
    }

    /// What to do next, or nil when the room is done.
    func direction(camera: ARCamera) -> Direction? {
        guard patches.contains(where: { !$0.done }) else { return nil }

        // A missing tile on screen: the tiles themselves show where; only coach the distance.
        if let visible = nearestInView(camera: camera, inner: 0.9) {
            let text: String
            if visible.distance > Self.goodRange.upperBound { text = "Move closer to the red area" }
            else if visible.distance < Self.goodRange.lowerBound { text = "Step back a little" }
            else { text = "Point at the red area and hold still" }
            return Direction(angle: 0, inView: true, text: text)
        }

        // Otherwise: an arrow to the missing patch that needs the least turning and walking.
        let t = camera.transform
        let eye = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        let forward = -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        var best: (target: SIMD3<Float>, distance: Float)?
        var bestScore = Float.infinity
        for patch in patches where !patch.done {
            let offset = patch.center - eye
            let distance = simd_length(offset)
            guard distance > 0.01 else { continue }
            let turn = acos(max(-1, min(1, simd_dot(offset / distance, forward))))
            let score = turn + 0.3 * distance
            if score < bestScore {
                bestScore = score
                best = (patch.center, distance)
            }
        }
        guard let best else { return nil }
        let distance = String(format: "%.0f m", max(1, best.distance.rounded()))

        // Screen space for the portrait UI: x right, y up, looking down -z.
        let view = camera.viewMatrix(for: .portrait) * SIMD4(best.target, 1)
        if view.z > 0 {
            return Direction(angle: view.x >= 0 ? .pi / 2 : -.pi / 2, inView: false, text: "Turn around · \(distance)")
        }
        let angle = Double(atan2(view.x, view.y))
        let degrees = angle * 180 / .pi
        let text: String
        if abs(degrees) < 45 { text = "Look up" }
        else if abs(degrees) > 135 { text = "Look down" }
        else { text = degrees > 0 ? "Turn right" : "Turn left" }
        return Direction(angle: angle, inView: false, text: "\(text) · \(distance)")
    }

    private static func contains(_ polygon: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}
