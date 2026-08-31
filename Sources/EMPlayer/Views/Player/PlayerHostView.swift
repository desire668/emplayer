import SwiftUI
import EMPlayerCore
import KSPlayer

// MARK: - Player Host
//
// 播放层直接使用 KSPlayer 官方提供的 SwiftUI 视图 `KSVideoPlayerView`
// （自带播放/暂停/进度条/手势/倍速/字幕/画中画/全屏等完整播放 UI），
// 并通过 `KSVideoPlayer.Coordinator` 的官方回调把播放进度/状态/结束事件
// 桥接到 Emby 的 PlaybackReporter 进行播放上报。
//
// 官方 API（已核对 KSPlayer main 分支源码）：
//   KSVideoPlayerView(coordinator:url:options:title:)   // iOS 16+
//   KSVideoPlayer.Coordinator (ObservableObject)
//     .onPlay        : (TimeInterval, TimeInterval) -> Void   // 当前时间 / 总时长
//     .onStateChanged: (KSPlayerLayer, KSPlayerState) -> Void
//     .onFinish      : (KSPlayerLayer, Error?) -> Void         // error 非 nil 表示出错
//     .seek(time:) / .playerLayer?.play() / .pause()
//   KSPlayerState: .initialized/.preparing/.readyToPlay/
//                  .buffering/.bufferFinished/.paused/
//                  .playedToTheEnd/.error （.error 无关联值）
//   KSOptions: hardwareDecode / startPlayTime / userAgent /
//              avOptions[AVURLAssetHTTPHeaderFieldsKey] / isSecondOpen ...

struct PlayerHostView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState
    let context: ItemDetailView.PlayerContext

    // 播放列表 / 当前集
    @State private var item: MediaItem
    @State private var startTicks: Int64
    @State private var playlist: [MediaItem]
    @State private var currentIndex: Int

    // Emby 播放会话
    @State private var playSessionId: String?
    @State private var currentMediaSource: MediaSource?
    @State private var playbackInfo: PlaybackInfoResponse?

    // 视图状态
    @State private var isLoading: Bool = true
    @State private var playbackURL: URL?
    @State private var startSeconds: Double = 0
    @State private var playMode: PlayMode = .directStream
    @State private var bannerMsg: String?        // 非致命错误（顶部横幅）
    @State private var fatalMsg: String?         // 无法播放（整页占位）

    // 上报 / 重建控制
    @State private var reporterActive: Bool = false
    @State private var finishedCurrent: Bool = false
    @State private var configureToken: Int = 0
    @State private var options = KSOptions()

    // KSPlayer 官方协调器
    @StateObject private var coordinator = KSVideoPlayer.Coordinator()

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
        _currentIndex = State(initialValue: context.episodes == nil ? 0 : context.currentIndex)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                loadingView
            } else if let url = playbackURL {
                KSVideoPlayerView(
                    coordinator: coordinator,
                    url: url,
                    options: options,
                    title: item.name
                )
                .id(configureToken)
                .ignoresSafeArea()
                .onAppear { installPlayer() }
                .overlay(alignment: .top) {
                    if let bannerMsg {
                        Text(bannerMsg)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(.red.opacity(0.85), in: Capsule())
                            .padding(.top, 58)
                    }
                }
                .overlay(alignment: .topLeading) {
                    // Emby 专属菜单（媒体源 / 播放模式 / 播放列表），
                    // 跟随 KSPlayer 控制栏一起显隐，避开左上角自带的关闭按钮。
                    topTrailingMenu
                        .opacity(coordinator.isMaskShow ? 1 : 0)
                        .padding(.top, 6)
                        .padding(.leading, 54)
                }
            } else {
                ContentUnavailableView(
                    "无法播放",
                    systemImage: "play.slash.fill",
                    description: Text(fatalMsg ?? "没有可用的播放源")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .padding()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .task(id: item.id, priority: .high) { await resolvePlayback() }
        .onChange(of: currentIndex) { _, idx in
            guard idx >= 0 && idx < playlist.count else { return }
            let next = playlist[idx]
            item = next
            startTicks = next.playbackPositionTicks
            // item.id 变化会自动触发上面的 .task(id: item.id) 重新解析播放
        }
        .onChange(of: playMode) { _, _ in
            reloadWithCurrentSource()
        }
        .onDisappear {
            teardownReporter(playedToCompletion: guessPlayedToCompletion())
        }
    }

    // MARK: - Loading

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
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .padding()
                }
            }
        }
    }

    // MARK: - Emby 专属菜单

    private var topTrailingMenu: some View {
        Menu {
            if let info = playbackInfo, info.mediaSources.count > 1 {
                Menu("媒体源") {
                    ForEach(info.mediaSources) { ms in
                        Button {
                            currentMediaSource = ms
                            reloadWithCurrentSource()
                        } label: {
                            if ms.id == currentMediaSource?.id {
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
                    ForEach(PlayMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
            }
            if playlist.count > 1 {
                Menu("播放列表") {
                    ForEach(Array(playlist.enumerated()), id: \.offset) { idx, it in
                        Button {
                            currentIndex = idx
                        } label: {
                            if idx == currentIndex {
                                Label(episodeLabel(it, idx: idx), systemImage: "checkmark")
                            } else {
                                Text(episodeLabel(it, idx: idx))
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle.fill")
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
        }
    }

    private func episodeLabel(_ it: MediaItem, idx: Int) -> String {
        if let s = it.parentIndexNumber, let e = it.indexNumber {
            return String(format: "S%02dE%02d %@", s, e, it.name)
        }
        return "\(idx + 1). \(it.name)"
    }

    // MARK: - 解析播放地址

    private func resolvePlayback() async {
        teardownReporter(playedToCompletion: false)
        isLoading = true
        bannerMsg = nil
        fatalMsg = nil
        playbackURL = nil
        currentMediaSource = nil
        finishedCurrent = false

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
            startSeconds = Double(startTicks) / 10_000_000.0
            configureOptions()
            rebuildPlaybackURL(with: source, mode: playMode)

            isLoading = false
            configureToken &+= 1
        } catch {
            fatalMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            isLoading = false
        }
    }

    private func configureOptions() {
        let opt = KSOptions()
        opt.hardwareDecode = true
        opt.preferredForwardBufferDuration = 30
        opt.maxBufferDuration = 60
        opt.isSecondOpen = true
        opt.isAccurateSeek = true
        opt.autoSelectEmbedSubtitle = true
        opt.asynchronousDecompression = true
        // 续播位置（KSOptions.startPlayTime 为官方属性，单位秒）
        opt.startPlayTime = max(0, startSeconds)
        opt.userAgent = "EMPlayer/1.0 (iOS)"
        // Emby 鉴权头（AVPlayer 内核读取 AVURLAssetHTTPHeaderFieldsKey）
        if let token = EmbyClient.shared.accessToken {
            opt.avOptions = [
                "AVURLAssetHTTPHeaderFieldsKey": [
                    "User-Agent": "EMPlayer/1.0 (iOS)",
                    "X-Emby-Token": token
                ]
            ]
        }
        options = opt
    }

    private func rebuildPlaybackURL(with source: MediaSource, mode: PlayMode) {
        switch mode {
        case .directStream:
            playbackURL = EmbyClient.shared.directStreamURL(mediaSource: source)
                ?? EmbyClient.shared.hlsTranscodeURL(
                    mediaSource: source,
                    playSessionId: playSessionId ?? UUID().uuidString,
                    startTimeTicks: startTicks
                )
        case .hlsTranscode:
            if source.supportsTranscoding, let sid = playSessionId {
                playbackURL = EmbyClient.shared.hlsTranscodeURL(
                    mediaSource: source,
                    playSessionId: sid,
                    startTimeTicks: startTicks
                )
            } else {
                playbackURL = EmbyClient.shared.directStreamURL(mediaSource: source)
            }
        }
    }

    /// 切换媒体源 / 播放模式后重建播放器（.id 变化触发 KSVideoPlayerView 重建，
    /// 其 onAppear 会重新挂载回调并启动上报）。
    private func reloadWithCurrentSource() {
        teardownReporter(playedToCompletion: false)
        reporterActive = false
        finishedCurrent = false
        bannerMsg = nil
        guard let src = currentMediaSource else { return }
        configureOptions()
        rebuildPlaybackURL(with: src, mode: playMode)
        configureToken &+= 1
    }

    // MARK: - KSPlayer 回调挂载

    private func installPlayer() {
        coordinator.onPlay = { current, total in
            // 高频回调，仅把最新位置喂给上报器（上报器内部 10s 定时批量上报）
            if reporterActive {
                PlaybackReporter.shared.updatePosition(current, isPaused: false)
            }
        }
        coordinator.onStateChanged = { _, state in
            switch state {
            case .paused:
                if reporterActive { PlaybackReporter.shared.togglePause(true) }
            case .playedToTheEnd:
                handleCurrentFinished()
            case .initialized, .preparing, .readyToPlay, .buffering, .bufferFinished, .error:
                break
            @unknown default:
                break
            }
        }
        coordinator.onFinish = { _, error in
            if let error {
                bannerMsg = "播放出错：\(error.localizedDescription)"
            } else {
                handleCurrentFinished()
            }
        }
        startReporterIfNeeded()
    }

    // MARK: - 播放结束 / 下一集

    private func handleCurrentFinished() {
        guard !finishedCurrent else { return }
        finishedCurrent = true
        PlaybackReporter.shared.stop(playedToCompletion: true)
        reporterActive = false

        if currentIndex + 1 < playlist.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                currentIndex += 1
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                dismiss()
            }
        }
    }

    private func guessPlayedToCompletion() -> Bool {
        let total = Double(coordinator.timemodel.totalTime)
        let cur = Double(coordinator.timemodel.currentTime)
        guard total > 0 else { return false }
        return cur > max(total - 15, total * 0.95)
    }

    // MARK: - Emby 上报

    private func startReporterIfNeeded() {
        guard !reporterActive, let src = currentMediaSource else { return }
        reporterActive = true
        let sid = playSessionId ?? UUID().uuidString
        let it = item
        let ticks = startTicks
        Task {
            await PlaybackReporter.shared.start(
                item: it,
                mediaSource: src,
                playSessionId: sid,
                startPositionTicks: ticks
            )
        }
    }

    private func teardownReporter(playedToCompletion: Bool) {
        guard reporterActive else { return }
        reporterActive = false
        PlaybackReporter.shared.stop(playedToCompletion: playedToCompletion)
    }
}
