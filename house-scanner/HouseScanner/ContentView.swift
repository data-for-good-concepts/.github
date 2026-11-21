import RoomPlan
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: ScanStore
    @State private var path: [SavedScan] = []
    @State private var showingScanner = false
    @State private var justSaved: SavedScan?

    private let isSupported = RoomCaptureSession.isSupported

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.scans.isEmpty {
                    emptyState
                } else {
                    scanList
                }
            }
            .navigationTitle("House Scanner")
            .navigationDestination(for: SavedScan.self) { scan in
                ScanDetailView(scan: scan)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    showingScanner = true
                } label: {
                    Label("New scan", systemImage: "camera.viewfinder")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isSupported)
                .padding()
                .background(.bar)
            }
        }
        .fullScreenCover(isPresented: $showingScanner, onDismiss: {
            if let scan = justSaved {
                path = [scan]
                justSaved = nil
            }
        }) {
            ScanView { scan in justSaved = scan }
                .environmentObject(store)
        }
    }

    private var scanList: some View {
        List {
            if !isSupported { unsupportedNotice }
            ForEach(store.scans) { scan in
                NavigationLink(value: scan) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(scan.meta.name).font(.headline)
                        Text("\(scan.meta.roomCount) room\(scan.meta.roomCount == 1 ? "" : "s") · \(scan.meta.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { offsets in
                offsets.map { store.scans[$0] }.forEach(store.delete)
            }
        }
    }

    private var emptyState: some View {
        VStack {
            if !isSupported { List { unsupportedNotice }.frame(maxHeight: 140) }
            ContentUnavailableView {
                Label("No scans yet", systemImage: "house")
            } description: {
                Text("Tap New scan and walk around a room. You can scan several rooms in a row and they will be joined into one model of your house.")
            }
        }
    }

    private var unsupportedNotice: some View {
        Label("This device has no LiDAR sensor, so it can't scan. You need an iPhone Pro (12 Pro or newer) or an iPad Pro.",
              systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
    }
}
