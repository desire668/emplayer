import SwiftUI
import EMPlayerCore

struct SearchView: View {
    @EnvironmentObject var appState: AppState
    @State private var text: String = ""
    @State private var results: [MediaItem] = []
    @State private var loading: Bool = false
    @State private var debounceTask: Task<Void, Never>?
    @State private var hasSearched: Bool = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                Divider()
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if text.isEmpty && !hasSearched {
                    ContentUnavailableView(
                        "搜索",
                        systemImage: "magnifyingglass",
                        description: Text("输入关键词搜索电影、剧集、音乐等。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    ContentUnavailableView(
                        "没有结果",
                        systemImage: "magnifyingglass",
                        description: Text("试试其它关键词。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(results) { item in
                                NavigationLink {
                                    ItemDetailView(item: item)
                                } label: {
                                    ListRow(item: item)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(10)
                    }
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .autocorrectionDisabled()
        }
    }
    
    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索电影、剧集、音乐、演员…", text: $text)
                    .onSubmit { runSearch() }
                if !text.isEmpty {
                    Button {
                        text = ""
                        results = []
                        hasSearched = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .onChange(of: text) { _, new in
            debounceTask?.cancel()
            debounceTask = Task.detached {
                do {
                    try await Task.sleep(seconds: 0.35)
                    if Task.isCancelled { return }
                    await MainActor.run { runSearch() }
                } catch {}
            }
        }
    }
    
    private func runSearch() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { results = []; hasSearched = false; return }
        hasSearched = true
        loading = true
        Task.detached {
            do {
                let r = try await EmbyClient.shared.getItems(
                    recursive: true,
                    searchTerm: q,
                    limit: 100,
                    sortBy: ["SortName"]
                )
                try Task.checkCancellation()
                await MainActor.run {
                    results = r.items
                    loading = false
                }
            } catch {
                await MainActor.run {
                    appState.handleError(error, fallback: "搜索失败")
                    loading = false
                }
            }
        }
    }
}
