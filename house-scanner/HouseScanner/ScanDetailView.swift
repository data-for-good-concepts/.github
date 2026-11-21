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

                ShareLink(item: scan.mainModelURL) {
                    Label("Share 3D model (AirDrop to Mac…)", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("3D model")
            } footer: {
                if scan.meta.roomCount > 1 && !scan.meta.hasMergedModel {
                    Text("The rooms couldn't be joined into one model, but you can still open each room on its own.")
                }
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
        } catch {
            loadError = "Couldn't read the floor plan data: \(error.localizedDescription)"
        }
    }
}
