import RoomPlan
import SwiftUI
import simd

/// A top-down 2D floor plan drawn from the RoomPlan data.
struct FloorPlanView: View {
    let rooms: [CapturedRoom]
    var showMeasurements: Bool

    var body: some View {
        let plan = FloorPlan(rooms: rooms)
        Canvas { context, size in
            guard let bounds = plan.bounds else { return }
            let padding: CGFloat = 28
            let scale = min((size.width - padding * 2) / bounds.width,
                            (size.height - padding * 2) / bounds.height)
            let offset = CGPoint(x: (size.width - bounds.width * scale) / 2,
                                 y: (size.height - bounds.height * scale) / 2)
            func p(_ point: CGPoint) -> CGPoint {
                CGPoint(x: offset.x + (point.x - bounds.minX) * scale,
                        y: offset.y + (point.y - bounds.minY) * scale)
            }
            func line(_ seg: FloorPlan.Segment) -> Path {
                var path = Path()
                path.move(to: p(seg.a))
                path.addLine(to: p(seg.b))
                return path
            }
            func polygon(_ points: [CGPoint]) -> Path {
                var path = Path()
                path.addLines(points.map(p))
                path.closeSubpath()
                return path
            }

            for floor in plan.floors {
                context.fill(polygon(floor), with: .color(.accentColor.opacity(0.10)))
            }
            for object in plan.objects {
                let shape = polygon(object)
                context.fill(shape, with: .color(.gray.opacity(0.25)))
                context.stroke(shape, with: .color(.gray.opacity(0.7)), lineWidth: 1)
            }
            for wall in plan.walls {
                context.stroke(line(wall), with: .color(.primary), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            let gap = Color(uiColor: .secondarySystemBackground)
            for opening in plan.openings {
                context.stroke(line(opening), with: .color(gap), lineWidth: 6)
            }
            for door in plan.doors {
                context.stroke(line(door), with: .color(gap), lineWidth: 6)
                context.stroke(line(door), with: .color(.orange), lineWidth: 2)
            }
            for window in plan.windows {
                context.stroke(line(window), with: .color(.cyan), lineWidth: 3)
            }

            if showMeasurements {
                for wall in plan.walls where wall.length > 0.6 {
                    let mid = p(CGPoint(x: (wall.a.x + wall.b.x) / 2, y: (wall.a.y + wall.b.y) / 2))
                    let label = Text(Format.metres(wall.length))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.gray)
                    context.draw(label, at: CGPoint(x: mid.x, y: mid.y - 9))
                }
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .overlay {
            if plan.bounds == nil {
                Text("No floor plan data").foregroundStyle(.secondary)
            }
        }
    }
}

/// Converts RoomPlan's 3D surfaces into 2D shapes seen from above (x = right, z = down).
struct FloorPlan {
    struct Segment {
        var a: CGPoint
        var b: CGPoint
        var length: Float
    }

    var walls: [Segment] = []
    var doors: [Segment] = []
    var windows: [Segment] = []
    var openings: [Segment] = []
    var objects: [[CGPoint]] = []
    var floors: [[CGPoint]] = []

    init(rooms: [CapturedRoom]) {
        for room in rooms {
            walls += room.walls.map(Self.segment)
            doors += room.doors.map(Self.segment)
            windows += room.windows.map(Self.segment)
            openings += room.openings.map(Self.segment)
            objects += room.objects.map(Self.footprint)
            floors += room.floors.compactMap(Self.outline)
        }
    }

    var bounds: CGRect? {
        let points = walls.flatMap { [$0.a, $0.b] } + floors.flatMap { $0 } + objects.flatMap { $0 }
        guard let first = points.first else { return nil }
        var rect = CGRect(origin: first, size: .zero)
        for point in points { rect = rect.union(CGRect(origin: point, size: .zero)) }
        guard rect.width > 0.01, rect.height > 0.01 else { return nil }
        return rect
    }

    private static func flat(_ v: simd_float4) -> CGPoint {
        CGPoint(x: CGFloat(v.x), y: CGFloat(v.z))
    }

    private static func direction(_ v: simd_float4) -> CGVector {
        let length = max(hypot(CGFloat(v.x), CGFloat(v.z)), 0.0001)
        return CGVector(dx: CGFloat(v.x) / length, dy: CGFloat(v.z) / length)
    }

    /// Walls, doors and windows are flat rectangles; their local x axis runs along their width.
    private static func segment(_ surface: CapturedRoom.Surface) -> Segment {
        let t = surface.transform
        let center = flat(t.columns.3)
        let dir = direction(t.columns.0)
        let half = CGFloat(surface.dimensions.x) / 2
        return Segment(a: CGPoint(x: center.x - dir.dx * half, y: center.y - dir.dy * half),
                       b: CGPoint(x: center.x + dir.dx * half, y: center.y + dir.dy * half),
                       length: surface.dimensions.x)
    }

    /// The rectangle an object (bed, sofa, table…) covers on the floor.
    private static func footprint(_ object: CapturedRoom.Object) -> [CGPoint] {
        let t = object.transform
        let c = flat(t.columns.3)
        let right = direction(t.columns.0)
        let forward = direction(t.columns.2)
        let w = CGFloat(object.dimensions.x) / 2
        let d = CGFloat(object.dimensions.z) / 2
        return [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { sx, sz in
            CGPoint(x: c.x + right.dx * w * sx + forward.dx * d * sz,
                    y: c.y + right.dy * w * sx + forward.dy * d * sz)
        }
    }

    private static func outline(_ floor: CapturedRoom.Surface) -> [CGPoint]? {
        guard floor.polygonCorners.count >= 3 else { return nil }
        return floor.polygonCorners.map { corner in
            flat(floor.transform * simd_float4(corner, 1))
        }
    }
}
