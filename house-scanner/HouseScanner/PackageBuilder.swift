import Foundation
import UIKit

/// Builds house-scan.zip: everything except the videos, with a manifest and a README that
/// explain every file, so a person or an AI (for example Claude) can build a 3D rendering from it.
enum PackageBuilder {
    struct Manifest: Encodable {
        let format = "house-scanner-package"
        let version = 2
        let app = "House Scanner"
        let readme = "README.md"
        let units = "meters"
        let upAxis = "y"
        let coordinateSystem = "Right-handed, +Y up, metres. Every file shares the same ARKit world space. Matrices are 4x4, column-major."
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
        let keyframeImages: String?
        let meshes: [String]
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

    static func build(for scan: SavedScan) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "package-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = staging.appending(path: "house-scan", directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        func copy(_ from: String, _ to: String? = nil) throws {
            let source = scan.folder.appending(path: from)
            guard fm.fileExists(atPath: source.path) else { return }
            try fm.copyItem(at: source, to: root.appending(path: to ?? from))
        }
        try copy("house-scene.json")
        try copy("rooms.json", "roomplan-raw.json")
        try copy("keyframes.json")
        try copy("keyframes")
        try copy("mesh")

        let contents = (try? fm.contentsOfDirectory(atPath: scan.folder.path)) ?? []
        let posesFiles = contents.filter { $0.hasPrefix("video-poses") && $0.hasSuffix(".json") }.sorted()
        for file in posesFiles { try copy(file) }
        let videos = contents.filter { $0.hasPrefix("video") && $0.hasSuffix(".mp4") }.sorted()

        let meshFiles = ((try? fm.contentsOfDirectory(atPath: scan.folder.appending(path: "mesh").path)) ?? [])
            .filter { $0.hasSuffix(".ply") }.sorted().map { "mesh/\($0)" }
        var meshVertices = 0, meshFaces = 0
        for file in meshFiles {
            if let c = MeshExporter.counts(of: scan.folder.appending(path: file)) {
                meshVertices += c.vertices
                meshFaces += c.faces
            }
        }

        let scene = try? JSONDecoder().decode(SceneCounts.self, from: Data(contentsOf: scan.sceneJSONURL))
        let rooms = scene?.rooms ?? []
        let keyframeCount = (try? JSONDecoder().decode(FrameRecorder.StoredFrames.self, from: Data(contentsOf: scan.keyframesURL)))?.frames.count ?? 0
        let hasKeyframes = keyframeCount > 0

        let manifest = Manifest(
            name: scan.meta.name,
            createdAt: scan.meta.date,
            device: deviceModel(),
            sessions: scan.meta.sessionCount ?? 1,
            files: Files(
                keyframes: hasKeyframes ? "keyframes.json" : nil,
                keyframeImages: hasKeyframes ? "keyframes/" : nil,
                meshes: meshFiles,
                videoPoses: posesFiles),
            counts: Counts(
                rooms: rooms.count,
                walls: rooms.reduce(0) { $0 + $1.walls.count },
                doors: rooms.reduce(0) { $0 + $1.doors.count },
                windows: rooms.reduce(0) { $0 + $1.windows.count },
                openings: rooms.reduce(0) { $0 + $1.openings.count },
                objects: rooms.reduce(0) { $0 + $1.objects.count },
                keyframes: keyframeCount,
                meshVertices: meshVertices,
                meshFaces: meshFaces),
            notIncluded: videos.map { "\($0) (exported separately; its camera poses are in the matching video-poses file)" })

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: root.appending(path: "manifest.json"))

        if let readme = Bundle.main.url(forResource: "PackageREADME", withExtension: "md") {
            try fm.copyItem(at: readme, to: root.appending(path: "README.md"))
        }

        // NSFileCoordinator's .forUploading option hands back a zip of the folder.
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: root, options: [.forUploading], error: &coordinatorError) { zipURL in
            do {
                if fm.fileExists(atPath: scan.packageURL.path) { try fm.removeItem(at: scan.packageURL) }
                try fm.copyItem(at: zipURL, to: scan.packageURL)
            } catch {
                copyError = error
            }
        }
        if let error = coordinatorError ?? copyError { throw error }
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
