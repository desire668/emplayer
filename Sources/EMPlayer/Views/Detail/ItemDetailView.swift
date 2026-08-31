import SwiftUI
import EMPlayerCore

struct ItemDetailView: View {
    @EnvironmentObject var appState: AppState
    let item: MediaItem
    
    @State private var fullItem: MediaItem?
    @State private var seasons: [MediaItem] = []
    @State private var episodes: [MediaItem] = []
    @State private var selectedSeasonId: String?
    @State private var loading: Bool = true
    @State private var childItems: [MediaItem] = []
    @State private var isFavorite: Bool = false
    @State private var showPlayer: Bool = false
    @State private var playerContext: PlayerContext?
    
    struct PlayerContext: Identifiable {
        let id: String
        let item: MediaItem
        let startPositionTicks: Int64
        let episodes: [MediaItem]?
        let currentIndex: Int
        
        init(item: MediaItem, startTicks: Int64 = 0, episodes: [MediaItem]? = nil, currentIndex: Int = 0) {
            self.id = item.id + "-" + UUID().uuidString
            self.item = item
            self.startPositionTicks = startTicks
            self.episodes = episodes
            self.currentIndex = currentIndex
        }
    }
    
    private var effectiveItem: MediaItem { fullItem ?? item }
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                heroHeader
                
                mainActions
                
                overviewSection
                
                if isSeries(effectiveItem) {
                    seriesContent
                } else if isSeason(effectiveItem) {
                    seasonEpisodes
                } else if isCollection(effectiveItem) {
                    collectionChildren
                }
                
                if !isSeries(effectiveItem) && !isSeason(effectiveItem) && !isCollection(effectiveItem) {
                    extrasSection
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .top) {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: 100).padding(.top, 80)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task {
                        isFavorite.toggle()
                        await PlaybackReporter.shared.setFavorite(item: effectiveItem, isFavorite: isFavorite)
                    }
                } label: {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .foregroundStyle(isFavorite ? .pink : .primary)
                }
                Menu {
                    Button {
                        Task { await PlaybackReporter.shared.markWatched(item: effectiveItem) }
                    } label: { Label("标记已观看", systemImage: "checkmark.circle") }
                    Button {
                        Task { await PlaybackReporter.shared.markUnwatched(item: effectiveItem) }
                    } label: { Label("标记未观看", systemImage: "circle") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fullScreenCover(item: $playerContext) { ctx in
            PlayerHostView(context: ctx)
                .ignoresSafeArea()
                .environmentObject(appState)
        }
        .task(id: item.id) { await loadFull() }
        .onChange(of: playerContext) { _, new in
            if new == nil {
                // Player dismissed — refresh item (watched state etc.)
                Task { await loadFull() }
            }
        }
    }
    
    // MARK: - Hero header
    
    private var heroHeader: some View {
        ZStack(alignment: .bottomLeading) {
            KFPosterImage(
                url: EmbyClient.shared.backdropURL(for: effectiveItem) ?? EmbyClient.shared.primaryImageURL(for: effectiveItem, maxWidth: 1200),
                size: CGSize(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.width * 0.6),
                placeholder: .backdrop,
                contentMode: .fill,
                cornerRadius: 0
            )
            .frame(width: UIScreen.main.bounds.width, height: UIScreen.main.bounds.width * 0.6)
            
            LinearGradient(colors: [.clear, Color(UIColor.systemBackground).opacity(0.0), Color(UIColor.systemBackground)], startPoint: .top, endPoint: .bottom)
            
            HStack(alignment: .bottom, spacing: 14) {
                if !isSeries(effectiveItem) && !isSeason(effectiveItem) {
                    KFPosterImage(url: EmbyClient.shared.primaryImageURL(for: effectiveItem, maxWidth: 500), size: CGSize(width: 120, height: 180), placeholder: .poster)
                        .frame(width: 120, height: 180)
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                        .padding(.bottom, -40)
                        .padding(.leading)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    if isSeries(effectiveItem) || isSeason(effectiveItem) {
                        Spacer(minLength: 150)
                    }
                    Text(effectiveItem.name)
                        .font(.title2.bold())
                        .lineLimit(2)
                    if let subtitle = effectiveItem.originalTitle, !subtitle.isEmpty && subtitle != effectiveItem.name {
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(metaLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let tagline = effectiveItem.tagline, !tagline.isEmpty {
                        Text(tagline).font(.footnote).foregroundStyle(.tertiary).italic()
                    }
                }
                .padding(.trailing)
                .padding(.bottom, 12)
            }
        }
    }
    
    private var metaLine: String {
        var p: [String] = []
        if let y = effectiveItem.productionYear { p.append(String(y)) }
        if let rating = effectiveItem.officialRating, !rating.isEmpty { p.append(rating) }
        if isSeason(effectiveItem), let idx = effectiveItem.parentIndexNumber ?? effectiveItem.indexNumber {
            p.insert("第 \(idx) 季", at: 0)
        }
        if isSeries(effectiveItem), let count = effectiveItem.recursiveItemCount {
            p.append("共 \(count) 集")
        } else if let cnt = effectiveItem.childCount, cnt > 0 {
            p.append("\(cnt) 项")
        }
        let d = effectiveItem.durationString
        if !d.isEmpty { p.append(d) }
        if let t = effectiveItem.type { p.append(t) }
        return p.joined(separator: " · ")
    }
    
    // MARK: - Actions
    
    private var mainActions: some View {
        HStack(spacing: 12) {
            if MediaTypeUtils.isVideo(effectiveItem) || MediaTypeUtils.isAudio(effectiveItem) {
                Button {
                    Task { await startPlay() }
                } label: {
                    Label(startLabel, systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: 12))
                
                ShareLink(item: shareURL) {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: 12))
            } else if MediaTypeUtils.isPhoto(effectiveItem) {
                Button {
                    // Photo viewer (simple fullscreen)
                    showPlayer = true
                    playerContext = .init(item: effectiveItem, startTicks: 0)
                } label: {
                    Label("查看图片", systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: 12))
            } else {
                // Collection: "Explore" button
                Button {
                    // Scroll to children
                } label: {
                    Label("浏览内容", systemImage: "rectangle.stack")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .buttonBorderShape(.roundedRectangle(radius: 12))
            }
        }
        .padding(.horizontal)
    }
    
    private var startLabel: String {
        let pct = effectiveItem.userData?.playedPercentage ?? 0
        if pct > 0 && pct < 100 {
            return "继续播放 \(TimeUtils.formatTicks(effectiveItem.userData?.playbackPositionTicks ?? 0))"
        }
        if MediaTypeUtils.isAudio(effectiveItem) { return "播放" }
        return "播放"
    }
    
    private var shareURL: URL {
        let host = EmbyClient.shared.currentServer?.baseURL() ?? ""
        return URL(string: "\(host)/web/index.html#!/item?id=\(effectiveItem.id)") ?? URL(string: host)!
    }
    
    // MARK: - Overview
    
    private var overviewSection: some View {
        Group {
            let ov = effectiveItem.overview ?? ""
            if !ov.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("简介").font(.headline)
                    Text(ov)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                }
                .padding(.horizontal)
            }
            if let genres = effectiveItem.genres, !genres.isEmpty {
                HStack(spacing: 6) {
                    ForEach(genres.prefix(5), id: \.self) { g in
                        Text(g)
                            .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(.indigo.opacity(0.2)))
                            .foregroundStyle(.indigo)
                    }
                }
                .padding(.horizontal)
            }
            if let studios = effectiveItem.studios, !studios.isEmpty {
                HStack {
                    Text("出品：")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(studios.map(\.name).joined(separator: "、"))
                        .font(.footnote)
                }
                .padding(.horizontal)
            }
            if let artists = effectiveItem.artists, !artists.isEmpty {
                HStack {
                    Text("艺人：")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text(artists.joined(separator: "、"))
                        .font(.footnote)
                }
                .padding(.horizontal)
            }
        }
    }
    
    // MARK: - Series section
    
    private var seriesContent: some View {
        Group {
            if !seasons.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(seasons) { s in
                                Button {
                                    selectedSeasonId = s.id
                                    Task { await loadEpisodes(seasonId: s.id) }
                                } label: {
                                    VStack(spacing: 6) {
                                        KFPosterImage(url: EmbyClient.shared.primaryImageURL(for: s, maxWidth: 400), size: CGSize(width: 120, height: 180), placeholder: .poster)
                                            .frame(width: 120, height: 180)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 12)
                                                    .stroke((selectedSeasonId ?? seasons.first?.id) == s.id ? Color.indigo : Color.clear, lineWidth: 2.5)
                                            )
                                        Text(s.name)
                                            .font(.callout.weight(.semibold))
                                            .lineLimit(1)
                                        Text("\(s.childCount ?? s.recursiveItemCount ?? 0) 集")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                } header: {
                    SectionHeader(title: "季", systemImage: "folder.fill")
                }
            }
            
            Section {
                if episodes.isEmpty && !loading {
                    EmptyHint(label: "该季暂无剧集", systemImage: "square.grid.3x1.folder.fill.badge.plus")
                } else {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(episodes.enumerated()), id: \.element.id) { (idx, ep) in
                            Button {
                                playerContext = .init(
                                    item: ep,
                                    startTicks: ep.playbackPositionTicks,
                                    episodes: episodes,
                                    currentIndex: idx
                                )
                            } label: {
                                EpisodeRow(item: ep)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            } header: {
                SectionHeader(title: "剧集", systemImage: "list.bullet")
            }
        }
    }
    
    // MARK: - Season episodes (when detail is a season)
    
    private var seasonEpisodes: some View {
        Section {
            LazyVStack(spacing: 6) {
                ForEach(Array(episodes.enumerated()), id: \.element.id) { (idx, ep) in
                    Button {
                        playerContext = .init(
                            item: ep,
                            startTicks: ep.playbackPositionTicks,
                            episodes: episodes,
                            currentIndex: idx
                        )
                    } label: {
                        EpisodeRow(item: ep)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        } header: {
            SectionHeader(title: "剧集", systemImage: "list.bullet")
        }
    }
    
    // MARK: - Collection / folder children
    
    private var collectionChildren: some View {
        Section {
            if childItems.isEmpty {
                EmptyHint(label: "空文件夹", systemImage: "folder")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                    ForEach(childItems) { ci in
                        NavigationLink {
                            ItemDetailView(item: ci)
                        } label: {
                            if MediaTypeUtils.isVideo(ci) && !MediaTypeUtils.isCollection(ci) {
                                PosterCard(item: ci)
                            } else {
                                PosterCard(item: ci)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
        } header: {
            SectionHeader(title: "内容", systemImage: "square.stack.3d.up")
        }
    }
    
    // MARK: - Extras
    
    private var extrasSection: some View {
        Section {
            VStack(spacing: 8) {
                if let type = effectiveItem.type {
                    LabeledContent("类型", value: type)
                }
                if let pd = effectiveItem.premiereDate {
                    LabeledContent("上映日期", value: TimeUtils.formatDate(pd))
                }
                if let dateAdded = effectiveItem.dateCreated {
                    LabeledContent("加入时间", value: TimeUtils.formatDate(dateAdded))
                }
                if let bitrate = effectiveItem.mediaSources?.first?.bitrate {
                    LabeledContent("码率", value: TimeUtils.formatBitrate(bitrate))
                }
                if let size = effectiveItem.mediaSources?.first?.size {
                    LabeledContent("大小", value: TimeUtils.formatSize(size))
                }
                if let ms = effectiveItem.mediaSources?.first {
                    let v = ms.mediaStreams?.first(where: { $0.type?.caseInsensitiveCompare("Video") == .orderedSame })
                    let a = ms.mediaStreams?.first(where: { $0.type?.caseInsensitiveCompare("Audio") == .orderedSame })
                    if let v {
                        let resolution = [v.width, v.height].compactMap { $0 }.map(String.init).joined(separator: "×")
                        LabeledContent("视频", value: "\(v.codec?.uppercased() ?? "?")\(!resolution.isEmpty ? " \(resolution)" : "")")
                    }
                    if let a {
                        LabeledContent("音频", value: "\(a.codec?.uppercased() ?? "?")\(a.channels.map { " \($0)ch" } ?? "")")
                    }
                }
            }
            .padding(.horizontal)
        } header: {
            SectionHeader(title: "媒体信息", systemImage: "info.circle")
        }
    }
    
    // MARK: - Helpers
    
    private func isSeries(_ it: MediaItem) -> Bool {
        (it.type ?? "").caseInsensitiveCompare("Series") == .orderedSame
    }
    private func isSeason(_ it: MediaItem) -> Bool {
        (it.type ?? "").caseInsensitiveCompare("Season") == .orderedSame
    }
    private func isCollection(_ it: MediaItem) -> Bool {
        MediaTypeUtils.isCollection(it) && !isSeries(it) && !isSeason(it)
    }
    
    // MARK: - Loaders
    
    private func loadFull() async {
        loading = true
        defer { loading = false }
        do {
            let full = try await EmbyClient.shared.getItem(item.id)
            fullItem = full
            isFavorite = full.userData?.isFavorite ?? false
            
            if isSeries(full) {
                let s = try await EmbyClient.shared.getSeasons(seriesId: full.id)
                seasons = s.items
                if let first = seasons.first {
                    selectedSeasonId = first.id
                    episodes = []
                    await loadEpisodes(seasonId: first.id)
                }
            } else if isSeason(full) {
                if let sid = full.seriesId {
                    let e = try await EmbyClient.shared.getEpisodes(seriesId: sid, seasonId: full.id)
                    episodes = e.items
                }
            } else if isCollection(full) {
                let r = try await EmbyClient.shared.getItems(parentId: full.id, recursive: false, limit: 500)
                childItems = r.items
            }
        } catch {
            appState.handleError(error, fallback: "加载详情失败")
        }
    }
    
    private func loadEpisodes(seasonId: String) async {
        guard let sid = effectiveItem.seriesId ?? (isSeries(effectiveItem) ? effectiveItem.id : nil) else { return }
        do {
            let e = try await EmbyClient.shared.getEpisodes(seriesId: sid, seasonId: seasonId)
            episodes = e.items
        } catch {
            appState.handleError(error, fallback: "加载剧集失败")
        }
    }
    
    private func startPlay() async {
        let it = effectiveItem
        let startTicks = it.playbackPositionTicks
        
        if let src = it.mediaSources?.first, MediaTypeUtils.isVideo(it) || MediaTypeUtils.isAudio(it) {
            // If we have media sources already, just start
            playerContext = .init(item: it, startTicks: startTicks)
            return
        }
        
        // Otherwise fetch playback info to get sources
        do {
            let info = try await EmbyClient.shared.getPlaybackInfo(itemId: it.id, startTimeTicks: startTicks)
            if info.mediaSources.isEmpty {
                appState.errorMessage = "无可播放的媒体源"
                return
            }
            var updated = it
            let keyPath = \MediaItem.mediaSources
            updated[keyPath: keyPath] = info.mediaSources
            fullItem = updated
            playerContext = .init(item: updated, startTicks: startTicks)
        } catch {
            appState.handleError(error, fallback: "获取播放信息失败")
        }
    }
}

// MARK: - Episode Row

struct EpisodeRow: View {
    let item: MediaItem
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                KFPosterImage(url: EmbyClient.shared.thumbImageURL(for: item, maxWidth: 500), size: CGSize(width: 180, height: 100), placeholder: .backdrop, cornerRadius: 10)
                    .frame(width: 180, height: 100)
                if let pct = item.userData?.playedPercentage, pct > 0 {
                    ProgressView(value: min(1, pct / 100.0))
                        .progressViewStyle(.linear)
                        .tint(.indigo)
                        .padding(6)
                }
                if item.played {
                    Image(systemName: "checkmark.circle.fill")
                        .padding(6)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(format: "E%02d", item.indexNumber ?? 0))
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.indigo.opacity(0.25)))
                        .foregroundStyle(.indigo)
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                Text(item.overview ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    if !item.durationString.isEmpty {
                        Label(item.durationString, systemImage: "clock")
                    }
                    if let ticks = item.userData?.playbackPositionTicks, ticks > 0 {
                        Label("已看 \(TimeUtils.formatTicks(ticks))", systemImage: "gauge.with.dots.needle.bottom.50percent")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.4)))
    }
}

import UIKit
import Kingfisher
