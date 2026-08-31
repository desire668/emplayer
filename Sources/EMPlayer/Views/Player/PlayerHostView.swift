import SwiftUI
import EMPlayerCore
import KSPlayer
import AVFoundation
import UIKit

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
    @State private var hasStartedReporter: Bool = false
    
    @StateObject private var coordinator = PlayerCoordinator()
    
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
            Color.black.ignoresSafeArea()
            
            if isLoading {
                loadingView
            } else if let url = playbackURL, let src = currentMediaSource {
                GeometryReader { proxy in
                    KSPlayerUIViewWrapper(
                        url: url,
                        mediaItem: item,
                        startSeconds: startSeconds,
                        coordinator: coordinator,
                        size: proxy.size
                    )
                    .ignoresSafeArea()
                    .onAppear { ensureReporterStarted(src: src) }
                    .overlay(alignment: .top) {
                        if let msg = errorMsg {
                            Text(msg).font(.caption).foregroundStyle(.red).padding(6)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .padding()
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        Button {
                            coordinator.pause()
                            PlaybackReporter.shared.stop(playedToCompletion: isPlayedToCompletion())
                            hasStartedReporter = false
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
                    .onChange(of: coordinator.currentTime) { _, newTime in
                        if hasStartedReporter {
                            PlaybackReporter.shared.updatePosition(newTime, isPaused: coordinator.isPaused)
                        }
                    }
                    .onChange(of: coordinator.isPaused) { _, paused in
                        if hasStartedReporter {
                            PlaybackReporter.shared.togglePause(paused)
                        }
                    }
                    .onChange(of: coordinator.state) { _, newState in
                        handleState(newState)
                    }
                }
            } else {
                ContentUnavailableView("无法播放", systemImage: "play.slash.fill", description: Text(errorMsg ?? "没有可用的播放源"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            hasStartedReporter = false
            coordinator.reset()
            Task { await resolvePlayback() }
        }
        .onDisappear {
            if hasStartedReporter {
                PlaybackReporter.shared.stop(playedToCompletion: isPlayedToCompletion())
                hasStartedReporter = false
            }
        }
    }
    
    private var loadingView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().controlSize(.large).tint(.white)
                Text("正在准备播放…").font(.headline).foregroundStyle(.white)
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
                        coordinator.reset()
                    }
                }
            }
            if !playlist.isEmpty && playlist.count > 1 {
                Menu("播放列表") {
                    ForEach(Array(playlist.enumerated()), id: \.offset) { (idx, it) in
                        Button {
                            currentIndex = idx
                        } label: {
                            let label = episodeLabel(it, idx: idx)
                            if idx == currentIndex {
                                Label(label, systemImage: "checkmark")
                            } else {
                                Text(label)
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
    
    private func episodeLabel(_ it: MediaItem, idx: Int) -> String {
        if let s = it.parentIndexNumber, let e = it.indexNumber {
            return String(format: "S%02dE%02d %@", s, e, it.name)
        }
        return "\(idx + 1). \(it.name)"
    }
    
    // MARK: - Resolve playback
    
    private func resolvePlayback() async {
        isLoading = true
        errorMsg = nil
        playbackURL = nil
        currentMediaSource = nil
        
        do {
            let info: PlaybackInfoResponse
            if let existing = item.mediaSources, !existing.isEmpty {
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
            rebuildPlaybackURL(with: source, mode: playMode)
            
            startSeconds = Double(startTicks) / 10_000_000.0
            isLoading = false
        } catch {
            errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }
    
    private func rebuildPlaybackURL(with source: MediaSource, mode: PlayMode) {
        switch mode {
        case .directStream:
            self.playbackURL = EmbyClient.shared.directStreamURL(mediaSource: source) ?? EmbyClient.shared.hlsTranscodeURL(
                mediaSource: source,
                playSessionId: playSessionId ?? UUID().uuidString,
                startTimeTicks: startTicks
            )
        case .hlsTranscode:
            if source.supportsTranscoding, let sid = playSessionId {
                self.playbackURL = EmbyClient.shared.hlsTranscodeURL(
                    mediaSource: source,
                    playSessionId: sid,
                    startTimeTicks: startTicks
                )
            } else {
                self.playbackURL = EmbyClient.shared.directStreamURL(mediaSource: source)
            }
        }
    }
    
    private func ensureReporterStarted(src: MediaSource) {
        guard !hasStartedReporter else { return }
        hasStartedReporter = true
        let sid = playSessionId ?? UUID().uuidString
        Task {
            await PlaybackReporter.shared.start(
                item: item,
                mediaSource: src,
                playSessionId: sid,
                startPositionTicks: startTicks
            )
        }
    }
    
    // MARK: - State handling
    
    private func handleState(_ state: PlayerCoordinator.StateEx) {
        switch state {
        case .error(let err):
            errorMsg = "播放错误：\(err?.localizedDescription ?? "未知错误")"
        case .finished:
            if hasStartedReporter {
                PlaybackReporter.shared.stop(playedToCompletion: true)
                hasStartedReporter = false
            }
            if currentIndex + 1 < playlist.count {
                currentIndex += 1
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    dismiss()
                }
            }
        case .paused, .playing, .ready, .buffering:
            break
        }
    }
    
    private func isPlayedToCompletion() -> Bool {
        let total = coordinator.totalDuration
        let cur = coordinator.currentTime
        if total <= 0 { return false }
        return cur > max(total - 15, total * 0.95)
    }
}

// MARK: - Coordinator

@MainActor
final class PlayerCoordinator: ObservableObject {
    enum StateEx {
        case ready, playing, paused, buffering, finished, error(Error?)
    }
    
    @Published var currentTime: Double = 0
    @Published var totalDuration: Double = 0
    @Published var isPaused: Bool = false
    @Published var state: StateEx = .ready
    
    weak var playerView: KSPlayer.IOSVideoPlayerView?
    
    func play() { playerView?.play() }
    func pause() { playerView?.pause() }
    func seek(to seconds: Double) { playerView?.seek(time: seconds, completionHandler: nil) }
    
    func reset() {
        currentTime = 0
        totalDuration = 0
        isPaused = false
        state = .ready
    }
}

// MARK: - IOSVideoPlayerView SwiftUI Wrapper (UIViewRepresentable)

/// SwiftUI wrapper for the official KSPlayer `IOSVideoPlayerView` (UIKit).
/// Uses the official callbacks: `playTimeDidChange`, `stateChanged`, `playDone`, etc.
struct KSPlayerUIViewWrapper: UIViewRepresentable {
    let url: URL
    let mediaItem: MediaItem
    let startSeconds: Double
    @ObservedObject var coordinator: PlayerCoordinator
    let size: CGSize
    
    func makeUIView(context: Context) -> KSPlayer.IOSVideoPlayerView {
        let player = KSPlayer.IOSVideoPlayerView()
        
        // ==== 构建 KSOptions（只用官方文档确认存在的 API）====
        let options = KSOptions()
        options.hardwareDecode = true
        options.preferredForwardBufferDuration = 30
        options.maxBufferDuration = 60
        options.isSecondOpen = true
        options.isAccurateSeek = true
        options.startPlayTime = max(0, startSeconds)
        options.autoSelectEmbedSubtitle = true
        options.asynchronousDecompression = true
        
        // 构造 Emby 自定义 User-Agent + 鉴权头（防止部分服务器拒绝）
        if let token = EmbyClient.shared.accessToken ?? EmbyClient.shared.currentServer?.apiKey {
            options.userAgent = "EMPlayer/1.0 (iOS) X-MediaBrowser-Token/\(token)"
            options.avOptions = [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": "EMPlayer/1.0 iOS",
                    "X-Emby-Token": token
                ]
            ] as [String: Any]
        }
        
        // ==== 构造 KSPlayerResource（支持多种清晰度/子轨）====
        let coverURL = EmbyClient.shared.primaryImageURL(for: mediaItem, maxWidth: 400)
        let def = KSPlayerResourceDefinition(
            url: url,
            definition: mediaItem.name,
            options: options
        )
        let resource = KSPlayerResource(
            name: mediaItem.name,
            definitions: [def],
            cover: coverURL
        )
        
        // ==== 注册回调 ====
        context.coordinator.boundPlayerView = player
        context.coordinator.outerCoordinator = coordinator
        
        player.playTimeDidChange = { current, total in
            Task { @MainActor in
                context.coordinator.outerCoordinator?.currentTime = current
                context.coordinator.outerCoordinator?.totalDuration = total
            }
        }
        player.playerStateChange = { _, newState in
            Task { @MainActor in
                switch newState {
                case .playback:
                    context.coordinator.outerCoordinator?.state = .playing
                    context.coordinator.outerCoordinator?.isPaused = false
                case .paused, .loading:
                    if case .loading = newState {
                        context.coordinator.outerCoordinator?.state = .buffering
                    } else {
                        context.coordinator.outerCoordinator?.state = .paused
                        context.coordinator.outerCoordinator?.isPaused = true
                    }
                case .readyToPlay:
                    context.coordinator.outerCoordinator?.state = .ready
                case .bufferFinished:
                    break
                case .playedToTheEnd:
                    context.coordinator.outerCoordinator?.state = .finished
                case .error(let err):
                    context.coordinator.outerCoordinator?.state = .error(err)
                @unknown default:
                    break
                }
            }
        }
        
        player.set(resource: resource)
        player.play()
        coordinator.playerView = player
        
        return player
    }
    
    func updateUIView(_ uiView: KSPlayer.IOSVideoPlayerView, context: Context) {
        // no-op for now
    }
    
    func makeCoordinator() -> InnerCoordinator {
        InnerCoordinator()
    }
    
    // Inner coordinator keeps a strong reference to bridge closures from being recycled
    final class InnerCoordinator {
        weak var boundPlayerView: KSPlayer.IOSVideoPlayerView?
        weak var outerCoordinator: PlayerCoordinator?
    }
}
