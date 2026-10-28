import PodcastCore
import SwiftUI

@MainActor
@main struct QuietCastApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(store)
                .onOpenURL { url in Task { await store.handle(url) } }
                .onChange(of: scenePhase) { phase in
                    if phase != .active { store.sceneBackground() }
                    else { store.revalidate() }
                }
        }
    }
}
