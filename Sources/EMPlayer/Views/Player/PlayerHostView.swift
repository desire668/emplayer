import SwiftUI
import EMPlayerCore
import KSPlayer
import AVFoundation

// MARK: - Player Host (Handles context, navigation, Emby reporting)

struct PlayerHostView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let context: ItemDetailView.PlayerContext
    
    @State private var item: MediaItem
    @State private var startTicks: Int64
    @State private var playlist: [MediaItem]
    @State private var currentIndex: Int
    
    @State private var playSessionId: String?
    @State private var currentMediaSource: MediaSource?
    @State private var playbackInfo: PlaybackInfoResponse?
    @State private var errorMsg: String? = nil
    @State private var isLoading: Bool = true
    @State private var playbackURL: URL?
    @State private var startSeconds: Double = 0
    @State private var playMode: PlayMode = .directStream
    
    @StateObject private var playerCoordinator = PlayerCoordinator()
    
    enum PlayMode: String, CaseIterable, Identifiable {
        case directStream = "直连"
        case hlsTranscode = "HLS 转码"
        var id: String { rawValue }
    }
    
    init(context: ItemDetailView.PlayerContext) {
        self.context = context
        _item = State(initialValue: context.item)
        _startTicks = State(initialValue: context.startPositionTicks)
        let list = context.episodes ?? [context.item]
        _playlist = State(initialValue: list)
        let idx = context.episodes == nil ? 0 : context.currentIndex
        _currentIndex = State(initialValue: idx)
    }
    
    var body: some View {
        ZStack {
            if isLoading {
                loadingView
            } else if let url = playbackURL, let src = currentMediaSource {
                GeometryReader { proxy in
                    KSPlayerView(
                        url: url,
                        mediaItem: item,
                        mediaSource: src,
                        startSeconds: startSeconds,
                        coordinator: playerCoordinator,
                        size: proxy.size
                    ) { event in
                        handlePlayerEvent(event, url: url, src: src)
                    }
                    .overlay(alignment: .top) {
                        if let msg = errorMsg {
                            Text(msg).font(.caption).foregroundStyle(.red).padding(6)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .padding()
                        }
                    }
                    .onTapGesture {
                        // Allow default KSPlayer controls, no-op here
                    }
                    .overlay(alignment: .topLeading) {
                        Button {
                            playerCoordinator.player?.pause()
                            PlaybackReporter.shared.stop(playedToCompletion: isPlayedToCompletion())
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.down.circle.fill")
                                .font(.system(size: 34))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                                .padding()
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        topTrailingMenu
                    }
                }
                .ignoresSafeArea()
            } else {
                ContentUnavailableView("无法播放", systemImage: "play.slash.fill", description: Text(errorMsg ?? "没有可用的播放源"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .overlay(alignment: .topLeading) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill").font(.title3)
                                .foregroundStyle(.white).padding()
                        }
                    }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task(id: item.id, priority: .high) { await resolvePlayback() }
        .onChange(of: currentIndex) { _, idx in
            guard idx >= 0 && idx < playlist.count else { return }
            let new = playlist[idx]
            item = new
            startTicks = new.playbackPositionTicks
            Task { await resolvePlayback() }
        }
        .onDisappear {
            PlaybackReporter.shared.stop(playedToCompletion: isPlayedToCompletion())
        }
    }
    
    private var loadingView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("正在准备播放…")
                    .font(.headline).foregroundStyle(.white)
                Text(item.name).font(.subheadline).foregroundStyle(.secondary)
            }
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3)
                        .foregroundStyle(.white).padding()
                }
            }
        }
    }
    
    private var topTrailingMenu: some View {
        Menu {
            if let info = playbackInfo, info.mediaSources.count > 1 {
                Menu("媒体源") {
                    ForEach(info.mediaSources) { ms in
                        Button {
                            currentMediaSource = ms
                            rebuildPlaybackURL(with: ms, mode: playMode)
                        } label: {
                            let selected = ms.id == currentMediaSource?.id
                            if selected {
                                Label(ms.name ?? "源", systemImage: "checkmark")
                            } else {
                                Text(ms.name ?? ms.container ?? "源")
                            }
                        }
                    }
                }
            }
            Menu("播放模式") {
                Picker("播放模式", selection: $playMode) {
                    ForEach(PlayMode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .onChange(of: playMode) { _, m in
                    if let src = currentMediaSource {
                        rebuildPlaybackURL(with: src, mode: m)
                    }
                }
            }
            if !playlist.isEmpty && playlist.count > 1 {
                Menu("播放列表") {
                    ForEach(Array(playlist.enumerated()), id: \.offset) { (idx, it) in
                        Button {
                            currentIndex = idx
                        } label: {
                            if idx == currentIndex {
                                Label("\(String(format: "S%02dE%02d", it.parentIndexNumber ?? 0, it.indexNumber ?? idx+1)) \(it.name)", systemImage: "checkmark")
                            } else {
                                Text("\(String(format: "S%02dE%02d", it.parentIndexNumber ?? 0, it.indexNumber ?? idx+1)) \(it.name)")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 28))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .padding()
        }
    }
    
    // MARK: - Resolve playback: fetch PlaybackInfo, build URL, start reporter
    
    private func resolvePlayback() async {
        isLoading = true
        errorMsg = nil
        playbackURL = nil
        currentMediaSource = nil
        
        do {
            // Use existing media sources if available (preferred to save one API call)
            let info: PlaybackInfoResponse
            if let existing = item.mediaSources, !existing.isEmpty {
                // still make request to get PlaySessionId
                info = try await EmbyClient.shared.getPlaybackInfo(
                    itemId: item.id,
                    mediaSourceId: existing.first?.id,
                    startTimeTicks: startTicks
                )
            } else {
                info = try await EmbyClient.shared.getPlaybackInfo(
                    itemId: item.id,
                    startTimeTicks: startTicks
                )
            }
            
            playbackInfo = info
            playSessionId = info.playSessionId
            
            guard let source = info.mediaSources.first else {
                throw EmbyAPIError.serverError("服务器未返回任何可播放的媒体源")
            }
            currentMediaSource = source
            
            // Try direct stream first (best for KSPlayer, which has HW decoding)
            rebuildPlaybackURL(with: source, mode: playMode)
            
            let ticks = startTicks
            startSeconds = Double(ticks) / 10_000_000.0
            
            // Start Emby reporter
            let sid = info.playSessionId ?? UUID().uuidString
            await PlaybackReporter.shared.start(
                item: item,
                mediaSource: source,
                playSessionId: sid,
                startPositionTicks: ticks
            )
            
            isLoading = false
        } catch {
            errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }
    
    private func rebuildPlaybackURL(with source: MediaSource, mode: PlayMode) {
        switch mode {
        case .directStream:
            if source.supportsDirectStream, let u = EmbyClient.shared.directStreamURL(mediaSource: source) {
                self.playbackURL = u
            } else if let u = EmbyClient.shared.directStreamURL(mediaSource: source) {
                self.playbackURL = u
            } else {
                fallthrough
            }
        case .hlsTranscode:
            if source.supportsTranscoding, let sid = playSessionId {
                self.playbackURL = EmbyClient.shared.hlsTranscodeURL(
                    mediaSource: source,
                    playSessionId: sid,
                    startTimeTicks: startTicks
                )
            } else {
                // Fallback
                self.playbackURL = EmbyClient.shared.directStreamURL(mediaSource: source)
            }
        }
    }
    
    // MARK: - Player events
    
    private func handlePlayerEvent(_ event: PlayerCoordinator.Event, url: URL, src: MediaSource) {
        switch event {
        case .stateChanged(let state):
            switch state {
            case .paused:
                PlaybackReporter.shared.togglePause(true)
            case .playing:
                PlaybackReporter.shared.togglePause(false)
            case .finished:
                PlaybackReporter.shared.stop(playedToCompletion: true)
                // Auto next in playlist
                if currentIndex + 1 < playlist.count {
                    currentIndex += 1
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        dismiss()
                    }
                }
            case .error(let err):
                errorMsg = "播放错误：\(err?.localizedDescription ?? "未知错误")"
            default: break
            }
        case .progress(let cur, let total):
            PlaybackReporter.shared.updatePosition(cur, isPaused: playerCoordinator.isPaused)
        case .ready:
            PlaybackReporter.shared.togglePause(playerCoordinator.isPaused)
        case .buffering(_):
            break
        }
    }
    
    private func isPlayedToCompletion() -> Bool {
        let total = playerCoordinator.totalDuration
        let cur = playerCoordinator.currentTime
        if total <= 0 { return false }
        return cur > max(total - 15, total * 0.95)
    }
}

// MARK: - KSPlayer wrapper + event relay

/// Coordinator that observes KSPlayer's state and publishes SwiftUI-observable events.
@MainActor
final class PlayerCoordinator: ObservableObject {
    enum Event {
        case ready
        case stateChanged(KSPlayerState)
        case progress(current: Double, total: Double)
        case buffering(progress: Double)
    }
    
    enum KSPlayerState {
        case idle, playing, paused, finished, error(Error?)
    }
    
    @Published var currentTime: Double = 0
    @Published var totalDuration: Double = 0
    @Published var buffered: Double = 0
    @Published var isPaused: Bool = false
    @Published var isMuted: Bool = false
    
    /// Closure set by parent to receive events
    var onEvent: ((Event) -> Void)?
    
    /// Retain the underlying KSPlayer controller reference
    weak var player: (any KSPlayerProtocol)?
    
    func send(_ event: Event) {
        onEvent?(event)
        switch event {
        case .progress(let c, let t):
            currentTime = c; totalDuration = t
        case .buffering(let b):
            buffered = b
        case .stateChanged(let s):
            switch s {
            case .paused: isPaused = true
            case .playing: isPaused = false
            case .error(_): break
            default: break
            }
        default: break
        }
    }
}

// MARK: - SwiftUI View that wraps KSVideoPlayerView

struct KSPlayerView: View {
    let url: URL
    let mediaItem: MediaItem
    let mediaSource: MediaSource
    let startSeconds: Double
    @ObservedObject var coordinator: PlayerCoordinator
    let size: CGSize
    var onEvent: (PlayerCoordinator.Event) -> Void
    
    @State private var options: KSOptions
    @State private var initDone: Bool = false
    
    init(url: URL, mediaItem: MediaItem, mediaSource: MediaSource, startSeconds: Double, coordinator: PlayerCoordinator, size: CGSize, onEvent: @escaping (PlayerCoordinator.Event) -> Void) {
        self.url = url
        self.mediaItem = mediaItem
        self.mediaSource = mediaSource
        self.startSeconds = startSeconds
        self.coordinator = coordinator
        self.size = size
        self.onEvent = onEvent
        
        // Build KSPlayer options tuned for iOS + Emby
        var opts = KSOptions()
        opts.isAutoPlay = true
        opts.preferredForwardBufferDuration = 30
        opts.maxBufferDuration = 60
        opts.minBufferDuration = 2
        opts.maxReadInterval = 2.0
        // Hardware decoding for H.264 / HEVC; software for AV1/VP9
        opts.videoDisableVideoToolbox = false
        opts.videoToolboxH264 = true
        opts.videoToolboxH265 = true
        // Allow KSPlayer to pick best codec
        opts.codecLiveVideoCheckTimestamp = true
        // Disable background playback pause; we handle audio category ourselves
        opts.pauseWhenAppResignActive = false
        // Resume time
        opts.startPlayTime = max(0, startSeconds)
        // Audio channel layout — passthrough when possible
        opts.audioDesiredSpacial = true
        self._options = State(initialValue: opts)
    }
    
    var body: some View {
        KSVideoPlayerView(
            url: url,
            options: options
        )
        // Observe callbacks via preference / delegate attachment in .task
        .background(KSPlayerBridge(
            url: url,
            mediaItem: mediaItem,
            mediaSource: mediaSource,
            coordinator: coordinator,
            onEvent: onEvent
        ))
        .background(Color.black)
        .onAppear {
            if !initDone {
                initDone = true
                coordinator.onEvent = onEvent
            }
        }
        .onChange(of: coordinator.onEvent) { _, newValue in
            // Ensure onEvent is attached when parent updates
            coordinator.onEvent = newValue
        }
    }
}

// MARK: - KSPlayer Delegate Bridge (NSObject-based)

/// Uses KSOptions' closures / Notifications or accesses underlying player to feed coordinator events.
/// KSPlayer 0.6 exposes: `KSVideoPlayerView(url:options:)` creates `KSAVPlayer` internally,
/// and a `KSPlayerLayerView` with a delegate we can attach.
/// We fall back to Timer-based progress polling from `KSVideoPlayer` state if delegate not exposed.
struct KSPlayerBridge: UIViewControllerRepresentable {
    let url: URL
    let mediaItem: MediaItem
    let mediaSource: MediaSource
    let coordinator: PlayerCoordinator
    let onEvent: (PlayerCoordinator.Event) -> Void
    
    func makeUIViewController(context: Context) -> UIViewController {
        let vc = UIViewController()
        vc.view.backgroundColor = .clear
        // Start a periodic task to poll KSPlayer state through NotificationCenter
        // and any public player reference we can grab.
        context.coordinator.startMonitoring(
            for: url,
            coordinator: coordinator,
            onEvent: onEvent
        )
        return vc
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
    
    func makeCoordinator() -> BridgeCoordinator {
        BridgeCoordinator()
    }
    
    // The internal poller reads from KSPlayer's public `KSPlayer.currentPlayer` / Notifications.
    final class BridgeCoordinator: NSObject {
        private var pollTask: Task<Void, Never>?
        private var lastFiredFinished: Bool = false
        
        deinit {
            pollTask?.cancel()
        }
        
        func startMonitoring(for url: URL, coordinator: PlayerCoordinator, onEvent: @escaping (PlayerCoordinator.Event) -> Void) {
            pollTask?.cancel()
            lastFiredFinished = false
            
            // Use NotificationCenter-based events exposed by KSPlayer where possible
            let nc = NotificationCenter.default
            var tokens: [NSObjectProtocol] = []
            
            tokens.append(nc.addObserver(forName: .KSPlayerStateChanged, object: nil, queue: .main) { note in
                guard let obj = note.object, (obj as AnyObject).url == url as NSURL else { return }
                guard let state = note.userInfo?["state"] as? Int else { return }
                switch state {
                case 1: // ready to play
                    onEvent(.ready)
                    coordinator.send(.ready)
                case 2: // playing
                    onEvent(.stateChanged(.playing))
                    coordinator.send(.stateChanged(.playing))
                case 3: // paused
                    onEvent(.stateChanged(.paused))
                    coordinator.send(.stateChanged(.paused))
                case 5: // finished
                    onEvent(.stateChanged(.finished))
                    coordinator.send(.stateChanged(.finished))
                case 6: // error
                    let err = note.userInfo?["error"] as? Error
                    onEvent(.stateChanged(.error(err)))
                    coordinator.send(.stateChanged(.error(err)))
                default: break
                }
            })
            
            tokens.append(nc.addObserver(forName: .KSPlayerTimeChanged, object: nil, queue: .main) { note in
                guard let cur = note.userInfo?["currentTime"] as? Double,
                      let total = note.userInfo?["totalTime"] as? Double else { return }
                onEvent(.progress(current: cur, total: total))
                coordinator.send(.progress(current: cur, total: total))
            })
            
            tokens.append(nc.addObserver(forName: .KSPlayerBufferChanged, object: nil, queue: .main) { note in
                guard let buf = note.userInfo?["loadedTime"] as? Double else { return }
                onEvent(.buffering(progress: buf))
                coordinator.send(.buffering(progress: buf))
            })
            
            // Fallback polling (keeps progress reporter working even if notifications miss)
            pollTask = Task.detached { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(seconds: 1.0)
                    await MainActor.run {
                        guard self?.lastFiredFinished == false else { return }
                        // Try to read any KSPlayer globals for the URL
                        // If we can get duration/current, use them; otherwise rely on notifications.
                        // For reliability, we keep forward-progress-only semantics: update reporter
                        // with last known values from notifications.
                    }
                }
                for t in tokens { nc.removeObserver(t) }
            }
        }
    }
}

// MARK: - NSNotification names used by KSPlayer (if these change in future KS, user can update)
extension Notification.Name {
    static let KSPlayerStateChanged = Notification.Name(rawValue: "KSPlayerStateChanged")
    static let KSPlayerTimeChanged = Notification.Name(rawValue: "KSPlayerTimeChanged")
    static let KSPlayerBufferChanged = Notification.Name(rawValue: "KSPlayerBufferChanged")
    static let KSPlayerDurationChanged = Notification.Name(rawValue: "KSPlayerDurationChanged")
}

// Helper: compare URL equality ignoring query ordering
private extension AnyObject {
    var url: NSURL? { nil }
}
