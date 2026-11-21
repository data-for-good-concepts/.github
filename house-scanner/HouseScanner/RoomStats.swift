import Foundation
import RoomPlan
import simd

extension CapturedRoom.Surface {
    /// Area of a floor surface in square metres.
    var area: Float {
        let corners = polygonCorners
        if corners.count >= 3 {
            // Corners lie in the surface's own plane; try both possible axes and keep the real one.
            return max(Self.shoelace(corners.map { SIMD2($0.x, $0.y) }),
                       Self.shoelace(corners.map { SIMD2($0.x, $0.z) }))
        }
        let depth = dimensions.y > 0.01 ? dimensions.y : dimensions.z
        return dimensions.x * depth
    }

    private static func shoelace(_ points: [SIMD2<Float>]) -> Float {
        var sum: Float = 0
        for i in points.indices {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}

extension CapturedRoom.Object.Category {
    var displayName: String {
        let raw = String(describing: self)
        // "washerDryer" -> "Washer dryer"
        let spaced = raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.prefix(1).uppercased() + spaced.dropFirst().lowercased()
    }
}

struct ScanSummary {
    var walls = 0
    var doors = 0
    var windows = 0
    var openings = 0
    var floorArea: Float = 0
    var ceilingHeight: Float?
    var objectCounts: [(name: String, count: Int)] = []

    init(rooms: [CapturedRoom]) {
        walls = rooms.reduce(0) { $0 + $1.walls.count }
        doors = rooms.reduce(0) { $0 + $1.doors.count }
        windows = rooms.reduce(0) { $0 + $1.windows.count }
        openings = rooms.reduce(0) { $0 + $1.openings.count }
        floorArea = rooms.flatMap(\.floors).reduce(0) { $0 + $1.area }

        let heights = rooms.flatMap(\.walls).map(\.dimensions.y).sorted()
        if !heights.isEmpty { ceilingHeight = heights[heights.count / 2] }

        var counts: [String: Int] = [:]
        for object in rooms.flatMap(\.objects) {
            counts[object.category.displayName, default: 0] += 1
        }
        objectCounts = counts.map { (name: $0.key, count: $0.value) }.sorted { $0.name < $1.name }
    }
}

enum Format {
    static func metres(_ value: Float) -> String {
        String(format: "%.2f m", value)
    }

    static func squareMetres(_ value: Float) -> String {
        String(format: "%.1f m²", value)
    }
}
