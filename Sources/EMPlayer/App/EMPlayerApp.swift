import SwiftUI
import AVFoundation
import Kingfisher
import EMPlayerCore

/// Kingfisher 图片加载的 SSL 挑战响应：命中「跳过 SSL 验证」主机时信任自签名证书
/// 注意：Kingfisher 7.x 协议名为 AuthenticationChallengeResponsible（旧 typo 名 Responsable 已废弃）
final class EmbyImageAuthChallenge: NSObject, AuthenticationChallengeResponsible {
    func downloader(_ downloader: ImageDownloader,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        // 与 EmbyClient 的 URLSession 委托共用同一套按主机信任状态（线程安全）
        if EmbyClient.shared.shouldTrustServer(host: challenge.protectionSpace.host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

@main
struct EMPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared
    @StateObject private var serverStore = ServerStore.shared

    /// 强引用持有 Kingfisher 挑战响应器（Kingfisher 内部为 weak 引用）
    private static let imageChallenge = EmbyImageAuthChallenge()

    init() {
        // Register appearance proxies
        let navBarAppearance = UINavigationBarAppearance()
        navBarAppearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance = navBarAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navBarAppearance
        UINavigationBar.appearance().compactAppearance = navBarAppearance
        UINavigationBar.appearance().tintColor = .systemIndigo

        // 图片加载同样支持「跳过 SSL 验证」（自签名 HTTPS 服务器的封面图）
        KingfisherManager.shared.downloader.authenticationChallengeResponder = Self.imageChallenge

        // Kingfisher 请求注入 Emby 鉴权头（部分服务器仅认 header 不认 query param）
        KingfisherManager.shared.downloader.requestModifier = AnyModifier { request in
            var req = request
            if let token = EmbyClient.shared.accessToken, !token.isEmpty {
                req.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "X-Emby-Authorization")
            }
            return req
        }

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
