import Foundation
import Combine

// MARK: - Playback Reporter

/// Periodically reports playback progress back to Emby server, and handles start/stop events.
@MainActor
public final class PlaybackReporter: ObservableObject {
    public static let shared = PlaybackReporter()
    
    private var currentItem: MediaItem?
    private var currentMediaSource: MediaSource?
    private var playSessionId: String?
    private var lastPositionTicks: Int64 = 0
    private var timerTask: Task<Void, Never>?
    private var lastReportedDate: Date = .distantPast
    
    public private(set) var isRunning: Bool = false
    
    private init() {}
    
    // MARK: Lifecycle
    
    public func start(
        item: MediaItem,
        mediaSource: MediaSource,
        playSessionId: String,
        startPositionTicks: Int64 = 0
    ) async {
        stop()
        
        self.currentItem = item
        self.currentMediaSource = mediaSource
        self.playSessionId = playSessionId
        self.lastPositionTicks = startPositionTicks
        
        isRunning = true
        
        // 服务器可能返回空 MediaSourceId，fallback 到 item.id（Emby 服务端允许）
        let effectiveMSId = mediaSource.id.isEmpty ? item.id : mediaSource.id
        do {
            try await EmbyClient.shared.reportPlaybackStart(
                itemId: item.id,
                mediaSourceId: effectiveMSId,
                playSessionId: playSessionId,
                playbackStartTimeTicks: startPositionTicks
            )
        } catch {
            print("[PlaybackReporter] start error: \(error)")
        }
        
        // Start a 10s progress report timer
        timerTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                try? await sleepTask(seconds: 10.0)
                guard let self = self else { break }
                Task { @MainActor in
                    await self.reportProgressIfNeeded()
                }
            }
        }
    }
    
    public func updatePosition(_ positionSeconds: Double, isPaused: Bool) {
        lastPositionTicks = Int64(positionSeconds * 10_000_000.0)
    }
    
    public func stop(playedToCompletion: Bool = false) {
        timerTask?.cancel()
        timerTask = nil
        guard let item = currentItem, let src = currentMediaSource else {
            currentItem = nil; currentMediaSource = nil; playSessionId = nil
            isRunning = false
            return
        }
        let pos = lastPositionTicks
        let sid = playSessionId
        let msId = src.id.isEmpty ? item.id : src.id
        
        isRunning = false
        currentItem = nil
        currentMediaSource = nil
        playSessionId = nil
        
        Task.detached {
            do {
                try await EmbyClient.shared.reportPlaybackStop(
                    itemId: item.id,
                    mediaSourceId: msId,
                    playSessionId: sid,
                    positionTicks: pos,
                    playedToCompletion: playedToCompletion
                )
                if playedToCompletion {
                    try await EmbyClient.shared.markWatched(itemId: item.id)
                }
            } catch {
                print("[PlaybackReporter] stop error: \(error)")
            }
        }
    }
    
    public func togglePause(_ isPaused: Bool) {
        Task.detached { [weak self] in
            guard let self = self else { return }
            let pos = await self.lastPositionTicks
            let itemId = await self.currentItem?.id
            let msId = await self.currentMediaSource?.id
            let psId = await self.playSessionId
            guard let i = itemId, let m = msId else { return }
            // MediaSourceId 为空时 fallback 到 item.id
            let effectiveMsId = m.isEmpty ? i : m
            do {
                try await EmbyClient.shared.reportPlaybackProgress(
                    itemId: i,
                    mediaSourceId: effectiveMsId,
                    playSessionId: psId,
                    positionTicks: pos,
                    isPaused: isPaused
                )
            } catch {
                print("[PlaybackReporter] togglePause error: \(error)")
            }
        }
    }
    
    private func reportProgressIfNeeded() async {
        guard let item = currentItem, let src = currentMediaSource else { return }
        let now = Date()
        guard now.timeIntervalSince(lastReportedDate) >= 9.0 else { return }
        lastReportedDate = now
        let msId = src.id.isEmpty ? item.id : src.id
        do {
            try await EmbyClient.shared.reportPlaybackProgress(
                itemId: item.id,
                mediaSourceId: msId,
                playSessionId: playSessionId,
                positionTicks: lastPositionTicks
            )
        } catch {
            print("[PlaybackReporter] progress error: \(error)")
        }
    }
    
    // MARK: Explicit mark watched
    
    public func markWatched(item: MediaItem) async {
        do { try await EmbyClient.shared.markWatched(itemId: item.id) } catch {}
    }
    
    public func markUnwatched(item: MediaItem) async {
        do { try await EmbyClient.shared.markUnwatched(itemId: item.id) } catch {}
    }
    
    public func setFavorite(item: MediaItem, isFavorite: Bool) async {
        do { try await EmbyClient.shared.setFavorite(itemId: item.id, isFavorite: isFavorite) } catch {}
    }
}
