import Foundation
import RoomPlan
import simd

/// Writes `floor-plan.dxf` (AutoCAD R12 ASCII, units: metres).
///
/// 2D floor plan on layers WALLS, DOORS, WINDOWS, OPENINGS, FURNITURE, FLOOR and LABELS,
/// plus every wall as a 3D face on layer WALLS_3D so CAD programs can show the house in 3D.
/// DXF is Z-up: scanner X → DXF X, scanner Z → DXF −Y, scanner height Y → DXF Z.
enum DXFExporter {
    private static let layers: [(name: String, color: Int)] = [
        ("WALLS", 7), ("WALLS_3D", 8), ("DOORS", 30), ("WINDOWS", 4),
        ("OPENINGS", 9), ("FURNITURE", 8), ("FLOOR", 3), ("LABELS", 2),
    ]

    static func string(rooms: [CapturedRoom]) -> String {
        var w = Writer()

        w.pair(0, "SECTION"); w.pair(2, "HEADER")
        w.pair(9, "$ACADVER"); w.pair(1, "AC1009")
        w.pair(9, "$INSUNITS"); w.pair(70, "6")
        w.pair(0, "ENDSEC")

        w.pair(0, "SECTION"); w.pair(2, "TABLES")
        w.pair(0, "TABLE"); w.pair(2, "LAYER"); w.pair(70, "\(layers.count)")
        for layer in layers {
            w.pair(0, "LAYER"); w.pair(2, layer.name); w.pair(70, "0")
            w.pair(62, "\(layer.color)"); w.pair(6, "CONTINUOUS")
        }
        w.pair(0, "ENDTAB")
        w.pair(0, "ENDSEC")

        w.pair(0, "SECTION"); w.pair(2, "ENTITIES")
        for room in rooms {
            for floor in room.floors {
                if let outline = FloorPlan.outline(floor) { w.polyline(outline, layer: "FLOOR") }
            }
            for wall in room.walls {
                let seg = FloorPlan.segment(wall)
                w.line(seg.a, seg.b, layer: "WALLS")
                w.face(wallFace(wall), layer: "WALLS_3D")
                if wall.dimensions.x > 0.3 {
                    w.label(String(format: "%.2f m", wall.dimensions.x), along: seg, height: 0.1, layer: "LABELS")
                }
            }
            for door in room.doors { let s = FloorPlan.segment(door); w.line(s.a, s.b, layer: "DOORS") }
            for window in room.windows { let s = FloorPlan.segment(window); w.line(s.a, s.b, layer: "WINDOWS") }
            for opening in room.openings { let s = FloorPlan.segment(opening); w.line(s.a, s.b, layer: "OPENINGS") }
            for object in room.objects {
                w.polyline(FloorPlan.footprint(object), layer: "FURNITURE")
                w.text(object.category.displayName, at: FloorPlan.flat(object.transform.columns.3),
                       height: 0.08, layer: "LABELS")
            }
        }
        w.pair(0, "ENDSEC")
        w.pair(0, "EOF")
        return w.output
    }

    /// The four corners of a wall in 3D (scanner coordinates).
    private static func wallFace(_ wall: CapturedRoom.Surface) -> [simd_float3] {
        let h = wall.dimensions / 2
        return [(-1, -1), (1, -1), (1, 1), (-1, 1)].map { x, y in
            let p = wall.transform * simd_float4(h.x * Float(x), h.y * Float(y), 0, 1)
            return simd_float3(p.x, p.y, p.z)
        }
    }

    private struct Writer {
        var output = ""

        mutating func pair(_ code: Int, _ value: String) {
            output += "\(code)\n\(value)\n"
        }

        private func n(_ v: Double) -> String { String(format: "%.4f", v) }

        /// Plan point (x, z) → DXF (x, −z).
        private mutating func point(_ p: CGPoint, _ code: Int = 10) {
            pair(code, n(Double(p.x))); pair(code + 10, n(Double(-p.y))); pair(code + 20, "0.0")
        }

        mutating func line(_ a: CGPoint, _ b: CGPoint, layer: String) {
            pair(0, "LINE"); pair(8, layer)
            point(a, 10); point(b, 11)
        }

        mutating func polyline(_ points: [CGPoint], layer: String) {
            pair(0, "POLYLINE"); pair(8, layer); pair(66, "1"); pair(70, "1")
            pair(10, "0.0"); pair(20, "0.0"); pair(30, "0.0")
            for p in points {
                pair(0, "VERTEX"); pair(8, layer); point(p)
            }
            pair(0, "SEQEND"); pair(8, layer)
        }

        mutating func face(_ corners: [simd_float3], layer: String) {
            pair(0, "3DFACE"); pair(8, layer)
            for (i, c) in corners.enumerated() {
                pair(10 + i, n(Double(c.x)))
                pair(20 + i, n(Double(-c.z)))
                pair(30 + i, n(Double(c.y)))
            }
        }

        mutating func text(_ string: String, at p: CGPoint, height: Double, rotation: Double = 0, layer: String) {
            pair(0, "TEXT"); pair(8, layer)
            point(p, 10)
            pair(40, n(height)); pair(1, string); pair(50, n(rotation))
            pair(72, "1"); pair(73, "2")   // centred horizontally and vertically
            point(p, 11)
        }

        /// Wall length written along the wall, kept upright.
        mutating func label(_ string: String, along seg: FloorPlan.Segment, height: Double, layer: String) {
            let dx = Double(seg.b.x - seg.a.x)
            let dy = -Double(seg.b.y - seg.a.y)
            var angle = atan2(dy, dx) * 180 / .pi
            if angle > 90 { angle -= 180 }
            if angle < -90 { angle += 180 }
            let mid = CGPoint(x: (seg.a.x + seg.b.x) / 2, y: (seg.a.y + seg.b.y) / 2)
            text(string, at: mid, height: height, rotation: angle, layer: layer)
        }
    }
}
