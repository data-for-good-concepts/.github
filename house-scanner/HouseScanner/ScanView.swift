import ARKit
import RoomPlan
import SwiftUI

struct ScanView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: ScanController

    @State private var showingNamePrompt = false
    @State private var showingDiscardConfirm = false
    @State private var scanName = ""
    @State private var isSaving = false

    /// The scan being added to, or nil for a new scan.
    private let continuing: SavedScan?
    /// Called with the saved scan right before the scanner closes.
    private let onSaved: (SavedScan) -> Void

    init(continuing: SavedScan? = nil, onSaved: @escaping (SavedScan) -> Void) {
        self.continuing = continuing
        self.onSaved = onSaved
        _controller = StateObject(wrappedValue: ScanController(worldMap: continuing.flatMap(ScanStore.loadWorldMap)))
    }

    var body: some View {
        ZStack {
            if controller.phase == .relocalizing {
                CameraPreview(session: controller.arSession).ignoresSafeArea()
            } else {
                // Black canvas: only fully captured parts of the home appear, as they are captured.
                CoverageCanvasView(canvas: controller.canvas).ignoresSafeArea()
            }

            VStack(spacing: 12) {
                topBar
                captureHint
                if let instruction = controller.instruction, controller.phase == .scanning {
                    Label(instruction, systemImage: "exclamationmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                if controller.phase == .scanning, controller.capturedArea == 0 {
                    emptyCanvasHint
                }
                bottomControls
            }
            .padding()

            if isSaving {
                Color.black.opacity(0.5).ignoresSafeArea()
                ProgressView("Building your 3D model…")
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { controller.begin() }
        .onDisappear { controller.shutdown() }
        .alert("Name this scan", isPresented: $showingNamePrompt) {
            TextField("e.g. Ground floor", text: $scanName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(controller.rooms.count) room\(controller.rooms.count == 1 ? "" : "s") scanned.")
        }
        .confirmationDialog("Discard this scan?", isPresented: $showingDiscardConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep scanning", role: .cancel) {}
        } message: {
            Text("The rooms you have scanned so far will be lost.")
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { controller.errorMessage != nil },
                                    set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }

    // MARK: - Pieces

    private var topBar: some View {
        HStack {
            Button("Cancel") {
                if controller.rooms.isEmpty { dismiss() } else { showingDiscardConfirm = true }
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Spacer()

            if controller.capturedArea > 0 {
                Label(String(format: "%.1f m²", controller.capturedArea), systemImage: "square.dashed.inset.filled")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .accessibilityLabel(String(format: "%.1f square metres captured", controller.capturedArea))
            }
            if controller.meshFaceCount > 0 {
                Label(controller.meshFaceCount >= 1000 ? "\(controller.meshFaceCount / 1000)k" : "\(controller.meshFaceCount)",
                      systemImage: "cube.transparent")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if controller.photoCount > 0 {
                Label("\(controller.photoCount)", systemImage: "camera.fill")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            if !controller.rooms.isEmpty {
                Label("\(controller.rooms.count)", systemImage: "square.split.bottomrightquarter")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    /// "Hold still" nudge while a new viewpoint needs a photo, then a short "Photo saved".
    @ViewBuilder
    private var captureHint: some View {
        switch controller.captureHint {
        case .holdStill:
            Label("Hold still to reveal this area", systemImage: "camera.aperture")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.yellow, in: Capsule())
                .transition(.opacity)
        case .photoSaved:
            Label("Captured", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.green, in: Capsule())
                .transition(.opacity)
        case .none:
            EmptyView()
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        switch controller.phase {
        case .relocalizing:
            VStack(spacing: 10) {
                ProgressView()
                Text("Lining up with your earlier scan")
                    .font(.headline)
                Text(controller.relocalizationMessage)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

        case .idle:
            VStack(spacing: 12) {
                if controller.isContinuing {
                    hint("Lined up with your earlier scan. New rooms will join onto it.")
                }
                bigButton("Start scanning", systemImage: "camera.viewfinder") {
                    controller.startRoom()
                }
            }

        case .scanning:
            VStack(spacing: 12) {
                hint("Sweep each wall from floor to ceiling. Areas appear once they are fully captured: when the yellow sign shows, hold still for a moment.")
                bigButton("Done with this room", systemImage: "checkmark.circle.fill") {
                    controller.finishRoom()
                }
            }

        case .processing:
            ProgressView("Processing room…")
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

        case .roomDone:
            VStack(spacing: 12) {
                hint(controller.mapIsGoodForContinuing
                     ? "To add another room, walk into it through the doorway, then tap Scan next room. Rooms scanned in one go are joined together."
                     : "To add another room, walk into it through the doorway, then tap Scan next room. Before saving, look around a little more so you can add rooms to this scan later.")
                HStack(spacing: 12) {
                    bigButton("Scan next room", systemImage: "plus.circle.fill", prominent: false) {
                        controller.startRoom()
                    }
                    bigButton(continuing == nil ? "Finish & save" : "Add to scan", systemImage: "square.and.arrow.down.fill") {
                        if continuing == nil {
                            scanName = ""
                            showingNamePrompt = true
                        } else {
                            save()
                        }
                    }
                }
            }
        }
    }

    /// Shown on the black canvas until the first area has been captured.
    private var emptyCanvasHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "viewfinder")
                .font(.system(size: 40, weight: .light))
            Text("Nothing captured yet")
                .font(.headline)
            Text("Point the phone at a wall and hold still. Each area appears here in colour once it has been captured from two angles.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .foregroundStyle(.white.opacity(0.8))
        .padding(.bottom, 40)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func bigButton(_ title: String, systemImage: String, prominent: Bool = true,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(prominent ? Color.accentColor : Color.gray)
        .controlSize(.large)
    }

    private func save() {
        isSaving = true
        Task {
            do {
                let worldMap = await controller.currentWorldMap()
                let capture = await controller.finishRecording()
                let scan: SavedScan
                if let continuing {
                    scan = try await store.append(rooms: controller.rooms, to: continuing, capture: capture, worldMap: worldMap)
                } else {
                    scan = try await store.save(rooms: controller.rooms, name: scanName, capture: capture, worldMap: worldMap)
                }
                isSaving = false
                onSaved(scan)
                dismiss()
            } catch {
                isSaving = false
                controller.errorMessage = "Could not save the scan: \(error.localizedDescription)"
            }
        }
    }
}
