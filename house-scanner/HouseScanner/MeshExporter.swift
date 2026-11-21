import ARKit

/// Writes ARKit's LiDAR mesh (all mesh anchors) as one binary PLY file in world coordinates,
/// with ARKit's classification for every face.
enum MeshExporter {
    static let classificationNames = ["none", "wall", "floor", "ceiling", "table", "seat", "window", "door"]

    @discardableResult
    static func writePLY(anchors: [ARMeshAnchor], to url: URL) throws -> (vertices: Int, faces: Int) {
        let vertexTotal = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        let faceTotal = anchors.reduce(0) { $0 + $1.geometry.faces.count }

        let header = """
        ply
        format binary_little_endian 1.0
        comment House Scanner ARKit LiDAR mesh. Metres, Y up, same world space as house-scene.json.
        comment classification per face: 0 none, 1 wall, 2 floor, 3 ceiling, 4 table, 5 seat, 6 window, 7 door
        element vertex \(vertexTotal)
        property float x
        property float y
        property float z
        element face \(faceTotal)
        property list uchar uint vertex_indices
        property uchar classification
        end_header

        """
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + vertexTotal * 12 + faceTotal * 14)

        // Vertices, moved from each anchor's local space into world space.
        for anchor in anchors {
            let source = anchor.geometry.vertices
            let base = source.buffer.contents().advanced(by: source.offset)
            let transform = anchor.transform
            for i in 0..<source.count {
                let p = base.advanced(by: i * source.stride).assumingMemoryBound(to: Float.self)
                let world = transform * simd_float4(p[0], p[1], p[2], 1)
                append(&data, world.x)
                append(&data, world.y)
                append(&data, world.z)
            }
        }

        // Faces, with indices offset into the combined vertex list.
        var offset: UInt32 = 0
        for anchor in anchors {
            let geometry = anchor.geometry
            let faces = geometry.faces
            let base = faces.buffer.contents()
            let classification = geometry.classification
            for i in 0..<faces.count {
                data.append(UInt8(3))
                for k in 0..<3 {
                    let pointer = base.advanced(by: (i * faces.indexCountPerPrimitive + k) * faces.bytesPerIndex)
                    let index: UInt32 = faces.bytesPerIndex == 2
                        ? UInt32(pointer.assumingMemoryBound(to: UInt16.self).pointee)
                        : pointer.assumingMemoryBound(to: UInt32.self).pointee
                    append(&data, index + offset)
                }
                var value: UInt8 = 0
                if let classification {
                    value = classification.buffer.contents()
                        .advanced(by: classification.offset + i * classification.stride)
                        .assumingMemoryBound(to: UInt8.self).pointee
                }
                data.append(value)
            }
            offset += UInt32(geometry.vertices.count)
        }

        try data.write(to: url)
        return (vertexTotal, faceTotal)
    }

    /// Reads the vertex and face counts from a PLY header.
    static func counts(of url: URL) -> (vertices: Int, faces: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1024),
              let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var vertices = 0, faces = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if parts.count == 3, parts[0] == "element" {
                if parts[1] == "vertex" { vertices = Int(parts[2]) ?? 0 }
                if parts[1] == "face" { faces = Int(parts[2]) ?? 0 }
            }
            if line.hasPrefix("end_header") { break }
        }
        return (vertices, faces)
    }

    private static func append<T>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value) { data.append(contentsOf: $0) }
    }
}
