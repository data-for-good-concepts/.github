import SwiftUI
import WebKit

// MARK: - Settings

enum CloudSettings {
    static let serverKey = "renderServerURL"
    static let tokenKey = "renderToken"
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(CloudSettings.serverKey) private var server = ""
    @AppStorage(CloudSettings.tokenKey) private var token = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://house-renderer-….run.app", text: $server)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Access token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Render server")
                } footer: {
                    Text("The address of your House Renderer service on Google Cloud Run and the token you set when deploying it. Scans are uploaded there and rendered in the cloud; this phone only shows the picture.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Upload

/// Remembers which upload belongs to which version of a scan's package, so it isn't sent twice.
private struct CloudRecord: Codable {
    let server: String
    let id: String
    let packageDate: Date
}

private struct UploadReply: Decodable {
    let id: String
}

@MainActor
final class ScanUploader: NSObject, ObservableObject, URLSessionTaskDelegate {
    enum State: Equatable {
        case idle
        case uploading
        case ready(URL)
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var progress: Double = 0

    func start(scan: SavedScan, server: String, token: String, force: Bool = false) async {
        let trimmed = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmed), let scheme = base.scheme, scheme.hasPrefix("http") else {
            state = .failed("Add your render server's address in Settings first.")
            return
        }
        guard scan.hasPackage else {
            state = .failed("This scan has no package to upload yet.")
            return
        }

        let recordURL = scan.folder.appending(path: "cloud.json")
        let packageDate = ((try? FileManager.default.attributesOfItem(atPath: scan.packageURL.path))?[.modificationDate] as? Date) ?? .distantPast
        if !force,
           let data = try? Data(contentsOf: recordURL),
           let record = try? JSONDecoder().decode(CloudRecord.self, from: data),
           record.server == trimmed, record.packageDate == packageDate {
            state = .ready(viewURL(base: base, id: record.id, token: token))
            return
        }

        var request = URLRequest(url: base.appending(path: "api/scans"))
        request.httpMethod = "POST"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 600

        state = .uploading
        progress = 0
        do {
            let (data, response) = try await URLSession.shared.upload(for: request, fromFile: scan.packageURL, delegate: self)
            guard let http = response as? HTTPURLResponse else {
                state = .failed("No answer from the server.")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? ""
                state = .failed(http.statusCode == 401
                                ? "The server refused the access token. Check it in Settings."
                                : "The server answered with error \(http.statusCode). \(message)")
                return
            }
            let reply = try JSONDecoder().decode(UploadReply.self, from: data)
            let record = CloudRecord(server: trimmed, id: reply.id, packageDate: packageDate)
            try? JSONEncoder().encode(record).write(to: recordURL)
            state = .ready(viewURL(base: base, id: reply.id, token: token))
        } catch {
            state = .failed("Upload failed: \(error.localizedDescription)")
        }
    }

    private func viewURL(base: URL, id: String, token: String) -> URL {
        var components = URLComponents(url: base.appending(path: "view/\(id)"), resolvingAgainstBaseURL: false)!
        if !token.isEmpty {
            // The token goes after "#", so it is never sent in request logs; the page reads it itself.
            components.fragment = "token=" + (token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? token)
        }
        return components.url!
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                                totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        let value = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        Task { @MainActor in self.progress = value }
    }
}

// MARK: - Screen

/// Uploads the scan, then shows the live picture rendered in the cloud.
struct CloudRenderView: View {
    let scan: SavedScan

    @Environment(\.dismiss) private var dismiss
    @AppStorage(CloudSettings.serverKey) private var server = ""
    @AppStorage(CloudSettings.tokenKey) private var token = ""
    @StateObject private var uploader = ScanUploader()

    var body: some View {
        NavigationStack {
            Group {
                switch uploader.state {
                case .idle, .uploading:
                    VStack(spacing: 16) {
                        ProgressView(value: uploader.progress)
                            .frame(maxWidth: 260)
                        Text("Uploading scan… \(Int(uploader.progress * 100))%")
                            .font(.headline)
                            .monospacedDigit()
                        Text("Photos and the LiDAR mesh are sent to your render server. Videos stay on the phone.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                case .ready(let url):
                    StreamWebView(url: url)
                        .ignoresSafeArea(edges: .bottom)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't open the cloud rendering", systemImage: "exclamationmark.icloud")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { Task { await uploader.start(scan: scan, server: server, token: token, force: true) } }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(scan.meta.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Upload again", systemImage: "arrow.clockwise.icloud") {
                            Task { await uploader.start(scan: scan, server: server, token: token, force: true) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { await uploader.start(scan: scan, server: server, token: token) }
    }
}

/// Shows the server's thin client page, which displays the streamed picture and sends touches back.
struct StreamWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.scrollView.isScrollEnabled = false
        view.scrollView.bounces = false
        view.isOpaque = false
        view.backgroundColor = .black
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
