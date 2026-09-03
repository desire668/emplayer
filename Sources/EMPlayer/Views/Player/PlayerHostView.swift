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

    // 横竖屏布局跟踪（控制状态栏显隐，来源于 GeometryReader 的真实窗口方向）
    @State private var isLandscapeLayout: Bool = true

    // 控制层显隐（自管自动隐藏：播放中 4s 无操作隐藏；暂停/拖动/弹菜单时常驻）
    @State private var controlsVisible: Bool = true
    @State private var hideTask: Task<Void, Never>?
    // 音量弹窗
    @State private var showVolumePopover: Bool = false

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
            // 真实窗口方向（按钮图标/布局以此为准，与设备旋转实时同步）
            let isLandscape = geo.size.width > geo.size.height
            let insets = geo.safeAreaInsets

            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                if isLoading {
                    loadingView
                } else if let url = playbackURL {
                    if isLandscape {
                        // 横屏（全屏）：视频铺满整个窗口
                        videoArea(url: url, isLandscape: isLandscape, insets: insets)
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        // 竖屏（窗口化）：画面 16:9 在整屏垂直居中，上下留黑
                        videoArea(url: url, isLandscape: isLandscape, insets: insets)
                            .frame(width: geo.size.width, height: geo.size.width * 9.0 / 16.0)
                            .clipShape(Rectangle())
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    fatalView
                }
            }
            .onChange(of: isLandscape) { _, v in isLandscapeLayout = v }
            .onAppear { isLandscapeLayout = isLandscape }
        }
        .preferredColorScheme(.dark)
        // 横屏全屏隐藏状态栏；竖屏保留
        .statusBarHidden(isLandscapeLayout)
        .background(Color.black.ignoresSafeArea())
        .task(id: item.id, priority: .high) { await resolvePlayback() }
        .onAppear {
            OrientationManager.shared.enterPlayer()
        }
        .onDisappear {
            hideTask?.cancel()
            OrientationManager.shared.exitPlayer()
            teardownReporter(playedToCompletion: guessPlayedToCompletion())
        }
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
        .onChange(of: scaleMode) { _, _ in
            applyScaleMode()
        }
    }

    // MARK: - 视频区域（渲染 + 手势 + 控件层）

    /// 缓冲进度轮询（0.5s 一次，仅缓冲中读取 playableTime）
    private let bufferPollPublisher = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private func videoArea(url: URL, isLandscape: Bool, insets: EdgeInsets) -> some View {
        ZStack {
            KSVideoPlayer(coordinator: coordinator, url: url, options: options)
                .id(configureToken)
                .onAppear { installPlayer() }

            // 字幕渲染层：KSVideoPlayer 底层视图不带字幕 UI，
            // 手动渲染 subtitleModel.parts（KSPlayerLayerDelegate 每帧驱动更新）
            subtitleOverlay

            // 缓冲进度提示（加载 / 卡顿时显示）
            if isBuffering {
                bufferingView
            }

            // 控制层：自动隐藏 + 横竖屏自适应 + 安全区域避让
            controlsLayer(isLandscape: isLandscape, insets: insets)

            if let bannerMsg {
                Text(bannerMsg)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.red.opacity(0.85), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, isLandscape ? insets.top + 56 : 44)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            // 双击：播放 / 暂停（锁定时忽略）
            guard !isLocked else { return }
            togglePlayPause()
        }
        .onTapGesture {
            // 单击：显隐控制层（播放中自动倒计时隐藏；锁定时用于唤出解锁按钮）
            if controlsVisible { hideControls() } else { showControls() }
        }
        // 缓冲进度轮询：可播放时长 / 总时长
        .onReceive(bufferPollPublisher) { _ in
            guard isBuffering else { return }
            let total = Double(coordinator.timemodel.totalTime)
            let playable = coordinator.playerLayer?.player.playableTime ?? 0
            if total > 0 {
                bufferPercent = min(1, max(0, playable / total))
            }
        }
        // SubtitleModel 是嵌套 ObservableObject，需手动同步到视图状态
        .onReceive(coordinator.subtitleModel.$parts) { subtitleParts = $0 }
        .onReceive(coordinator.subtitleModel.$selectedSubtitleInfo) { _ in
            // 切换字幕轨后立即刷新一次
            subtitleParts = coordinator.subtitleModel.parts
        }
        // 音量弹窗打开时常驻控制层，关闭后重新计时自动隐藏
        .onChange(of: showVolumePopover) { _, shown in
            if shown { keepControlsVisible() } else { scheduleAutoHide() }
        }
    }

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
                // 控制栏显示时抬高避让；双语字幕行间距保持紧凑
                .padding(.bottom, controlsVisible ? 96 : 8)
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

    // MARK: - 控制层（自动隐藏 / 横竖屏自适应 / 安全区域避让）

    /// 横屏时避让刘海/灵动岛与 Home Indicator；竖屏视频本身不贴屏幕边，用固定边距
    private func hPad(_ insets: EdgeInsets, isLandscape: Bool) -> CGFloat {
        isLandscape ? max(12, insets.leading, insets.trailing) : 10
    }

    private func controlsLayer(isLandscape: Bool, insets: EdgeInsets) -> some View {
        Group {
            if isLocked {
                // 锁定态：仅保留右上角解锁按钮（单击屏幕唤出）
                VStack {
                    HStack {
                        Spacer()
                        unlockButton
                            .padding(.top, isLandscape ? insets.top + 6 : 8)
                            .padding(.trailing, hPad(insets, isLandscape: isLandscape))
                    }
                    Spacer()
                }
            } else {
                VStack(spacing: 0) {
                    topBar(isLandscape: isLandscape, insets: insets)
                    Spacer(minLength: 0)
                    bottomBar(isLandscape: isLandscape, insets: insets)
                }
            }
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .animation(.easeInOut(duration: 0.25), value: controlsVisible)
    }

    /// 解锁按钮（锁定态唯一可见控件）
    private var unlockButton: some View {
        Button {
            isLocked = false
            showControls()
        } label: {
            Image(systemName: "lock.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// 顶栏：返回 + 标题 + 锁定（渐变背景；横屏避让灵动岛/刘海）
    private func topBar(isLandscape: Bool, insets: EdgeInsets) -> some View {
        HStack(spacing: 2) {
            playerButton("chevron.down", size: 20) { dismiss() }

            Text(MediaTypeUtils.displayTitle(item))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.leading, 6)

            Spacer(minLength: 8)

            // 播放锁定（防误触）：锁定后仅可解锁
            playerButton(isLocked ? "lock.fill" : "lock.open.fill",
                         size: 18, active: isLocked) {
                isLocked.toggle()
                if isLocked { keepControlsVisible() } else { showControls() }
            }
        }
        .padding(.horizontal, hPad(insets, isLandscape: isLandscape))
        .padding(.top, isLandscape ? insets.top + 2 : 4)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - 底栏（上：进度行；下：按钮行；渐变背景 + 安全区域）

    private func bottomBar(isLandscape: Bool, insets: EdgeInsets) -> some View {
        VStack(spacing: 2) {
            // 进度行：当前时间 —— 进度条 —— 总时长
            HStack(spacing: 10) {
                Text(timeString(coordinator.timemodel.currentTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 42, alignment: .leading)

                progressSlider

                Text(timeString(coordinator.timemodel.totalTime))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 42, alignment: .trailing)
            }

            // 按钮行：左侧播放控制组，右侧功能组（竖屏自动收窄，次要功能进「更多」）
            HStack(spacing: 2) {
                playerButton("gobackward.15", size: 22) { coordinator.skip(interval: -15) }
                playPauseButton
                playerButton("goforward.15", size: 22) { coordinator.skip(interval: 15) }

                Spacer(minLength: 8)

                // 音量（仅横屏显示；竖屏用机身音量键）
                if isLandscape {
                    volumeButton
                }
                // 更多：选集 / 倍速 / 字幕 / 音轨 / 画面比例 / 播放模式
                moreMenu
                // 横竖屏切换（= 全屏进入 / 退出）
                orientationButton(isLandscape: isLandscape)
            }
        }
        .padding(.horizontal, hPad(insets, isLandscape: isLandscape))
        .padding(.top, 18)
        .padding(.bottom, isLandscape ? insets.bottom + 6 : 6)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    // MARK: - 控制按钮（统一 44×44 点击区域）

    /// 通用控制按钮：图标 20~24pt，点击区域 44×44pt，操作后重置自动隐藏计时
    private func playerButton(_ systemName: String,
                              size: CGFloat = 22,
                              active: Bool = false,
                              action: @escaping () -> Void) -> some View {
        Button {
            action()
            scheduleAutoHide()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? Color.indigo : Color.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 播放 / 暂停（状态联动图标；暂停时常驻控制层，播放后自动隐藏）
    private var playPauseButton: some View {
        Button {
            togglePlayPause()
        } label: {
            Image(systemName: coordinator.state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 进度条：拖动中常驻控制层，松手定位后重新计时
    private var progressSlider: some View {
        Slider(
            value: Binding(
                get: { isSeeking ? seekValue : Double(coordinator.timemodel.currentTime) },
                set: { seekValue = $0 }
            ),
            in: 0...max(1, Double(coordinator.timemodel.totalTime))
        ) { editing in
            isSeeking = editing
            if editing {
                keepControlsVisible()
            } else {
                coordinator.seek(time: seekValue)
                scheduleAutoHide()
            }
        }
        .tint(.indigo)
    }

    /// 音量按钮（MPVolumeView 系统音量滑块，iOS 原生公开 API）
    private var volumeButton: some View {
        Button {
            showVolumePopover.toggle()
        } label: {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showVolumePopover) {
            VStack(spacing: 10) {
                Label("音量", systemImage: "speaker.wave.2.fill")
                    .font(.footnote.weight(.medium))
                SystemVolumeView()
                    .frame(width: 210, height: 32)
            }
            .padding(18)
            .presentationCompactAdaptation(.popover)
        }
    }

    /// 横竖屏切换按钮：图标跟随 GeometryReader 的真实窗口方向
    private func orientationButton(isLandscape: Bool) -> some View {
        Button {
            if isLandscape {
                OrientationManager.shared.requestPortrait()
            } else {
                OrientationManager.shared.requestLandscape()
            }
            scheduleAutoHide()
        } label: {
            Image(systemName: isLandscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 「更多」菜单：选集 / 倍速 / 字幕 / 音轨 / 画面比例 / 播放模式（Picker 自带勾选状态）
    private var moreMenu: some View {
        Menu {
            if playlist.count > 1 {
                Picker("选集", selection: $currentIndex) {
                    ForEach(Array(playlist.enumerated()), id: \.offset) { idx, ep in
                        Text(episodeLabel(ep, idx: idx)).tag(idx)
                    }
                }
            }

            Picker("倍速",
                   selection: Binding<Float>(
                       get: { coordinator.playbackRate },
                       set: { coordinator.playbackRate = $0 })) {
                ForEach(playbackRates, id: \.self) { rate in
                    Text(rateLabel(rate)).tag(rate)
                }
            }

            Picker("字幕", selection: subtitleSelection) {
                Text("关闭字幕").tag(-1)
                ForEach(Array(coordinator.subtitleModel.subtitleInfos.enumerated()), id: \.element.id) { idx, info in
                    Text(info.name).tag(idx)
                }
            }

            if let tracks = coordinator.playerLayer?.player.tracks(mediaType: .audio), !tracks.isEmpty {
                Picker("音轨",
                       selection: Binding<Int>(
                           get: { tracks.firstIndex(where: { $0.isEnabled }) ?? 0 },
                           set: { idx in
                               if idx >= 0, idx < tracks.count {
                                   coordinator.playerLayer?.player.select(track: tracks[idx])
                               }
                           })) {
                    ForEach(Array(tracks.enumerated()), id: \.element.trackID) { idx, track in
                        Text(track.name).tag(idx)
                    }
                }
            }

            Picker("画面比例", selection: $scaleMode) {
                ForEach(ScaleMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            Picker("播放模式", selection: $playMode) {
                ForEach(PlayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 打开菜单时常驻控制层（菜单打开期间不自动隐藏）
        .simultaneousGesture(TapGesture().onEnded { keepControlsVisible() })
    }

    /// 字幕选择绑定：-1 = 关闭，其余为 subtitleInfos 索引（按身份匹配勾选）
    private var subtitleSelection: Binding<Int> {
        Binding<Int>(
            get: {
                guard let sel = coordinator.subtitleModel.selectedSubtitleInfo else { return -1 }
                return coordinator.subtitleModel.subtitleInfos.firstIndex(where: { $0.id == sel.id }) ?? -1
            },
            set: { idx in
                if idx >= 0, idx < coordinator.subtitleModel.subtitleInfos.count {
                    coordinator.subtitleModel.selectedSubtitleInfo = coordinator.subtitleModel.subtitleInfos[idx]
                } else {
                    coordinator.subtitleModel.selectedSubtitleInfo = nil
                }
            }
        )
    }

    private func rateLabel(_ rate: Float) -> String {
        rate == rate.rounded() ? String(format: "%.0fx", rate) : String(format: "%.2gx", rate)
    }

    // MARK: - 控制层显隐 / 自动隐藏

    private func togglePlayPause() {
        if coordinator.state.isPlaying {
            coordinator.playerLayer?.pause()
            keepControlsVisible()   // 暂停时常驻
        } else {
            coordinator.playerLayer?.play()
            showControls()          // 播放后倒计时自动隐藏
        }
    }

    /// 显示控制层并开始 4 秒自动隐藏计时
    private func showControls() {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        coordinator.isMaskShow = true
        scheduleAutoHide()
    }

    /// 常驻显示（拖动进度条 / 菜单打开 / 暂停 / 缓冲），不自动隐藏
    private func keepControlsVisible() {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        coordinator.isMaskShow = true
    }

    /// 重新安排自动隐藏（仅播放中生效；暂停/缓冲常驻）
    private func scheduleAutoHide() {
        hideTask?.cancel()
        // 未播放 / 暂停时常驻
        guard coordinator.state.isPlaying else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled { return }
            // 拖动中 / 音量弹窗 / 锁定态 / 缓冲中不隐藏
            guard !isSeeking, !showVolumePopover, !isLocked,
                  coordinator.state == .bufferFinished else { return }
            withAnimation(.easeIn(duration: 0.35)) { controlsVisible = false }
            coordinator.isMaskShow = false
        }
    }

    /// 立即隐藏控制层
    private func hideControls() {
        hideTask?.cancel()
        withAnimation(.easeIn(duration: 0.25)) { controlsVisible = false }
        coordinator.isMaskShow = false
    }

    // MARK: - 选集标签（「更多」菜单使用）

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
                keepControlsVisible()   // 暂停时常驻控制层
                if reporterActive { PlaybackReporter.shared.togglePause(true) }
            case .playedToTheEnd:
                handleCurrentFinished()
            case .buffering:
                isBuffering = true
                keepControlsVisible()   // 缓冲时常驻
            case .readyToPlay, .bufferFinished:
                isBuffering = false
                // 播放器 view 就绪后应用画面比例
                applyScaleMode()
                showControls()          // 开始播放：显示控制层并倒计时自动隐藏
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
