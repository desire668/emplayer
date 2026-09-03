import SwiftUI
import UIKit
import AVFoundation
import Combine
import EMPlayerCore
import KSPlayer

// MARK: - Player Host
//
// 播放层使用 KSPlayer 底层的 `KSVideoPlayer`（纯视频渲染视图，无自带控制层），
// 控制层（顶部返回/标题/菜单 + 底部进度条/倍速/音轨/字幕）完全自定义实现，
// 通过 `KSVideoPlayer.Coordinator` 的官方回调把播放进度/状态/结束事件
// 桥接到 Emby 的 PlaybackReporter 进行播放上报。
//
// 方向控制：进入播放页强制横屏（OrientationManager + AppDelegate），
// 竖屏时视频保持 16:9 半屏显示、下方展示标题与选集。
//
// 官方 API（已核对 KSPlayer main 分支源码）：
//   KSVideoPlayer(coordinator:url:options:)            // 纯渲染 UIViewRepresentable
//   KSVideoPlayer.Coordinator (ObservableObject)
//     .onPlay        : (TimeInterval, TimeInterval) -> Void   // 当前时间 / 总时长
//     .onStateChanged: (KSPlayerLayer, KSPlayerState) -> Void
//     .onFinish      : (KSPlayerLayer, Error?) -> Void         // error 非 nil 表示出错
//     .seek(time:) / .skip(interval:) / .mask(show:autoHide:)
//     .isMaskShow / .state.isPlaying / .timemodel (currentTime/totalTime, Int 秒)
//     .playbackRate / .playerLayer?.play() / .pause()
//     .playerLayer?.player.tracks(mediaType:) / .select(track:)   // 音轨
//     .subtitleModel.subtitleInfos / .selectedSubtitleInfo          // 字幕
//   KSPlayerState: .initialized/.preparing/.readyToPlay/
//                  .buffering/.bufferFinished/.paused/
//                  .playedToTheEnd/.error （.error 无关联值）

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

    // 进度条拖动状态（拖动中不被播放进度回调覆盖）
    @State private var isSeeking: Bool = false
    @State private var seekValue: Double = 0

    // 字幕渲染层状态（SubtitleModel 为嵌套 ObservableObject，onReceive 手动同步）
    @State private var subtitleParts: [SubtitlePart] = []

    // 画面比例
    @State private var scaleMode: ScaleMode = .fit

    // 播放锁定（锁定后仅解锁按钮可点，防误触）
    @State private var isLocked: Bool = false

    // 横竖屏布局跟踪（控制状态栏显隐）
    @State private var isLandscapeLayout: Bool = true

    // 缓冲进度提示
    @State private var isBuffering: Bool = false
    @State private var bufferPercent: Double = 0

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

    /// 画面比例模式
    enum ScaleMode: String, CaseIterable, Identifiable {
        case fit = "适应"
        case fill = "填充"
        case stretch = "拉伸"
        var id: String { rawValue }

        var contentMode: UIView.ContentMode {
            switch self {
            case .fit: return .scaleAspectFit
            case .fill: return .scaleAspectFill
            case .stretch: return .scaleToFill
            }
        }
    }

    private let playbackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    init(context: ItemDetailView.PlayerContext) {
        self.context = context
        _item = State(initialValue: context.item)
        _startTicks = State(initialValue: context.startPositionTicks)
        let list = context.episodes ?? [context.item]
        _playlist = State(initialValue: list)
        _currentIndex = State(initialValue: context.episodes == nil ? 0 : context.currentIndex)
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let topInset = isLandscape ? 0 : geo.safeAreaInsets.top + 14

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                if isLoading {
                    loadingView
                } else if let url = playbackURL {
                    // 视频渲染层（纯渲染，不含控制层）
                    if isLandscape {
                        KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                            .id(configureToken)
                            .onAppear { installPlayer() }
                            .frame(width: geo.size.width, height: geo.size.height)
                        subtitleOverlay
                        if isBuffering { bufferingView }
                    } else {
                        // 竖屏：画面在顶部 16:9，下方空出放控件
                        VStack(spacing: 0) {
                            KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                                .id(configureToken)
                                .onAppear { installPlayer() }
                                .frame(width: geo.size.width, height: geo.size.width * 9.0 / 16.0)
                                .clipped()
                            Spacer()
                        }
                        .frame(width: geo.size.width, height: geo.size.height - topInset)
                        .padding(.top, topInset)
                        subtitleOverlay
                        if isBuffering { bufferingView }
                    }
                } else {
                    fatalView
                }

                // 横幅错误提示（独立层）
                if let bannerMsg {
                    Text(bannerMsg)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.red.opacity(0.85), in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 52)
                }

                // 控制层（覆盖整个屏幕；锁定时只显示解锁按钮）
                if isLocked {
                    unlockOverlay
                        .opacity(coordinator.isMaskShow ? 1 : 0)
                        .allowsHitTesting(coordinator.isMaskShow)
                } else {
                    controlsOverlay(isLandscape: isLandscape, geo: geo)
                        .opacity(coordinator.isMaskShow ? 1 : 0)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard !isLocked else { return }
                if coordinator.state.isPlaying {
                    coordinator.playerLayer?.pause()
                } else {
                    coordinator.playerLayer?.play()
                }
            }
            .onTapGesture {
                coordinator.mask(show: !coordinator.isMaskShow)
            }
            .onReceive(bufferPollPublisher) { _ in
                guard isBuffering else { return }
                let total = Double(coordinator.timemodel.totalTime)
                let playable = coordinator.playerLayer?.player.playableTime ?? 0
                if total > 0 {
                    bufferPercent = min(1, max(0, playable / total))
                }
            }
            .onReceive(coordinator.subtitleModel.$parts) { subtitleParts = $0 }
            .onReceive(coordinator.subtitleModel.$selectedSubtitleInfo) { _ in
                subtitleParts = coordinator.subtitleModel.parts
            }
            .onChange(of: isLandscape) { _, v in isLandscapeLayout = v }
            .onAppear { isLandscapeLayout = isLandscape }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(!isLandscapeLayout)
        .background(Color.black.ignoresSafeArea())
        .task(id: item.id, priority: .high) { await resolvePlayback() }
        .onAppear { OrientationManager.shared.lockLandscape() }
        .onDisappear {
            OrientationManager.shared.lockPortrait()
            teardownReporter(playedToCompletion: guessPlayedToCompletion())
        }
        .onChange(of: currentIndex) { _, idx in
            guard idx >= 0 && idx < playlist.count else { return }
            let next = playlist[idx]
            item = next
            startTicks = next.playbackPositionTicks
        }
        .onChange(of: playMode) { _, _ in reloadWithCurrentSource() }
        .onChange(of: scaleMode) { _, _ in applyScaleMode() }
    }

    // MARK: - 缓冲轮询（0.5s 一次）

    private let bufferPollPublisher = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    // MARK: - 字幕渲染层

    private var subtitleOverlay: some View {
        VStack(spacing: 0) {
            Spacer()
            ForEach(subtitleParts) { part in
                Group {
                    if let image = part.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else if let attr = part.text, attr.length > 0 {
                        Text(AttributedString(attr))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                    }
                }
                .shadow(color: .black.opacity(0.9), radius: 3, x: 0, y: 1)
                .padding(.horizontal, 20)
                // 控制栏显示时抬高避让；双语字幕行间距要窄，不用额外 padding
                .padding(.bottom, coordinator.isMaskShow ? 88 : 6)
                .frame(maxWidth: .infinity)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 缓冲提示 / 锁定层

    private var bufferingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(bufferPercent > 0.001 ? String(format: "正在缓冲 %.0f%%", bufferPercent * 100) : "正在缓冲…")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(24)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - 控制层（重构：浮动关闭 + 右侧锁定 + 单胶囊底栏）

    private func controlsOverlay(isLandscape: Bool, geo: GeometryProxy) -> some View {
        ZStack(alignment: .topTrailing) {
            // 顶：浮动关闭 X
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, isLandscape ? 10 : 0)
                Spacer()
                bottomBar(isLandscape: isLandscape)
            }
            .frame(width: geo.size.width, height: geo.size.height)

            // 锁定按钮：**屏幕右侧垂直居中**（而非视频区右侧）
            if !isLocked {
                VStack {
                    Spacer()
                    Button {
                        isLocked = true
                        coordinator.mask(show: true)
                    } label: {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .trailing)
                .padding(.trailing, 8)
            }
        }
    }

    /// 锁定态覆盖层（隐藏原控制层，仅解锁按钮）
    private var unlockOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Button {
                    isLocked = false
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
            Spacer()
        }
    }

    // MARK: - 单胶囊底栏：时间+控制+进度+菜单 一行排列；所有按钮统一 36x36

    private func bottomBar(isLandscape: Bool) -> some View {
        HStack(spacing: 12) {
            Text(timeString(Int(coordinator.timemodel.currentTime)))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 34, alignment: .leading)

            // 快退 / 播放暂停 / 快进
            HStack(spacing: 10) {
                Button {
                    coordinator.skip(interval: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)

                Button {
                    if coordinator.state.isPlaying {
                        coordinator.playerLayer?.pause()
                    } else {
                        coordinator.playerLayer?.play()
                    }
                } label: {
                    Image(systemName: coordinator.state.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)

                Button {
                    coordinator.skip(interval: 15)
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)
            }

            // 进度条（接在播放按钮右边）
            Slider(
                value: Binding(
                    get: { isSeeking ? seekValue : Double(coordinator.timemodel.currentTime) },
                    set: { seekValue = $0 }
                ),
                in: 0...max(1, Double(coordinator.timemodel.totalTime))
            ) { editing in
                isSeeking = editing
                if !editing {
                    coordinator.seek(time: seekValue)
                }
            }
            .tint(.indigo)
            .controlSize(.mini)

            Text(timeString(coordinator.timemodel.totalTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 34, alignment: .trailing)

            // 右侧功能按钮（每个统一 36x36，HStack spacing: 10 保证间隔一致）
            HStack(spacing: 10) {
                scaleModeMenu
                audioTrackMenu
                subtitleMenu
                playbackRateMenu
                Button {
                    if isLandscape {
                        OrientationManager.shared.rotateToPortrait()
                    } else {
                        OrientationManager.shared.rotateToLandscape()
                    }
                } label: {
                    Image(systemName: isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                }
                .frame(width: 36, height: 36)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
        .padding(.bottom, isLandscape ? 18 : 12)
    }

    /// 画面比例（适应 / 填充 / 拉伸）
    private var scaleModeMenu: some View {
        Menu {
            ForEach(ScaleMode.allCases) { mode in
                Button {
                    scaleMode = mode
                } label: {
                    if scaleMode == mode {
                        Label(mode.rawValue, systemImage: "checkmark")
                    } else {
                        Text(mode.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "aspect.ratio")
                .font(.system(size: 16))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
    }

    /// 音轨选择：始终渲染按钮；菜单项在 readyToPlay 后自动出现（playerLayer 由 @StateObject 驱动重绘）
    private var audioTrackMenu: some View {
        Menu {
            let tracks = coordinator.playerLayer?.player.tracks(mediaType: .audio) ?? []
            ForEach(tracks, id: \.trackID) { track in
                Button {
                    coordinator.playerLayer?.player.select(track: track)
                } label: {
                    if track.isEnabled {
                        Label(track.name, systemImage: "checkmark")
                    } else {
                        Text(track.name)
                    }
                }
            }
        } label: {
            Image(systemName: "waveform")
                .font(.system(size: 16))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
    }

    /// 字幕选择（内嵌字幕 + 外挂字幕；按当前 selectedSubtitleInfo 身份匹配勾选）
    private var subtitleMenu: some View {
        Menu {
            Button {
                coordinator.subtitleModel.selectedSubtitleInfo = nil
            } label: {
                if coordinator.subtitleModel.selectedSubtitleInfo == nil {
                    Label("关闭字幕", systemImage: "checkmark")
                } else {
                    Text("关闭字幕")
                }
            }
            ForEach(coordinator.subtitleModel.subtitleInfos, id: \.id) { info in
                Button {
                    coordinator.subtitleModel.selectedSubtitleInfo = info
                } label: {
                    if coordinator.subtitleModel.selectedSubtitleInfo?.id == info.id {
                        Label(info.name, systemImage: "checkmark")
                    } else {
                        Text(info.name)
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 16))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
    }

    /// 倍速选择
    private var playbackRateMenu: some View {
        Menu {
            ForEach(playbackRates, id: \.self) { rate in
                Button {
                    coordinator.playbackRate = rate
                } label: {
                    if abs(coordinator.playbackRate - rate) < 0.01 {
                        Label(rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(rate))
                    }
                }
            }
        } label: {
            Image(systemName: "speedometer")
                .font(.system(size: 16))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? String(format: "%.0fx", rate) : String(format: "%.2gx", rate)
    }

    // MARK: - 竖屏下方信息区（半屏播放）

    private var portraitInfoView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.name)
                .font(.title3.bold())
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 10) {
                if let s = item.parentIndexNumber, let e = item.indexNumber {
                    Text(String(format: "S%02d · E%02d", s, e))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.indigo)
                }
                Text(item.durationString)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if playlist.count > 1 {
                Text("选集")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(playlist.enumerated()), id: \.offset) { idx, ep in
                            Button {
                                currentIndex = idx
                            } label: {
                                Text(episodeLabel(ep, idx: idx))
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule().fill(idx == currentIndex ? Color.indigo : Color(UIColor.tertiarySystemFill))
                                    )
                                    .foregroundStyle(idx == currentIndex ? .white : .primary)
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
    }

    private func episodeLabel(_ it: MediaItem, idx: Int) -> String {
        if let s = it.parentIndexNumber, let e = it.indexNumber {
            return String(format: "S%02dE%02d", s, e)
        }
        return "\(idx + 1)"
    }

    // MARK: - Loading / Fatal

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

    private var fatalView: some View {
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

    // MARK: - 时间格式化（秒）

    private func timeString(_ t: Int) -> String {
        let s = max(0, t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
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
            configureToken += 1
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

    /// 切换媒体源 / 播放模式后重建播放器（.id 变化触发重建，
    /// 其 onAppear 会重新挂载回调并启动上报）。
    private func reloadWithCurrentSource() {
        teardownReporter(playedToCompletion: false)
        reporterActive = false
        finishedCurrent = false
        bannerMsg = nil
        guard let src = currentMediaSource else { return }
        configureOptions()
        rebuildPlaybackURL(with: src, mode: playMode)
        configureToken += 1
    }

    // MARK: - KSPlayer 回调挂载

    private func installPlayer() {
        coordinator.onPlay = { current, total in
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
            case .buffering:
                isBuffering = true
            case .readyToPlay, .bufferFinished:
                isBuffering = false
                applyScaleMode()
            case .initialized, .preparing, .error:
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
        applyScaleMode()
    }

    /// 把画面比例应用到播放器视图（切换比例、重建播放器、就绪后都会调用）
    private func applyScaleMode() {
        coordinator.playerLayer?.player.view?.contentMode = scaleMode.contentMode
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
