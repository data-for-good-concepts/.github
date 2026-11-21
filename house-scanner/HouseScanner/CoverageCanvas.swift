import ARKit
import SceneKit
import SwiftUI

/// The scanning screen's picture: black, showing only what has been fully captured, as coloured
/// points seen from where the phone is right now. Things appear as they are captured.
final class CoverageCanvas {
    let view: SCNView
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let pointsRoot = SCNNode()
    private var chunkNodes: [Int64: SCNNode] = [:]
    private let material: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant          // the colours are photographed light already
        m.diffuse.contents = UIColor.white   // multiplied by the per-point colours
        m.isDoubleSided = true
        return m
    }()

    init() {
        view = SCNView(frame: .zero)
        view.scene = scene
        view.backgroundColor = .black
        scene.background.contents = UIColor.black
        view.antialiasingMode = .none
        view.rendersContinuously = true
        view.isUserInteractionEnabled = false
        cameraNode.camera = SCNCamera()
        scene.rootNode.addChildNode(cameraNode)
        scene.rootNode.addChildNode(pointsRoot)
        gapsNode.renderingOrder = 10   // after the points, so captured points stay visible
        scene.rootNode.addChildNode(gapsNode)
        view.pointOfView = cameraNode
    }

    /// Moves the virtual camera to where the phone is (call every frame).
    func follow(_ camera: ARCamera) {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        cameraNode.simdTransform = camera.viewMatrix(for: .portrait).inverse
        cameraNode.camera?.projectionTransform = SCNMatrix4(
            camera.projectionMatrix(for: .portrait, viewportSize: size, zNear: 0.02, zFar: 80))
    }

    /// Replaces the points of the chunks that changed.
    func apply(_ chunks: [Int64: CoverageMap.Points]) {
        for (key, points) in chunks {
            guard !points.positions.isEmpty else {
                chunkNodes[key]?.removeFromParentNode()
                chunkNodes[key] = nil
                continue
            }
            let node = chunkNodes[key] ?? {
                let n = SCNNode()
                pointsRoot.addChildNode(n)
                chunkNodes[key] = n
                return n
            }()
            node.geometry = geometry(points)
        }
    }

    /// Red tiles where the LiDAR walk still needs a photo (replaces any shown before).
    func showGaps(_ tiles: [Int: [SIMD3<Float>]]) {
        gapsNode.geometry = nil
        let quads = tiles.values.filter { $0.count == 4 }
        guard !quads.isEmpty else { return }
        var vertices: [SIMD3<Float>] = []
        var triangles: [UInt32] = []
        var lines: [UInt32] = []
        for quad in quads {
            let base = UInt32(vertices.count)
            vertices.append(contentsOf: quad)
            triangles += [base, base + 1, base + 2, base, base + 2, base + 3]
            lines += [base, base + 1, base + 1, base + 2, base + 2, base + 3, base + 3, base]
        }
        let source = SCNGeometrySource(vertices: vertices.map { SCNVector3($0.x, $0.y, $0.z) })
        let fill = SCNGeometryElement(indices: triangles, primitiveType: .triangles)
        let outline = SCNGeometryElement(indices: lines, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [fill, outline])
        geometry.materials = [gapFill, gapOutline]
        gapsNode.geometry = geometry
    }

    private let gapsNode = SCNNode()
    private let gapFill: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.systemRed.withAlphaComponent(0.35)
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        return m
    }()
    private let gapOutline: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = UIColor.systemRed
        m.isDoubleSided = true
        return m
    }()

    private func geometry(_ points: CoverageMap.Points) -> SCNGeometry {
        let count = points.positions.count
        let positions = points.positions.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: count * MemoryLayout<SIMD3<Float>>.stride)
        }
        let colors = points.colors.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: count * MemoryLayout<SIMD3<Float>>.stride)
        }
        let stride = MemoryLayout<SIMD3<Float>>.stride   // 16 bytes: x, y, z + padding
        let vertexSource = SCNGeometrySource(data: positions, semantic: .vertex, vectorCount: count,
                                             usesFloatComponents: true, componentsPerVector: 3,
                                             bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let colorSource = SCNGeometrySource(data: colors, semantic: .color, vectorCount: count,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let indices = (0..<UInt32(count)).map { $0 }
        let element = SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) },
                                         primitiveType: .point, primitiveCount: count, bytesPerIndex: 4)
        element.pointSize = CGFloat(CoverageMap.voxelSize * 1.3)   // in metres: points just overlap
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 24
        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        geometry.materials = [material]
        return geometry
    }
}

struct CoverageCanvasView: UIViewRepresentable {
    let canvas: CoverageCanvas

    func makeUIView(context: Context) -> SCNView { canvas.view }
    func updateUIView(_ uiView: SCNView, context: Context) {}
}
