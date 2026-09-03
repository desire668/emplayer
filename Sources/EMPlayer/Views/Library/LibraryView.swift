import SwiftUI
import EMPlayerCore

// MARK: - Library Grid View

struct LibraryView: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if appState.isLoadingLibraries {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 300)
                    } else if appState.libraries.isEmpty {
                        ContentUnavailableView(
                            "暂无媒体库",
                            systemImage: "square.stack.3d.up",
                            description: Text("请在服务器上添加媒体库后下拉刷新重试。")
                        )
                        .frame(maxWidth: .infinity, minHeight: 400)
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 160), spacing: 14)],
                            spacing: 14
                        ) {
                            ForEach(appState.libraries) { folder in
                                NavigationLink {
                                    LibraryFolderView(folder: folder)
                                } label: {
                                    LibraryFolderCard(folder: folder)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("媒体库")
            .refreshable {
                await appState.loadLibraries(force: true)
            }
            .onAppear {
                Task { await appState.loadLibraries() }
            }
        }
    }
}

struct LibraryFolderCard: View {
    let folder: MediaFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                if let img = folderImage {
                    KFPosterImage(url: img, size: CGSize(width: 180, height: 110), placeholder: .backdrop, contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors: [.indigo.opacity(0.5), .purple.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(height: 110)
                        .overlay {
                            Image(systemName: folder.sfSymbol)
                                .font(.system(size: 46, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                }
            }
            .frame(height: 110)

            Text(folder.collectionName)
                .font(.headline)
                .lineLimit(1)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quaternary.opacity(0.4)))
    }

    private var folderImage: URL? {
        guard let tags = folder.imageTags else { return nil }
        return EmbyClient.shared.imageURL(itemId: folder.id, tag: tags.primary ?? tags.thumb, type: "Primary", maxWidth: 400)
    }
}

// MARK: - Folder Content (with filters, sort, tabs for Series/Movies etc.)

struct LibraryFolderView: View {
    @EnvironmentObject var appState: AppState
    let folder: MediaFolder
    
    @State private var items: [MediaItem] = []
    @State private var total: Int = 0
    @State private var loading: Bool = true
    @State private var viewMode: ViewMode = .autoPoster
    @State private var sortBy: SortKey = .name
    @State private var sortOrder: SortOrder = .asc
    @State private var filter: FilterKey = .all
    @State private var searchText: String = ""
    @State private var errorMsg: String?
    
    enum ViewMode: String, CaseIterable, Identifiable {
        case gridPoster = "海报网格"
        case list = "列表"
        case autoPoster = "自动"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .gridPoster: return "square.grid.3x3.fill"
            case .list: return "list.bullet"
            case .autoPoster: return "wand.and.stars.inverse"
            }
        }
    }
    
    enum SortKey: String, CaseIterable, Identifiable {
        case name = "名称"
        case dateAdded = "添加时间"
        case premiereDate = "上映时间"
        case runtime = "时长"
        case communityRating = "评分"
        case productionYear = "年份"
        var id: String { rawValue }
        var param: [String] {
            switch self {
            case .name: return ["SortName"]
            case .dateAdded: return ["DateCreated"]
            case .premiereDate: return ["PremiereDate"]
            case .runtime: return ["Runtime"]
            case .communityRating: return ["CommunityRating"]
            case .productionYear: return ["ProductionYear", "SortName"]
            }
        }
    }
    
    enum SortOrder: String, CaseIterable, Identifiable {
        case asc = "升序"
        case desc = "降序"
        var id: String { rawValue }
        var param: String { self == .asc ? "Ascending" : "Descending" }
    }
    
    enum FilterKey: String, CaseIterable, Identifiable {
        case all = "全部"
        case unwatched = "未观看"
        case watched = "已观看"
        case favorite = "收藏"
        var id: String { rawValue }
        var filters: [String] {
            switch self {
            case .all: return []
            case .unwatched: return ["IsUnplayed"]
            case .watched: return ["IsPlayed"]
            case .favorite: return ["IsFavorite"]
            }
        }
        var isFavorite: Bool? { self == .favorite ? true : nil }
        var hasPlayed: Bool? {
            switch self {
            case .unwatched: return false
            case .watched: return true
            default: return nil
            }
        }
    }
    
    private var isFolderOnly: Bool {
        (folder.collectionType ?? "").caseInsensitiveCompare("folders") == .orderedSame
    }
    
    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if items.isEmpty {
                        ContentUnavailableView(
                            "没有内容",
                            systemImage: "tray",
                            description: Text(errorMsg ?? "尝试切换筛选条件或下拉刷新。")
                        )
                        .frame(minHeight: 500)
                    } else {
                        content
                            .padding(.horizontal, 10)
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        .navigationTitle(folder.collectionName)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索 \(folder.collectionName)")
        .onSubmit(of: .search) { Task { await load() } }
        .onChange(of: searchText) { _, newValue in
            if newValue.isEmpty { Task { await load() } }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                menu
            }
        }
        .refreshable { await load() }
        .task(id: folder.id) { await load() }
        .onChange(of: sortBy) { _, _ in Task { await load() } }
        .onChange(of: sortOrder) { _, _ in Task { await load() } }
        .onChange(of: filter) { _, _ in Task { await load() } }
    }
    
    @ViewBuilder
    private var menu: some View {
        Menu {
            Picker("视图", selection: $viewMode) {
                ForEach(ViewMode.allCases) { v in
                    Label(v.rawValue, systemImage: v.symbol).tag(v)
                }
            }
            .pickerStyle(.menu)
            
            Menu {
                Picker("排序", selection: $sortBy) {
                    ForEach(SortKey.allCases) { s in Text(s.rawValue).tag(s) }
                }
                Picker("顺序", selection: $sortOrder) {
                    ForEach(SortOrder.allCases) { s in Text(s.rawValue).tag(s) }
                }
            } label: {
                Label("排序", systemImage: "arrow.up.arrow.down")
            }
            
            Menu {
                Picker("筛选", selection: $filter) {
                    ForEach(FilterKey.allCases) { f in Text(f.rawValue).tag(f) }
                }
            } label: {
                Label("筛选", systemImage: "line.3.horizontal.decrease.circle")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
    
    @ViewBuilder
    private var content: some View {
        let effectiveViewMode: ViewMode = {
            if viewMode != .autoPoster { return viewMode }
            // Auto: for folders that look like collections (season, series listing), use grid; otherwise grid poster
            return .gridPoster
        }()
        
        switch effectiveViewMode {
        case .gridPoster, .autoPoster:
            let colType = folder.collectionType?.lowercased() ?? ""
            let useWide = colType == "photos" || colType == "homevideos"
            let columns = useWide
                ? [GridItem(.adaptive(minimum: 200), spacing: 12)]
                : [GridItem(.adaptive(minimum: 140), spacing: 12)]
            
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(items) { item in
                    NavigationLink {
                        ItemDetailView(item: item)
                    } label: {
                        if useWide {
                            BackdropCard(item: item)
                        } else {
                            PosterCard(item: item)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)
        case .list:
            LazyVStack(spacing: 6) {
                ForEach(items) { item in
                    NavigationLink {
                        ItemDetailView(item: item)
                    } label: {
                        ListRow(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
    
    private func load() async {
        loading = true
        errorMsg = nil
        do {
            // 剧集库默认只显示 Series 级别（不展开到每集），其他库过滤掉 Episode 类型
            let colType = folder.collectionType?.lowercased() ?? ""
            let includeTypes: [String]? = colType == "tvshows" ? ["Series"] : nil
            let result = try await EmbyClient.shared.getItems(
                parentId: folder.id,
                filters: filter.filters.isEmpty ? nil : filter.filters,
                sortBy: sortBy.param,
                sortOrder: sortOrder.param,
                recursive: !isFolderOnly,
                includeItemTypes: includeTypes,
                searchTerm: searchText.isEmpty ? nil : searchText,
                limit: 500,
                isFavorite: filter.isFavorite,
                hasPlayed: filter.hasPlayed
            )
            // 双重保险：客户端再过滤掉 Episode 类型（部分服务器不遵 IncludeItemTypes）
            items = result.items.filter { ($0.type ?? "").caseInsensitiveCompare("Episode") != .orderedSame }
            total = result.totalRecordCount
        } catch {
            errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        loading = false
    }
}

struct ListRow: View {
    let item: MediaItem
    
    var body: some View {
        HStack(spacing: 12) {
            KFPosterImage(url: EmbyClient.shared.thumbImageURL(for: item, maxWidth: 400), size: CGSize(width: 140, height: 80), placeholder: .thumb, cornerRadius: 10)
                .frame(width: 140, height: 80)
            
            VStack(alignment: .leading, spacing: 5) {
                Text(MediaTypeUtils.displayTitle(item))
                    .font(.headline)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.4)))
    }
    
    private var subtitle: String {
        var parts: [String] = []
        if let t = item.type { parts.append(t) }
        if let y = item.productionYear { parts.append(String(y)) }
        if let g = item.genres, !g.isEmpty { parts.append(g.prefix(3).joined(separator: "、")) }
        let d = item.durationString
        if !d.isEmpty { parts.append(d) }
        if item.played { parts.append("已观看") }
        return parts.joined(separator: " · ")
    }
}
