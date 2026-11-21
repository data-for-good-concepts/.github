import AVKit
import QuickLook
import RoomPlan
import SwiftUI

struct ScanDetailView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss

    /// The scan as it was when opened; `scan` below always reads the latest saved version.
    let initialScan: SavedScan

    @State private var rooms: [CapturedRoom] = []
    @State private var loadError: String?
    @State private var previewURL: URL?
    @State private var videoURL: URL?
    @State private var showMeasurements = true
    @State private var showingRename = false
    @State private var newName = ""
    @State private var showingDeleteConfirm = false
    @State private var showingAddRooms = false
    @State private var videoPackageURL: URL?
    @State private var preparingVideoPackage = false

    init(scan: SavedScan) {
        initialScan = scan
    }

    /// Picks up renames and added rooms.
    private var scan: SavedScan {
        store.scans.first { $0.id == initialScan.id } ?? initialScan
    }

    var body: some View {
        let scan = self.scan
        let summary = ScanSummary(rooms: rooms)
        let videos = scan.videoURLs

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
                    showingAddRooms = true
                } label: {
                    Label("Add rooms to this scan", systemImage: "plus.square.on.square")
                }
                .disabled(!scan.canAddRooms || !RoomCaptureSession.isSupported)
            } footer: {
                Text(scan.canAddRooms
                     ? "Start in a room you already scanned so the phone can recognise it. New rooms join onto this scan, with their photos and video."
                     : "This scan has no saved map of the place, so new rooms can't be lined up with it.")
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

            if !videos.isEmpty {
                Section("Camera video") {
                    ForEach(Array(videos.enumerated()), id: \.element) { index, url in
                        HStack {
                            Button {
                                videoURL = url
                            } label: {
                                Label(videos.count == 1 ? "Watch video" : "Watch session \(index + 1)", systemImage: "play.rectangle")
                            }
                            Spacer()
                            ShareLink(item: url) {
                                Image(systemName: "square.and.arrow.up")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                if scan.hasPackage {
                    ShareLink(item: scan.packageURL) {
                        exportLabel("Scan package for Claude", "ZIP · rooms, full-resolution photos, LiDAR depth and mesh, camera poses, README", "shippingbox")
                    }
                }
                if !videos.isEmpty {
                    if let videoPackageURL {
                        ShareLink(item: videoPackageURL) {
                            exportLabel("Package with video", "ZIP · the above plus every session's video (large)", "film.stack")
                        }
                    } else {
                        Button {
                            prepareVideoPackage(scan)
                        } label: {
                            HStack {
                                exportLabel("Package with video", "Tap to prepare · adds every session's video (large)", "film.stack")
                                if preparingVideoPackage {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(preparingVideoPackage)
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
                Text("Give the scan package to Claude to build a photoreal 3D rendering: its README explains every file. Send it with AirDrop, or save it to Google Drive or Dropbox from the share sheet. All files are also in the Files app under On My iPhone → House Scanner.")
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
                if let sessions = scan.meta.sessionCount, sessions > 1 {
                    LabeledContent("Scanning sessions", value: "\(sessions)")
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
                    newName = scan.meta.name
                    showingRename = true
                }
                Button("Delete scan", role: .destructive) {
                    showingDeleteConfirm = true
                }
            }
        }
        .navigationTitle(scan.meta.name)
        .navigationBarTitleDisplayMode(.inline)
        .quickLookPreview($previewURL)
        .task { load() }
        .sheet(isPresented: Binding(get: { videoURL != nil }, set: { if !$0 { videoURL = nil } })) {
            if let videoURL {
                VideoPlayer(player: AVPlayer(url: videoURL))
                    .ignoresSafeArea()
            }
        }
        .fullScreenCover(isPresented: $showingAddRooms, onDismiss: load) {
            ScanView(continuing: scan) { _ in }
                .environmentObject(store)
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

    private func prepareVideoPackage(_ scan: SavedScan) {
        preparingVideoPackage = true
        Task {
            let url = await Task.detached { try? PackageBuilder.build(for: scan, includeVideo: true) }.value
            preparingVideoPackage = false
            videoPackageURL = url
            if url == nil { loadError = "Couldn't prepare the package with video. Check there is enough free space on the phone." }
        }
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
        let scan = self.scan
        do {
            rooms = try store.loadRooms(for: scan)
            loadError = nil
            let fm = FileManager.default
            if !fm.fileExists(atPath: scan.sceneJSONURL.path) || !fm.fileExists(atPath: scan.dxfURL.path) {
                try? store.writeExports(for: scan, rooms: rooms)
            }
        } catch {
            loadError = "Couldn't read the floor plan data: \(error.localizedDescription)"
        }
    }
}
