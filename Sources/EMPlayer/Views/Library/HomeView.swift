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

// MARK: - Home (Continue Watching + Next Up + Recently Added)

struct HomeView: View {
    @EnvironmentObject var appState: AppState
    @State private var resume: [MediaItem] = []
    @State private var nextUp: [MediaItem] = []
    @State private var recent: [MediaItem] = []
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
                        Section {
                            PosterRow(items: resume, useBackdrop: false) { item in
                                ResumeCard(item: item)
                            } emptyView: {
                                EmptyHint(label: "还没有继续观看的内容", systemImage: "play.circle")
                            }
                        } header: { SectionHeader(title: "继续观看", systemImage: "play.circle.fill") }
                        
                        Section {
                            PosterRow(items: nextUp, useBackdrop: false) { item in
                                NextUpCard(item: item)
                            } emptyView: {
                                EmptyHint(label: "没有待看的剧集", systemImage: "tv")
                            }
                        } header: { SectionHeader(title: "下一集", systemImage: "forward.end.fill") }
                        
                        Section {
                            PosterRow(items: recent, useBackdrop: true, wide: true) { item in
                                BackdropCard(item: item)
                            } emptyView: {
                                EmptyHint(label: "暂无最近添加内容", systemImage: "sparkles")
                            }
                        } header: { SectionHeader(title: "最近添加", systemImage: "sparkles") }
                    }
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("首页")
            .refreshable { await load() }
            .onAppear {
                if !loading && resume.isEmpty && nextUp.isEmpty && recent.isEmpty {
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
                async let r1 = EmbyClient.shared.getResumeItems(limit: 20)
                async let r2 = EmbyClient.shared.getNextUp(limit: 20)
                async let r3 = EmbyClient.shared.getItems(
                    sortBy: ["DateCreated"],
                    sortOrder: "Descending",
                    recursive: true,
                    includeItemTypes: ["Movie","Series","MusicAlbum","Season","Episode","MusicVideo"],
                    limit: 20
                )
                let (a, b, c) = try await (r1, r2, r3)
                try Task.checkCancellation()
                await MainActor.run {
                    resume = a.items
                    nextUp = b.items
                    recent = c.items
                    loading = false
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run {
                    appState.handleError(error, fallback: "加载首页失败")
                    loading = false
                }
            }
        }
        loadTask = task
    }
}

struct SectionHeader: View {
    let title: String
    let systemImage: String
    var action: (() -> Void)? = nil
    
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: systemImage)
                .font(.title3.bold())
            Spacer()
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
            ZStack(alignment: .bottom) {
                KFPosterImage(url: EmbyClient.shared.thumbImageURL(for: item, maxWidth: 800), size: size, placeholder: .backdrop, contentMode: .fill)
                    .clipped()
                VStack(spacing: 6) {
                    HStack {
                        Spacer()
                        Image(systemName: "play.fill")
                            .font(.title3.weight(.semibold))
                            .padding(10)
                            .background(.ultraThinMaterial, in: Circle())
                        Spacer()
                    }
                    if let pct = item.userData?.playedPercentage, pct > 0 {
                        ProgressView(value: min(1, pct / 100.0))
                            .progressViewStyle(.linear)
                            .tint(.indigo)
                    }
                }
                .padding(10)
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

struct NextUpCard: View {
    let item: MediaItem
    private let size: CGSize = CGSize(width: 280, height: 100)
    
    var body: some View {
        HStack(spacing: 10) {
            KFPosterImage(url: EmbyClient.shared.thumbImageURL(for: item, maxWidth: 400), size: CGSize(width: 160, height: 90), placeholder: .backdrop, contentMode: .fill)
                .frame(width: 160, height: 90)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            
            VStack(alignment: .leading, spacing: 4) {
                if let series = item.seriesName {
                    Text(series)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(item.name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                if let s = item.parentIndexNumber, let e = item.indexNumber {
                    Text(String(format: "S%02d · E%02d", s, e))
                        .font(.caption2)
                        .foregroundStyle(.indigo)
                } else {
                    Text(item.durationString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .frame(width: size.width)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.4)))
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
