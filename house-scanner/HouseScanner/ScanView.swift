import RoomPlan
import SwiftUI

struct ScanView: View {
    @EnvironmentObject private var store: ScanStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = ScanController()

    @State private var showingNamePrompt = false
    @State private var showingDiscardConfirm = false
    @State private var scanName = ""
    @State private var isSaving = false

    /// Called with the saved scan right before the scanner closes.
    var onSaved: (SavedScan) -> Void

    var body: some View {
        ZStack {
            RoomCaptureViewRepresentable(controller: controller)
                .ignoresSafeArea()

            VStack {
                topBar
                Spacer()
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
        .onAppear { controller.startRoom() }
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

            if !controller.rooms.isEmpty {
                Label("\(controller.rooms.count)", systemImage: "square.split.bottomrightquarter")
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    @ViewBuilder
    private var bottomControls: some View {
        switch controller.phase {
        case .idle:
            bigButton("Start scanning", systemImage: "camera.viewfinder") {
                controller.startRoom()
            }

        case .scanning:
            VStack(spacing: 12) {
                hint("Move slowly around the room. Point the camera at every wall, door, window and piece of furniture.")
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
                hint("To add another room, walk into it through the doorway, then tap Scan next room. Rooms scanned in one go are joined together.")
                HStack(spacing: 12) {
                    bigButton("Scan next room", systemImage: "plus.circle.fill", prominent: false) {
                        controller.startRoom()
                    }
                    bigButton("Finish & save", systemImage: "square.and.arrow.down.fill") {
                        scanName = ""
                        showingNamePrompt = true
                    }
                }
            }
        }
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
                let scan = try await store.save(rooms: controller.rooms, name: scanName)
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
