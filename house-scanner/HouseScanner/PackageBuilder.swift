import Foundation
import UIKit

/// Builds the scan package: every piece of captured data with a manifest and a README that explain
/// each file, so Claude (or a person) can build a photoreal 3D rendering from it.
///
/// - house-scan.zip             everything except the videos (built when a scan is saved)
/// - house-scan-with-video.zip  the same plus every session's video (built on request; large)
enum PackageBuilder {
    struct Manifest: Encodable {
        let format = "house-scanner-package"
        let version = 3
        let app = "House Scanner"
        let readme = "README.md"
        let units = "meters"
        let upAxis = "y"
        let coordinateSystem = "Right-handed, +Y up, metres. Every file shares the same ARKit world space. Matrices are 4x4, column-major (except transforms.json, which follows nerfstudio: row-major nested lists)."
        let name: String
        let createdAt: Date
        let device: String
        let sessions: Int
        let files: Files
        let counts: Counts
        let notIncluded: [String]
    }

    struct Files: Encodable {
        let scene = "house-scene.json"
        let roomplanRaw = "roomplan-raw.json"
        let keyframes: String?
        let nerfstudioTransforms: String?
        let images = "keyframes/"
        let depth = "depth/"
        let confidence = "confidence/"
        let meshes: [String]
        let videos: [String]
        let videoPoses: [String]
    }

    struct Counts: Encodable {
        let rooms: Int
        let walls: Int
        let doors: Int
        let windows: Int
        let openings: Int
        let objects: Int
        let keyframes: Int
        let keyframesWithDepth: Int
        let meshVertices: Int
        let meshFaces: Int
    }

    /// The raw house-scene.json, read only for the counts.
    private struct SceneCounts: Decodable {
        struct Room: Decodable {
            let walls: [Item]
            let doors: [Item]
            let windows: [Item]
            let openings: [Item]
            let objects: [Item]
        }
        struct Item: Decodable {}
        let rooms: [Room]
    }

    /// nerfstudio's transforms.json: per-frame pinhole intrinsics and camera-to-world matrices in the
    /// OpenGL convention, which is the same as ARKit's, so no axis changes are needed.
    private struct Transforms: Encodable {
        struct Frame: Encodable {
            let file_path: String
            let transform_matrix: [[Float]]
            let fl_x: Float
            let fl_y: Float
            let cx: Float
            let cy: Float
            let w: Int
            let h: Int
            let depth_file_path: String?
        }
        let camera_model = "PINHOLE"
        let depth_unit_scale_factor = 0.001
        let frames: [Frame]
    }

    static func build(for scan: SavedScan, includeVideo: Bool = false) throws -> URL {
        let fm = FileManager.default
        let destination = includeVideo ? scan.folder.appending(path: "house-scan-with-video.zip") : scan.packageURL
        let staging = fm.temporaryDirectory.appending(path: "package-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = staging.appending(path: "house-scan", directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        func copy(_ from: String, _ to: String? = nil) throws {
            let source = scan.folder.appending(path: from)
            guard fm.fileExists(atPath: source.path) else { return }
            try fm.copyItem(at: source, to: root.appending(path: to ?? from))
        }
        for item in ["house-scene.json", "keyframes.json", "keyframes", "depth", "confidence", "mesh"] { try copy(item) }
        try copy("rooms.json", "roomplan-raw.json")

        let contents = (try? fm.contentsOfDirectory(atPath: scan.folder.path)) ?? []
        let posesFiles = contents.filter { $0.hasPrefix("video-poses") && $0.hasSuffix(".json") }.sorted()
        for file in posesFiles { try copy(file) }
        let videos = contents.filter { $0.hasPrefix("video") && $0.hasSuffix(".mp4") }.sorted()
        if includeVideo { for file in videos { try copy(file) } }

        let meshFiles = ((try? fm.contentsOfDirectory(atPath: scan.folder.appending(path: "mesh").path)) ?? [])
            .filter { $0.hasSuffix(".ply") }.sorted().map { "mesh/\($0)" }
        var meshVertices = 0, meshFaces = 0
        for file in meshFiles {
            if let c = MeshExporter.counts(of: scan.folder.appending(path: file)) {
                meshVertices += c.vertices
                meshFaces += c.faces
            }
        }

        let frames = (try? JSONDecoder().decode(FrameRecorder.StoredFrames.self, from: Data(contentsOf: scan.keyframesURL)))?.frames ?? []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        if !frames.isEmpty {
            // nerfstudio needs depth for every frame or for none.
            let allHaveDepth = frames.allSatisfy { $0.depthFile != nil }
            let transforms = Transforms(frames: frames.compactMap { f in
                guard let file = f.file, f.transform.count == 16, f.intrinsics.count == 4 else { return nil }
                // Column-major (ARKit) → row-major rows.
                let rows = (0..<4).map { r in (0..<4).map { c in f.transform[c * 4 + r] } }
                return Transforms.Frame(file_path: file, transform_matrix: rows,
                                        fl_x: f.intrinsics[0], fl_y: f.intrinsics[1], cx: f.intrinsics[2], cy: f.intrinsics[3],
                                        w: f.width, h: f.height, depth_file_path: allHaveDepth ? f.depthFile : nil)
            })
            try encoder.encode(transforms).write(to: root.appending(path: "transforms.json"))
        }

        let scene = try? JSONDecoder().decode(SceneCounts.self, from: Data(contentsOf: scan.sceneJSONURL))
        let rooms = scene?.rooms ?? []
        let manifest = Manifest(
            name: scan.meta.name,
            createdAt: scan.meta.date,
            device: deviceModel(),
            sessions: scan.meta.sessionCount ?? 1,
            files: Files(
                keyframes: frames.isEmpty ? nil : "keyframes.json",
                nerfstudioTransforms: frames.isEmpty ? nil : "transforms.json",
                meshes: meshFiles,
                videos: includeVideo ? videos : [],
                videoPoses: posesFiles),
            counts: Counts(
                rooms: rooms.count,
                walls: rooms.reduce(0) { $0 + $1.walls.count },
                doors: rooms.reduce(0) { $0 + $1.doors.count },
                windows: rooms.reduce(0) { $0 + $1.windows.count },
                openings: rooms.reduce(0) { $0 + $1.openings.count },
                objects: rooms.reduce(0) { $0 + $1.objects.count },
                keyframes: frames.count,
                keyframesWithDepth: frames.filter { $0.depthFile != nil }.count,
                meshVertices: meshVertices,
                meshFaces: meshFaces),
            notIncluded: includeVideo ? [] : videos.map { "\($0) (share \"Package with video\" to include it; its camera poses are in the matching video-poses file)" })
        try encoder.encode(manifest).write(to: root.appending(path: "manifest.json"))

        if let readme = Bundle.main.url(forResource: "PackageREADME", withExtension: "md") {
            try fm.copyItem(at: readme, to: root.appending(path: "README.md"))
        }

        // NSFileCoordinator's .forUploading option hands back a zip of the folder.
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: root, options: [.forUploading], error: &coordinatorError) { zipURL in
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: zipURL, to: destination)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
        return destination
    }

    /// Model identifier such as "iPhone16,1".
    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(machine), iOS \(UIDevice.current.systemVersion)"
    }
}
