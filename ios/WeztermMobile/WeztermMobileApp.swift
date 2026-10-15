import SwiftUI

@main
struct WeztermMobileApp: App {
    var body: some Scene {
        WindowGroup {
            if UIDevice.current.userInterfaceIdiom == .pad {
                PadRootView()
            } else {
                ConnectView()   // iPhone: 既存フローそのまま
            }
        }
    }
}
