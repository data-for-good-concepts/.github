import ARKit
import Foundation
import RoomPlan

/// Information saved next to every scan.
struct ScanMeta: Codable, Hashable {
    var name: String
    var date: Date
    var roomCount: Int
    var hasMergedModel: Bool
    /// How many scanning sessions went into this scan (nil in older scans = 1).
    var sessionCount: Int?
}

/// A scan saved on the phone. Each scan is a folder in Documents/Scans that holds:
/// - meta.json            name, date, number of rooms
/// - rooms.json           the raw RoomPlan data (used for the floor plan and stats)
/// - room-N.usdz          a 3D model of each room
/// - house.usdz           all rooms merged into one model (when there is more than one room)
/// - house-scene.json     clean JSON for building 3D scenes in JavaScript (three.js)
/// - floor-plan.dxf       floor plan for CAD programs (with 3D walls)
/// - video.mp4, video-2.mp4…, video-poses*.json   camera recording of each session
/// - keyframes/, keyframes.json   still photos from all sessions (see FrameRecorder)
/// - mesh/mesh-N.ply      ARKit LiDAR mesh of each session, with per-face classification
/// - worldmap.arexperience        ARKit's map of the place, for adding rooms later
/// - house-scan.zip       everything except the videos, with manifest.json and README.md (see PackageBuilder)
struct SavedScan: Identifiable, Hashable {
    let folder: URL
    var meta: ScanMeta

    var id: URL { folder }

    var mergedModelURL: URL { folder.appending(path: "house.usdz") }
    var roomsDataURL: URL { folder.appending(path: "rooms.json") }
    var sceneJSONURL: URL { folder.appending(path: "house-scene.json") }
    var dxfURL: URL { folder.appending(path: "floor-plan.dxf") }
    var keyframesURL: URL { folder.appending(path: "keyframes.json") }
    var worldMapURL: URL { folder.appending(path: "worldmap.arexperience") }
    /// house-scene.json + keyframes, zipped, for the textured web viewer.
    var packageURL: URL { folder.appending(path: "house-scan.zip") }

    func roomModelURL(_ index: Int) -> URL {
        folder.appending(path: "room-\(index + 1).usdz")
    }

    /// The best model to show: the merged house if it exists, otherwise the first room.
    var mainModelURL: URL {
        FileManager.default.fileExists(atPath: mergedModelURL.path) ? mergedModelURL : roomModelURL(0)
    }

    /// One video per scanning session, oldest first.
    var videoURLs: [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "mp4" && $0.lastPathComponent.hasPrefix("video") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    var hasPackage: Bool { FileManager.default.fileExists(atPath: packageURL.path) }
    var canAddRooms: Bool { FileManager.default.fileExists(atPath: worldMapURL.path) }
}

@MainActor
final class ScanStore: ObservableObject {
    @Published private(set) var scans: [SavedScan] = []

    private let root: URL

    init() {
        root = URL.documentsDirectory.appending(path: "Scans", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        scans = folders
            .compactMap { folder -> SavedScan? in
                guard let data = try? Data(contentsOf: folder.appending(path: "meta.json")),
                      let meta = try? JSONDecoder().decode(ScanMeta.self, from: data) else { return nil }
                return SavedScan(folder: folder, meta: meta)
            }
            .sorted { $0.meta.date > $1.meta.date }
    }

    // MARK: - Saving

    /// Saves a new scan.
    func save(rooms: [CapturedRoom], name: String, capture: URL?, worldMap: ARWorldMap?) async throws -> SavedScan {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Scan" : trimmed

        let folder = uniqueFolder(for: displayName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scan = SavedScan(
            folder: folder,
            meta: ScanMeta(name: displayName, date: .now, roomCount: rooms.count, hasMergedModel: false, sessionCount: 1))
        return try await write(scan, rooms: rooms, capture: capture, worldMap: worldMap)
    }

    /// Adds rooms from a later session to an existing scan. The session must have been
    /// relocalised with the scan's world map, so the new rooms share its coordinates.
    func append(rooms newRooms: [CapturedRoom], to scan: SavedScan, capture: URL?, worldMap: ARWorldMap?) async throws -> SavedScan {
        var scan = scan
        let existing = (try? loadRooms(for: scan)) ?? []
        scan.meta.sessionCount = (scan.meta.sessionCount ?? 1) + 1
        return try await write(scan, rooms: existing + newRooms, capture: capture, worldMap: worldMap)
    }

    /// Writes every file for the scan: models, room data, exports, photos, world map, ZIP.
    private func write(_ scan: SavedScan, rooms: [CapturedRoom], capture: URL?, worldMap: ARWorldMap?) async throws -> SavedScan {
        var scan = scan
        scan.meta.roomCount = rooms.count
        scan.meta.hasMergedModel = false
        try? FileManager.default.removeItem(at: scan.mergedModelURL)

        for (index, room) in rooms.enumerated() {
            try room.export(to: scan.roomModelURL(index))
        }
        if rooms.count > 1 {
            do {
                let builder = StructureBuilder(options: [.beautifyObjects])
                let structure = try await builder.capturedStructure(from: rooms)
                try structure.export(to: scan.mergedModelURL)
                scan.meta.hasMergedModel = true
            } catch {
                // The rooms are still saved one by one, so this is not fatal.
                print("Could not merge rooms: \(error)")
            }
        }

        try JSONEncoder().encode(rooms).write(to: scan.roomsDataURL)
        try writeExports(for: scan, rooms: rooms)
        try JSONEncoder().encode(scan.meta).write(to: scan.folder.appending(path: "meta.json"))

        if let worldMap,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: worldMap, requiringSecureCoding: true) {
            try? data.write(to: scan.worldMapURL)
        }

        if let capture {
            mergeCapture(capture, into: scan, session: scan.meta.sessionCount ?? 1)
        }
        do {
            try makePackage(for: scan)
        } catch {
            print("Could not create house-scan.zip: \(error)")
        }

        reload()
        return scan
    }

    /// Moves a session's video and photos into the scan. Photos are renumbered after the
    /// existing ones and added to keyframes.json.
    private func mergeCapture(_ capture: URL, into scan: SavedScan, session: Int) {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: capture) }

        let suffix = session == 1 ? "" : "-\(session)"
        try? fm.createDirectory(at: scan.folder.appending(path: "mesh"), withIntermediateDirectories: true)
        for (from, to) in [("video.mp4", "video\(suffix).mp4"), ("video-poses.json", "video-poses\(suffix).json"),
                           ("mesh.ply", "mesh/mesh-\(session).ply")] {
            let source = capture.appending(path: from), target = scan.folder.appending(path: to)
            guard fm.fileExists(atPath: source.path) else { continue }
            try? fm.removeItem(at: target)
            try? fm.moveItem(at: source, to: target)
        }

        let decoder = JSONDecoder()
        var frames = (try? decoder.decode(FrameRecorder.StoredFrames.self, from: Data(contentsOf: scan.keyframesURL)))?.frames ?? []
        let newFrames = (try? decoder.decode(FrameRecorder.StoredFrames.self, from: Data(contentsOf: capture.appending(path: "keyframes.json"))))?.frames ?? []
        guard !newFrames.isEmpty else { return }

        try? fm.createDirectory(at: scan.folder.appending(path: "keyframes"), withIntermediateDirectories: true)
        var number = frames.count
        for frame in newFrames {
            guard let file = frame.file else { continue }
            var name: String
            repeat {
                number += 1
                name = String(format: "keyframes/%04d.jpg", number)
            } while fm.fileExists(atPath: scan.folder.appending(path: name).path)
            guard (try? fm.moveItem(at: capture.appending(path: file), to: scan.folder.appending(path: name))) != nil else { continue }
            frames.append(FrameRecorder.Frame(
                file: name, time: frame.time, width: frame.width, height: frame.height,
                intrinsics: frame.intrinsics, transform: frame.transform))
        }
        let file = FrameRecorder.FrameFile(format: "house-scanner-keyframes", frames: frames)
        try? JSONEncoder().encode(file).write(to: scan.keyframesURL)
    }

    /// Writes the JSON scene and DXF floor plan. Also used to fill them in for older scans.
    func writeExports(for scan: SavedScan, rooms: [CapturedRoom]) throws {
        try SceneExporter.data(rooms: rooms, name: scan.meta.name, date: scan.meta.date)
            .write(to: scan.sceneJSONURL)
        try DXFExporter.string(rooms: rooms).write(to: scan.dxfURL, atomically: true, encoding: .utf8)
    }

    /// Builds house-scan.zip (see PackageBuilder).
    func makePackage(for scan: SavedScan) throws {
        guard FileManager.default.fileExists(atPath: scan.sceneJSONURL.path) else { return }
        try PackageBuilder.build(for: scan)
    }

    // MARK: - Reading and managing

    func loadRooms(for scan: SavedScan) throws -> [CapturedRoom] {
        let data = try Data(contentsOf: scan.roomsDataURL)
        return try JSONDecoder().decode([CapturedRoom].self, from: data)
    }

    nonisolated static func loadWorldMap(_ scan: SavedScan) -> ARWorldMap? {
        guard let data = try? Data(contentsOf: scan.worldMapURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data)
    }

    func rename(_ scan: SavedScan, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var meta = scan.meta
        meta.name = trimmed
        try? JSONEncoder().encode(meta).write(to: scan.folder.appending(path: "meta.json"))
        reload()
    }

    func delete(_ scan: SavedScan) {
        try? FileManager.default.removeItem(at: scan.folder)
        reload()
    }

    /// Readable folder names so scans are easy to find in the Files app.
    private func uniqueFolder(for name: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let safeName = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        let base = "\(formatter.string(from: .now)) \(safeName)"
        var folder = root.appending(path: base, directoryHint: .isDirectory)
        var counter = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = root.appending(path: "\(base) \(counter)", directoryHint: .isDirectory)
            counter += 1
        }
        return folder
    }
}
