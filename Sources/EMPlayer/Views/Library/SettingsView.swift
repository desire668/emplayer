import SwiftUI
import EMPlayerCore
import Kingfisher

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverStore: ServerStore
    @State private var showServerList: Bool = false
    @State private var cacheSize: String = ""
    @State private var appVersion: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }()
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ServerListView()
                            .environmentObject(appState)
                            .environmentObject(serverStore)
                    } label: {
                        HStack(spacing: 12) {
                            if let s = appState.currentServer {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 10).fill(Color.indigo.opacity(0.3))
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(.indigo)
                                }
                                .frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name).font(.headline)
                                    Text(s.baseURL()).font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Label("服务器管理", systemImage: "server.rack")
                            }
                        }
                    }
                    
                    if let user = appState.currentUser {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.indigo.opacity(0.3)).frame(width: 40, height: 40)
                                Image(systemName: user.isAdministrator ? "person.crop.circle.badge.star" : "person.crop.circle")
                                    .foregroundStyle(.indigo)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.name).font(.headline)
                                Text(user.isAdministrator ? "管理员" : "普通用户")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("账户")
                }
                
                Section("播放") {
                    LabeledContent("首选解码", value: "Metal 硬件加速 + FFmpeg 软解")
                    LabeledContent("音频输出", value: "最多 8 声道 · AC3/EAC3/DTS 直通")
                    LabeledContent("字幕渲染", value: "ASS/SRT/VTT 外部 + PGS 内嵌")
                    LabeledContent("最高比特率", value: "20 Mbps")
                }
                
                Section("通用") {
                    HStack {
                        Label("图片缓存", systemImage: "photo.stack")
                        Spacer()
                        if cacheSize.isEmpty {
                            ProgressView()
                        } else {
                            Text(cacheSize).foregroundStyle(.secondary)
                        }
                    }
                    
                    Button(role: .destructive) {
                        clearCache()
                    } label: {
                        Label("清除图片缓存", systemImage: "trash")
                    }
                }
                
                Section {
                    if appState.isLoggedIn {
                        Button(role: .destructive) {
                            appState.logout()
                        } label: {
                            Label("退出当前账户", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
                
                Section("关于") {
                    LabeledContent("应用名称", value: "EMPlayer")
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("播放内核", value: "KSPlayer")
                    Link(destination: URL(string: "https://github.com/kingslay/KSPlayer")!) {
                        Label("KSPlayer 项目主页", systemImage: "safari")
                    }
                    Link(destination: URL(string: "https://emby.media/")!) {
                        Label("Emby 官网", systemImage: "safari")
                    }
                } footer: {
                    Text("© 2025 EMPlayer · 基于 KSPlayer 与 Emby API 构建")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .task { await computeCacheSize() }
        }
    }
    
    private func computeCacheSize() async {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("com.onevcat.Kingfisher.ImageCache.default")
        guard let u = url else { cacheSize = "—"; return }
        let size = Self.folderSize(u) ?? 0
        await MainActor.run { cacheSize = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
    }
    
    private static func folderSize(_ url: URL) -> Int? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { return nil }
        var total: Int = 0
        for case let u as URL in en {
            let v = try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0
        }
        return total
    }
    
    private func clearCache() {
        KingfisherManager.shared.cache.clearCache()
        Task { await computeCacheSize() }
    }
}
