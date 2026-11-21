import Foundation
import SwiftUI

@main
struct HouseScannerApp: App {
    @StateObject private var store = ScanStore()

    init() {
        #if DEBUG
        // Send each console line straight away when the console is a pipe (devicectl --console).
        setvbuf(stdout, nil, _IOLBF, 0)
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}
