import SwiftUI

@main struct TallyApp: App {
    @State private var store = TallyStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.tallyAccent)
                .onOpenURL { url in
                    if url.host == "home" { store.selectedTab = 0 }
                    if url.host == "link-complete" { store.reconnectURL = nil }
                }
                .overlay {
                    if phase != .active {
                        ZStack { Color(uiColor: .systemBackground).ignoresSafeArea(); Image(systemName: "leaf.fill").font(.system(size: 48)).foregroundStyle(Color.tallyAccent) }
                    }
                }
                .onChange(of: phase) { _, value in
                    if value == .background { store.lock() }
                    if value == .active { Task { await store.becameActive() } }
                }
        }
    }
}