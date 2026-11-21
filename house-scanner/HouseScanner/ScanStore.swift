import Foundation
import RoomPlan

/// Information saved next to every scan.
struct ScanMeta: Codable, Hashable {
    var name: String
    var date: Date
    var roomCount: Int
    var hasMergedModel: Bool
}

/// A scan saved on the phone. Each scan is a folder in Documents/Scans that holds:
/// - meta.json      name, date, number of rooms
/// - rooms.json     the raw RoomPlan data (used for the floor plan and stats)
/// - room-N.usdz    a 3D model of each room
/// - house.usdz     all rooms merged into one model (when there is more than one room)
/// - house-scene.json  clean JSON for building 3D scenes in JavaScript (three.js)
/// - floor-plan.dxf    floor plan for CAD programs (with 3D walls)
/// - video.mp4, video-poses.json, keyframes/, keyframes.json   camera recording (see FrameRecorder)
/// - house-scan.zip    house-scene.json + keyframes, for the textured web viewer
struct SavedScan: Identifiable, Hashable {
    let folder: URL
    var meta: ScanMeta

    var id: URL { folder }

    var mergedModelURL: URL { folder.appending(path: "house.usdz") }
    var roomsDataURL: URL { folder.appending(path: "rooms.json") }
    var sceneJSONURL: URL { folder.appending(path: "house-scene.json") }
    var dxfURL: URL { folder.appending(path: "floor-plan.dxf") }
    var videoURL: URL { folder.appending(path: "video.mp4") }
    var keyframesURL: URL { folder.appending(path: "keyframes.json") }
    /// house-scene.json + keyframes, zipped, for the textured web viewer.
    var packageURL: URL { folder.appending(path: "house-scan.zip") }

    var hasVideo: Bool { FileManager.default.fileExists(atPath: videoURL.path) }
    var hasPackage: Bool { FileManager.default.fileExists(atPath: packageURL.path) }

    func roomModelURL(_ index: Int) -> URL {
        folder.appending(path: "room-\(index + 1).usdz")
    }

    /// The best model to show: the merged house if it exists, otherwise the first room.
    var mainModelURL: URL {
        FileManager.default.fileExists(atPath: mergedModelURL.path) ? mergedModelURL : roomModelURL(0)
    }
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

    /// Saves the scanned rooms: one 3D model per room, a merged model of the whole house,
    /// and the raw data for the floor plan.
    func save(rooms: [CapturedRoom], name: String, capture: URL? = nil) async throws -> SavedScan {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Scan" : trimmed

        let folder = uniqueFolder(for: displayName)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var scan = SavedScan(
            folder: folder,
            meta: ScanMeta(name: displayName, date: .now, roomCount: rooms.count, hasMergedModel: false))

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

        if let capture {
            let fm = FileManager.default
            for item in ["video.mp4", "video-poses.json", "keyframes", "keyframes.json"] {
                let source = capture.appending(path: item)
                if fm.fileExists(atPath: source.path) {
                    try? fm.moveItem(at: source, to: folder.appending(path: item))
                }
            }
            try? fm.removeItem(at: capture)
            do {
                try makePackage(for: scan)
            } catch {
                print("Could not create house-scan.zip: \(error)")
            }
        }
        try JSONEncoder().encode(scan.meta).write(to: folder.appending(path: "meta.json"))

        reload()
        return scan
    }

    func loadRooms(for scan: SavedScan) throws -> [CapturedRoom] {
        let data = try Data(contentsOf: scan.roomsDataURL)
        return try JSONDecoder().decode([CapturedRoom].self, from: data)
    }

    /// Writes the JSON scene and DXF floor plan. Also used to fill them in for older scans.
    func writeExports(for scan: SavedScan, rooms: [CapturedRoom]) throws {
        try SceneExporter.data(rooms: rooms, name: scan.meta.name, date: scan.meta.date)
            .write(to: scan.sceneJSONURL)
        try DXFExporter.string(rooms: rooms).write(to: scan.dxfURL, atomically: true, encoding: .utf8)
    }

    /// Zips house-scene.json, keyframes.json and the keyframe photos into house-scan.zip.
    func makePackage(for scan: SavedScan) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: scan.keyframesURL.path) else { return }
        let staging = fm.temporaryDirectory.appending(path: "package-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = staging.appending(path: "house-scan", directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for item in ["house-scene.json", "keyframes.json", "keyframes"] {
            try fm.copyItem(at: scan.folder.appending(path: item), to: root.appending(path: item))
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
