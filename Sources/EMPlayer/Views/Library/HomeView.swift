import SwiftUI
import EMPlayerCore

struct MainTabView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: Tab = .home
    
    enum Tab {
        case home, libraries, search, settings
    }
    
    var body: some View {
        TabView(selection: $selection) {
            HomeView()
                .tabItem { Label("首页", systemImage: "house.fill") }
                .tag(Tab.home)
            
            LibraryView()
                .tabItem { Label("媒体库", systemImage: "square.stack.3d.up.fill") }
                .tag(Tab.libraries)
            
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
    }
}

// MARK: - Home (Continue Watching + Favorites + Server Views Categories)

/// 首页媒体库区块排序方式
enum HomeSortOption: String, CaseIterable, Identifiable {
    case dateAdded = "最近添加"
    case name = "名称"
    case year = "上映年份"
    var id: String { rawValue }

    var sortBy: String {
        switch self {
        case .dateAdded: return "DateCreated"
        case .name: return "SortName"
        case .year: return "ProductionYear"
        }
    }
    var sortOrder: String {
        switch self {
        case .name: return "Ascending"
        default: return "Descending"
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var resume: [MediaItem] = []
    @State private var favorites: [MediaItem] = []
    @State private var sections: [(folder: MediaFolder, items: [MediaItem])] = []
    // 每个媒体库区块的排序（folderId -> 排序方式），默认最近添加
    @State private var sortOptions: [String: HomeSortOption] = [:]
    @State private var loading: Bool = true
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 400)
                } else {
                    LazyVStack(alignment: .leading, spacing: 24, pinnedViews: [.sectionHeaders]) {
                        // 继续观看
                        Section {
                            PosterRow(items: resume) { item in
                                ResumeCard(item: item)
                            } emptyView: {
                                EmptyHint(label: "还没有继续观看的内容", systemImage: "play.circle")
                            }
                        } header: { SectionHeader(title: "继续观看", systemImage: "play.circle.fill") }

                        // 收藏
                        Section {
                            PosterRow(items: favorites) { item in
                                PosterCard(item: item)
                            } emptyView: {
                                EmptyHint(label: "暂无收藏内容", systemImage: "heart")
                            }
                        } header: { SectionHeader(title: "收藏", systemImage: "heart.fill") }

                        // 各服务器媒体库分类（名称取自服务器，可切换排序）
                        ForEach(Array(sections.enumerated()), id: \.offset) { idx, section in
                            Section {
                                PosterRow(items: section.items) { item in
                                    PosterCard(item: item)
                                } emptyView: {
                                    EmptyHint(label: "暂无内容", systemImage: "film.stack")
                                }
                            } header: {
                                SectionHeader(
                                    title: section.folder.collectionName,
                                    systemImage: section.folder.sfSymbol,
                                    sortBinding: Binding(
                                        get: { sortOptions[section.folder.id] ?? .dateAdded },
                                        set: { sortOptions[section.folder.id] = $0 }
                                    ),
                                    onSortChange: { sort in
                                        Task { await reloadFolder(section.folder, sort: sort) }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("首页")
            .refreshable { await load() }
            .onAppear {
                if !loading && resume.isEmpty && sections.isEmpty {
                    Task { await load() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loadTask?.cancel()
        loading = true
        let task = Task {
            do {
                // 1. 加载继续观看 + 收藏（独立容错）
                async let r1: QueryResult<MediaItem>? = loadSection {
                    try await EmbyClient.shared.getResumeItems(limit: 20)
                }
                async let r2: QueryResult<MediaItem>? = loadSection {
                    try await EmbyClient.shared.getItems(
                        sortBy: ["DateCreated"],
                        sortOrder: "Descending",
                        recursive: true,
                        limit: 20,
                        isFavorite: true
                    )
                }

                // 2. 加载服务器 Views（媒体库分类）
                let folders: [MediaFolder]
                do {
                    folders = try await EmbyClient.shared.getMediaFolders()
                } catch {
                    if Task.isCancelled { return }
                    folders = []
                    await MainActor.run {
                        appState.handleError(error, fallback: "加载媒体库分类失败")
                    }
                }

                // 3. 并发加载每个 View 的最新内容（按各自排序）
                let folderResults = await withTaskGroup(of: (folder: MediaFolder, items: [MediaItem]).self) { group in
                    for folder in folders {
                        group.addTask { [folder] in
                            do {
                                let sort = await MainActor.run { sortOptions[folder.id] ?? .dateAdded }
                                let result = try await EmbyClient.shared.getItems(
                                    parentId: folder.id,
                                    sortBy: [sort.sortBy],
                                    sortOrder: sort.sortOrder,
                                    recursive: true,
                                    limit: 20
                                )
                                return (folder: folder, items: result.items)
                            } catch {
                                return (folder: folder, items: [])
                            }
                        }
                    }
                    var results: [(folder: MediaFolder, items: [MediaItem])] = []
                    for await (folder, items) in group {
                        results.append((folder: folder, items: items))
                    }
                    return results
                }

                try Task.checkCancellation()
                let resumeResult = await r1
                let favResult = await r2
                await MainActor.run {
                    resume = resumeResult?.items ?? []
                    favorites = favResult?.items ?? []
                    sections = folderResults.filter { !$0.items.isEmpty }
                    loading = false
                }
            } catch is CancellationError {
                // 被下拉刷新 / 新任务取消，静默处理
            } catch {
                await MainActor.run {
                    appState.handleError(error, fallback: "加载首页失败")
                    loading = false
                }
            }
        }
        loadTask = task
    }

    /// 排序切换后单库刷新（只更新该区块，不整页 reload）
    private func reloadFolder(_ folder: MediaFolder, sort: HomeSortOption) async {
        guard let idx = sections.firstIndex(where: { $0.folder.id == folder.id }) else { return }
        let result = await loadSection {
            try await EmbyClient.shared.getItems(
                parentId: folder.id,
                sortBy: [sort.sortBy],
                sortOrder: sort.sortOrder,
                recursive: true,
                limit: 20
            )
        }
        if let r = result, !Task.isCancelled {
            await MainActor.run {
                if sections.indices.contains(idx) {
                    sections[idx] = (folder: folder, items: r.items)
                }
            }
        }
    }

    /// 单个首页区块的容错加载：失败时弹出错误横幅并返回 nil（区块显示空态），不影响其他区块
    private func loadSection(_ work: () async throws -> QueryResult<MediaItem>) async -> QueryResult<MediaItem>? {
        do {
            return try await work()
        } catch {
            if Task.isCancelled { return nil }
            await MainActor.run {
                appState.handleError(error, fallback: "加载首页部分内容失败")
            }
            return nil
        }
    }
}

struct SectionHeader: View {
    let title: String
    let systemImage: String
    var action: (() -> Void)? = nil
    var sortBinding: Binding<HomeSortOption>? = nil
    var onSortChange: ((HomeSortOption) -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: systemImage)
                .font(.title3.bold())
            Spacer()
            if let sb = sortBinding {
                Menu {
                    ForEach(HomeSortOption.allCases) { opt in
                        Button {
                            guard sb.wrappedValue != opt else { return }
                            sb.wrappedValue = opt
                            onSortChange?(opt)
                        } label: {
                            if sb.wrappedValue == opt {
                                Label(opt.rawValue, systemImage: "checkmark")
                            } else {
                                Text(opt.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down")
                        Text(sb.wrappedValue.rawValue)
                    }
                    .font(.footnote)
                    .foregroundStyle(.indigo)
                }
            }
            if let a = action {
                Button("查看全部", action: a)
                    .font(.footnote)
                    .foregroundStyle(.indigo)
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .background(Color(UIColor.systemBackground))
    }
}

struct PosterRow<Card: View, Empty: View>: View {
    let items: [MediaItem]
    var useBackdrop: Bool = false
    var wide: Bool = false
    @ViewBuilder let card: (MediaItem) -> Card
    @ViewBuilder let emptyView: Empty
    
    var body: some View {
        if items.isEmpty {
            emptyView.padding(.horizontal)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(items) { item in
                        NavigationLink {
                            ItemDetailView(item: item)
                        } label: {
                            card(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
        }
    }
}

struct EmptyHint: View {
    let label: String
    let systemImage: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text(label)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
    }
}

// MARK: - Cards

struct PosterCard: View {
    let item: MediaItem
    var size: CGSize = CGSize(width: 140, height: 210)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KFPosterImage(url: EmbyClient.shared.primaryImageURL(for: item, maxWidth: 500), size: size, placeholder: .poster)
                .overlay(alignment: .bottomLeading) {
                    if let pct = item.userData?.playedPercentage, pct > 0, pct < 100 {
                        ProgressView(value: pct / 100.0)
                            .progressViewStyle(.linear)
                            .tint(.indigo)
                            .padding(8)
                            .background(
                                LinearGradient(colors: [.black.opacity(0.0), .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                            )
                    }
                }
            Text(MediaTypeUtils.displayTitle(item))
                .font(.callout.weight(.semibold))
                .lineLimit(2)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: size.width)
    }
    
    private var subtitle: String {
        var parts: [String] = []
        if let y = item.productionYear { parts.append(String(y)) }
        let ds = item.durationString
        if !ds.isEmpty { parts.append(ds) }
        if item.played { parts.append("已观看") }
        return parts.joined(separator: " · ")
    }
}

struct ResumeCard: View {
    let item: MediaItem
    private let size: CGSize = CGSize(width: 260, height: 160)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KFPosterImage(url: EmbyClient.shared.thumbImageURL(for: item, maxWidth: 800), size: size, placeholder: .backdrop, contentMode: .fill)
                .clipped()
                // 播放按钮居中显示
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .overlay(alignment: .bottom) {
                    if let pct = item.userData?.playedPercentage, pct > 0 {
                        ProgressView(value: min(1, pct / 100.0))
                            .progressViewStyle(.linear)
                            .tint(.indigo)
                            .padding(8)
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            
            Text(MediaTypeUtils.displayTitle(item))
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Text("\(TimeUtils.formatTicks(item.userData?.playbackPositionTicks ?? 0)) / \(item.durationString)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: size.width)
    }
}

struct BackdropCard: View {
    let item: MediaItem
    private let size: CGSize = CGSize(width: 300, height: 170)
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                KFPosterImage(
                    url: EmbyClient.shared.backdropURL(for: item) ?? EmbyClient.shared.thumbImageURL(for: item, maxWidth: 800),
                    size: size,
                    placeholder: .backdrop,
                    contentMode: .fill
                )
                .clipped()
                
                LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                .padding(10)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
    
    private var subtitle: String {
        var parts: [String] = []
        if let t = item.type { parts.append(t) }
        if let y = item.productionYear { parts.append(String(y)) }
        let d = item.durationString
        if !d.isEmpty { parts.append(d) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - KF wrapper for optional URL & placeholder

enum PosterPlaceholderType { case poster, backdrop, thumb }

struct KFPosterImage: View {
    let url: URL?
    var size: CGSize
    var placeholder: PosterPlaceholderType = .poster
    var contentMode: SwiftUI.ContentMode = .fill
    var cornerRadius: CGFloat = 12
    
    var body: some View {
        Group {
            if let url = url {
                KFImage(url)
                    .placeholder({ _ in placeholderView })
                    .resizable()
                    .fade(duration: 0.25)
                    .diskCacheExpiration(.days(14))
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholderView
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color.gray.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
    
    private var placeholderView: some View {
        ZStack {
            Color.gray.opacity(0.25)
            switch placeholder {
            case .poster:
                Image(systemName: "film")
                    .font(.system(size: min(size.width, size.height) * 0.25))
                    .foregroundStyle(.secondary.opacity(0.6))
            case .backdrop, .thumb:
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: min(size.width, size.height) * 0.25))
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
    }
}

import Kingfisher
