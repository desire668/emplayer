import SwiftUI
import AVFoundation
import EMPlayerCore

@main
struct EMPlayerApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var serverStore = ServerStore.shared
    
    init() {
        // Register appearance proxies
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance
        UINavigationBar.appearance().tintColor = .systemIndigo
        
        // Background audio category (even when app is in background)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, policy: .longFormAudio, options: [.allowBluetoothHFP, .allowBluetoothA2DP, .allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("[App] Audio session init error: \(error)")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(serverStore)
                .preferredColorScheme(.dark)
                .tint(.indigo)
                .onAppear {
                    // Auto-connect last active server
                    if let server = serverStore.activeServer {
                        Task { @MainActor in
                            await appState.connect(to: server)
                        }
                    }
                }
        }
    }
}
