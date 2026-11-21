import AVKit
import QuickLook
import RoomPlan
import SwiftUI

struct ScanDetailView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss

    let scan: SavedScan

    @State private var rooms: [CapturedRoom] = []
    @State private var loadError: String?
    @State private var previewURL: URL?
    @State private var showMeasurements = true
    @State private var showingRename = false
    @State private var newName = ""
    @State private var showingDeleteConfirm = false
    @State private var showingVideo = false

    var body: some View {
        let summary = ScanSummary(rooms: rooms)

        List {
            Section {
                FloorPlanView(rooms: rooms, showMeasurements: showMeasurements)
                    .frame(height: 380)
                    .listRowInsets(EdgeInsets())
                Toggle("Show wall lengths", isOn: $showMeasurements)
                legend
            } header: {
                Text("Floor plan")
            } footer: {
                if let loadError { Text(loadError).foregroundStyle(.red) }
            }

            Section {
                Button {
                    previewURL = scan.mainModelURL
                } label: {
                    Label(scan.meta.roomCount > 1 && scan.meta.hasMergedModel
                          ? "View whole house in 3D / AR" : "View in 3D / AR",
                          systemImage: "cube.transparent")
                }

                if scan.meta.roomCount > 1 {
                    ForEach(0..<scan.meta.roomCount, id: \.self) { index in
                        Button {
                            previewURL = scan.roomModelURL(index)
                        } label: {
                            Label("Room \(index + 1)", systemImage: "square.dashed")
                        }
                    }
                }

            } header: {
                Text("3D model")
            } footer: {
                if scan.meta.roomCount > 1 && !scan.meta.hasMergedModel {
                    Text("The rooms couldn't be joined into one model, but you can still open each room on its own.")
                }
            }

            Section {
                if scan.hasPackage {
                    ShareLink(item: scan.packageURL) {
                        exportLabel("Scan with textures", "ZIP · open in the web viewer for textured walls and floors", "photo.on.rectangle")
                    }
                }
                if scan.hasVideo {
                    Button {
                        showingVideo = true
                    } label: {
                        Label("Watch camera video", systemImage: "play.rectangle")
                    }
                    ShareLink(item: scan.videoURL) {
                        exportLabel("Camera video", "MP4 · recorded during the scan", "video")
                    }
                }
                ShareLink(item: scan.sceneJSONURL) {
                    exportLabel("Scene for 3D web apps", "JSON · walls, doors, windows, furniture", "curlybraces")
                }
                ShareLink(item: scan.dxfURL) {
                    exportLabel("Floor plan for CAD", "DXF · 2D plan with 3D walls, in metres", "ruler")
                }
                ShareLink(item: scan.mainModelURL) {
                    exportLabel("3D model", "USDZ · opens on iPhone, Mac, Blender", "cube")
                }
            } header: {
                Text("Export")
            } footer: {
                Text("Use AirDrop to send files to your Mac. All files are also in the Files app under On My iPhone → House Scanner.")
            }

            Section("Summary") {
                LabeledContent("Rooms", value: "\(scan.meta.roomCount)")
                LabeledContent("Floor area", value: summary.floorArea > 0 ? "≈ " + Format.squareMetres(summary.floorArea) : "—")
                if let height = summary.ceilingHeight {
                    LabeledContent("Ceiling height", value: "≈ " + Format.metres(height))
                }
                LabeledContent("Walls", value: "\(summary.walls)")
                LabeledContent("Doors", value: "\(summary.doors)")
                LabeledContent("Windows", value: "\(summary.windows)")
                if summary.openings > 0 {
                    LabeledContent("Open doorways", value: "\(summary.openings)")
                }
                LabeledContent("Scanned", value: scan.meta.date.formatted(date: .long, time: .shortened))
            }

            if !summary.objectCounts.isEmpty {
                Section("Furniture & appliances") {
                    ForEach(summary.objectCounts, id: \.name) { item in
                        LabeledContent(item.name, value: "\(item.count)")
                    }
                }
            }

            Section {
                Button("Rename") {
                    newName = currentName
                    showingRename = true
                }
                Button("Delete scan", role: .destructive) {
                    showingDeleteConfirm = true
                }
            }
        }
        .navigationTitle(currentName)
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($previewURL)
        .task { load() }
        .sheet(isPresented: $showingVideo) {
            VideoPlayer(player: AVPlayer(url: scan.videoURL))
                .ignoresSafeArea()
        }
        .alert("Rename scan", isPresented: $showingRename) {
            TextField("Name", text: $newName)
            Button("Save") { store.rename(scan, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this scan?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(scan)
                dismiss()
            }
        }
    }

    /// Picks up renames, since `scan` itself is a snapshot.
    private var currentName: String {
        store.scans.first { $0.id == scan.id }?.meta.name ?? scan.meta.name
    }

    private func exportLabel(_ title: String, _ detail: String, _ icon: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(.primary, "Wall")
            legendItem(.orange, "Door")
            legendItem(.cyan, "Window")
            legendItem(.gray.opacity(0.6), "Furniture")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 14, height: 4)
            Text(title)
        }
    }

    private func load() {
        do {
            rooms = try store.loadRooms(for: scan)
            let fm = FileManager.default
            if !fm.fileExists(atPath: scan.sceneJSONURL.path) || !fm.fileExists(atPath: scan.dxfURL.path) {
                try? store.writeExports(for: scan, rooms: rooms)
            }
        } catch {
            loadError = "Couldn't read the floor plan data: \(error.localizedDescription)"
        }
    }
}
