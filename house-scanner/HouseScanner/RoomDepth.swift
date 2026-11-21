import ARKit
import RoomPlan
import simd

/// Depth for the scanning screen, worked out from RoomPlan's live room model.
///
/// RoomPlan runs ARKit with its own settings, which give the app neither LiDAR depth per frame
/// nor ARKit's mesh, and the app must not change them (that stops RoomPlan with "World tracking
/// failure"). RoomPlan does report the walls, floor and furniture it has found so far, so each
/// photo's depth is found by casting a ray through every pixel into that model.
///
/// This depth only drives the black canvas. It is never exported: the package holds real depth only.
struct RoomDepth {
    /// A flat, bounded surface (wall or floor) or a box (furniture), in world coordinates.
    private struct Shape {
        var worldToLocal: simd_float4x4
        var half: SIMD3<Float>         // half extents in local axes
        var flatAxis: Int?             // the axis the surface is flat along; nil for a box
        var polygon: [SIMD2<Float>]    // outline in the other two local axes, empty = rectangle
    }

    private var shapes: [Shape] = []

    var isEmpty: Bool { shapes.isEmpty }

    init(rooms: [CapturedRoom]) {
        for room in rooms {
            for surface in room.walls + room.floors { add(surface) }
            for object in room.objects {
                shapes.append(Shape(worldToLocal: object.transform.inverse, half: object.dimensions / 2,
                                    flatAxis: nil, polygon: []))
            }
        }
    }

    private mutating func add(_ surface: CapturedRoom.Surface) {
        let d = surface.dimensions
        // The axis with (almost) no size is the one the surface is flat along.
        let flat = d.x <= d.y && d.x <= d.z ? 0 : (d.y <= d.z ? 1 : 2)
        let (a, b) = Self.otherAxes(flat)
        let polygon = surface.polygonCorners.map { SIMD2<Float>($0[a], $0[b]) }
        shapes.append(Shape(worldToLocal: surface.transform.inverse, half: d / 2, flatAxis: flat,
                            polygon: polygon.count >= 3 ? polygon : []))
    }

    /// Surfaces and pieces of furniture in the model.
    var count: Int { shapes.count }

    /// A 256×192 depth map (Float32 metres along the camera's view axis, 0 = nothing) for this camera.
    /// Safe to call on any thread.
    func depthMap(for camera: ARCamera) -> FrameRecorder.Plane? {
        guard !shapes.isEmpty else { return nil }
        let width = 256, height = 192
        let scale = Float(width) / Float(camera.imageResolution.width)
        let k = camera.intrinsics
        let fx = k.columns.0.x * scale, fy = k.columns.1.y * scale
        let cx = k.columns.2.x * scale, cy = k.columns.2.y * scale
        let cameraToWorld = camera.transform
        let origin = SIMD3<Float>(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z)
        let rotation = simd_float3x3(SIMD3(cameraToWorld.columns.0.x, cameraToWorld.columns.0.y, cameraToWorld.columns.0.z),
                                     SIMD3(cameraToWorld.columns.1.x, cameraToWorld.columns.1.y, cameraToWorld.columns.1.z),
                                     SIMD3(cameraToWorld.columns.2.x, cameraToWorld.columns.2.y, cameraToWorld.columns.2.z))

        // Each shape's ray origin, and the camera's axes, in the shape's own coordinates.
        let localOrigins = shapes.map { simd_make_float3($0.worldToLocal * simd_float4(origin, 1)) }
        let cameraToLocal = shapes.map { shape -> simd_float3x3 in
            let m = shape.worldToLocal
            let r = simd_float3x3(simd_make_float3(m.columns.0), simd_make_float3(m.columns.1), simd_make_float3(m.columns.2))
            return r * rotation
        }

        var depth = [Float32](repeating: 0, count: width * height)
        for v in 0..<height {
            for u in 0..<width {
                // Camera space: x right, y up, looking down -z. A ray with z = -1 travels 1 m of depth per unit t.
                let ray = SIMD3<Float>((Float(u) + 0.5 - cx) / fx, -(Float(v) + 0.5 - cy) / fy, -1)
                var nearest = Float.infinity
                for (index, shape) in shapes.enumerated() {
                    let localDirection = cameraToLocal[index] * ray
                    if let t = Self.hit(shape, origin: localOrigins[index], direction: localDirection), t < nearest {
                        nearest = t
                    }
                }
                if nearest.isFinite { depth[v * width + u] = nearest }
            }
        }
        let data = depth.withUnsafeBytes { Data($0) }
        return FrameRecorder.Plane(width: width, height: height, bytesPerPixel: 4, data: data)
    }

    /// Distance along the ray (in units of the ray direction) to the shape, or nil.
    private static func hit(_ shape: Shape, origin o: SIMD3<Float>, direction r: SIMD3<Float>) -> Float? {
        if let flat = shape.flatAxis {
            guard abs(r[flat]) > 1e-6 else { return nil }
            let t = -o[flat] / r[flat]
            guard t > 0.05 else { return nil }
            let p = o + r * t
            let (a, b) = otherAxes(flat)
            let point = SIMD2<Float>(p[a], p[b])
            if shape.polygon.isEmpty {
                return abs(point.x) <= shape.half[a] && abs(point.y) <= shape.half[b] ? t : nil
            }
            return contains(shape.polygon, point) ? t : nil
        }
        // Box: slab test.
        var tMin: Float = 0.05, tMax = Float.infinity
        for axis in 0..<3 {
            if abs(r[axis]) < 1e-6 {
                if abs(o[axis]) > shape.half[axis] { return nil }
                continue
            }
            var t0 = (-shape.half[axis] - o[axis]) / r[axis]
            var t1 = (shape.half[axis] - o[axis]) / r[axis]
            if t0 > t1 { swap(&t0, &t1) }
            tMin = max(tMin, t0)
            tMax = min(tMax, t1)
            if tMin > tMax { return nil }
        }
        return tMin
    }

    private static func otherAxes(_ axis: Int) -> (Int, Int) {
        switch axis {
        case 0: return (1, 2)
        case 1: return (0, 2)
        default: return (0, 1)
        }
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
