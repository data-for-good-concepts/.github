import Foundation
import RoomPlan
import simd

/// Writes `house-scene.json`: a clean description of the scan for building 3D scenes in
/// JavaScript (for example three.js).
///
/// Conventions match three.js: metres, Y up, right-handed. Each item's `matrix` is a
/// column-major 4×4 transform that can be passed straight to `new THREE.Matrix4().fromArray(matrix)`.
/// The item's local box is centred on the origin and has the size given in `size`.
enum SceneExporter {
    struct Scene: Encodable {
        let format = "house-scanner-scene"
        let version = 1
        let units = "meters"
        let upAxis = "y"
        let notes = [
            "Coordinates are metres, Y up, right-handed (same as three.js).",
            "position is the centre of the item. rotationY is the rotation around the Y axis in radians.",
            "size is [width, height, depth]. Walls, doors, windows, openings and floors are flat, so one of their sizes is 0: give walls your own thickness (e.g. 0.1 m) when rendering.",
            "matrix is the full column-major 4x4 transform: new THREE.Matrix4().fromArray(matrix).",
            "corners, when present, are the world-space outline of a floor or of a non-rectangular wall.",
            "parentId links a door, window or opening to the wall it sits in.",
            "story is the floor level of the room (0 = ground floor) when the scanner could tell.",
        ]
        let name: String
        let scannedAt: Date
        let bounds: Bounds
        let rooms: [Room]
    }

    struct Bounds: Encodable {
        let min: [Double]
        let max: [Double]
        let center: [Double]
        let size: [Double]
    }

    struct Room: Encodable {
        let index: Int
        let story: Int
        let walls: [Item]
        let doors: [Item]
        let windows: [Item]
        let openings: [Item]
        let floors: [Item]
        let objects: [Item]
    }

    struct Item: Encodable {
        let id: String
        let type: String
        let category: String?
        let isOpen: Bool?
        let position: [Double]
        let rotationY: Double
        let size: [Double]
        let matrix: [Double]
        let corners: [[Double]]?
        let parentId: String?
        let confidence: String
    }

    static func data(rooms: [CapturedRoom], name: String, date: Date) throws -> Data {
        var boxPoints: [simd_float3] = []

        let exportedRooms = rooms.enumerated().map { index, room in
            func surfaces(_ list: [CapturedRoom.Surface], _ type: String) -> [Item] {
                list.map { surface in
                    boxPoints += boxCorners(surface.transform, surface.dimensions)
                    var isOpen: Bool?
                    if case .door(let open) = surface.category { isOpen = open }
                    let corners = surface.polygonCorners.isEmpty ? nil : surface.polygonCorners.map {
                        vector(world(surface.transform, $0))
                    }
                    return Item(
                        id: surface.identifier.uuidString,
                        type: type,
                        category: nil,
                        isOpen: isOpen,
                        position: vector(position(surface.transform)),
                        rotationY: round(rotationY(surface.transform)),
                        size: vector(surface.dimensions),
                        matrix: matrix(surface.transform),
                        corners: corners,
                        parentId: surface.parentIdentifier?.uuidString,
                        confidence: confidence(surface.confidence))
                }
            }

            let objects = room.objects.map { object in
                boxPoints += boxCorners(object.transform, object.dimensions)
                return Item(
                    id: object.identifier.uuidString,
                    type: "object",
                    category: String(describing: object.category),
                    isOpen: nil,
                    position: vector(position(object.transform)),
                    rotationY: round(rotationY(object.transform)),
                    size: vector(object.dimensions),
                    matrix: matrix(object.transform),
                    corners: nil,
                    parentId: object.parentIdentifier?.uuidString,
                    confidence: confidence(object.confidence))
            }

            return Room(
                index: index,
                story: room.story,
                walls: surfaces(room.walls, "wall"),
                doors: surfaces(room.doors, "door"),
                windows: surfaces(room.windows, "window"),
                openings: surfaces(room.openings, "opening"),
                floors: surfaces(room.floors, "floor"),
                objects: objects)
        }

        var lo = boxPoints.first ?? .zero
        var hi = lo
        for p in boxPoints {
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }

        let scene = Scene(
            name: name,
            scannedAt: date,
            bounds: Bounds(min: vector(lo), max: vector(hi), center: vector((lo + hi) / 2), size: vector(hi - lo)),
            rooms: exportedRooms)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(scene)
    }

    // MARK: - Helpers

    private static func round(_ value: Float) -> Double {
        (Double(value) * 1000).rounded() / 1000
    }

    private static func vector(_ v: simd_float3) -> [Double] {
        [round(v.x), round(v.y), round(v.z)]
    }

    private static func position(_ t: simd_float4x4) -> simd_float3 {
        simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }

    /// Rotation around Y, in the same sense as three.js `object.rotation.y`.
    private static func rotationY(_ t: simd_float4x4) -> Float {
        atan2(-t.columns.0.z, t.columns.0.x)
    }

    private static func matrix(_ t: simd_float4x4) -> [Double] {
        [t.columns.0, t.columns.1, t.columns.2, t.columns.3].flatMap { c in
            [c.x, c.y, c.z, c.w].map { (Double($0) * 1_000_000).rounded() / 1_000_000 }
        }
    }

    private static func world(_ t: simd_float4x4, _ local: simd_float3) -> simd_float3 {
        let p = t * simd_float4(local, 1)
        return simd_float3(p.x, p.y, p.z)
    }

    private static func boxCorners(_ t: simd_float4x4, _ size: simd_float3) -> [simd_float3] {
        let h = size / 2
        return [-1, 1].flatMap { x in [-1, 1].flatMap { y in [-1, 1].map { z in
            world(t, simd_float3(h.x * Float(x), h.y * Float(y), h.z * Float(z)))
        } } }
    }

    private static func confidence(_ c: CapturedRoom.Confidence) -> String {
        switch c {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        @unknown default: return "unknown"
        }
    }
}
