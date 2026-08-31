import SwiftUI
import EMPlayerCore

// MARK: - Server Add View

struct ServerAddView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var apiKey: String = ""
    @State private var isLoading: Bool = false
    @State private var testResult: String?
    @State private var showLogin: Bool = false
    @State private var tempServer: EmbyServer? = nil
    
    private var canSave: Bool {
        !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Label("名称", systemImage: "server.rack")
                        TextField("我的 Emby 服务器", text: $name)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }

                    HStack {
                        Label("地址", systemImage: "network")
                        TextField("http://192.168.1.100:8096", text: $host)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }

                    HStack {
                        Label("API Key", systemImage: "key")
                        SecureField("可选", text: $apiKey)
                            .autocapitalization(.none)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("服务器信息")
                } footer: {
                    Text("地址示例：\n• http://192.168.1.100:8096\n• https://emby.example.com\nAPI Key 在服务器管理面板 → 高级 → API密钥 中生成。不填时使用用户名密码登录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                
                Section {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Button {
                            Task { await testAndContinue() }
                        } label: {
                            Label("连接并继续", systemImage: "link.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(!canSave || isLoading)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .listRowInsets(.init(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                    
                    if let msg = testResult {
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("添加服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !serverStore.servers.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                    }
                }
            }
            .sheet(isPresented: $showLogin) {
                if let server = tempServer {
                    LoginView(server: server, presetAPIKey: apiKey) { savedServer in
                        serverStore.add(server: savedServer)
                        serverStore.setActive(server: savedServer)
                        Task { await appState.connect(to: savedServer) }
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func testAndContinue() async {
        isLoading = true
        testResult = nil
        defer { isLoading = false }
        
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverName = name.isEmpty ? (try? await EmbyClient.shared.getPublicSystemInfo(host: trimmedHost).serverName) ?? "Emby Server" : name
        
        var server = EmbyServer(name: serverName, host: trimmedHost)
        if !apiKey.isEmpty { server.apiKey = apiKey }
        
        do {
            let info = try await EmbyClient.shared.getPublicSystemInfo(host: trimmedHost)
            print("[AddServer] Connected: \(info.serverName) v\(info.version)")
            
            // If API key is provided, save & connect directly (no login needed)
            if !apiKey.isEmpty {
                serverStore.add(server: server)
                serverStore.setActive(server: server)
                Task { await appState.connect(to: server) }
                dismiss()
            } else {
                tempServer = server
                showLogin = true
            }
        } catch {
            testResult = "连接失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
        }
    }
}

// MARK: - Server List View

struct ServerListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverStore: ServerStore
    @State private var showAdd: Bool = false
    @State private var editingServer: EmbyServer?
    @State private var connectingServerId: String?
    
    var body: some View {
        NavigationStack {
            List {
                if serverStore.servers.isEmpty {
                    ContentUnavailableView(
                        "还没有服务器",
                        systemImage: "server.rack",
                        description: Text("点击右上角 + 添加你的 Emby 服务器。")
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    Section("已保存的服务器") {
                        ForEach(serverStore.servers) { s in
                            ServerRow(server: s, isActive: serverStore.activeServer?.id == s.id, isConnecting: connectingServerId == s.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    connectingServerId = s.id
                                    Task {
                                        await appState.connect(to: s)
                                        if s.accessToken != nil || s.apiKey != nil {
                                            serverStore.setActive(server: s)
                                        }
                                        connectingServerId = nil
                                    }
                                }
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        editingServer = s
                                    } label: {
                                        Label("编辑", systemImage: "pencil")
                                    }
                                    .tint(.indigo)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        serverStore.remove(server: s)
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .navigationTitle("EMPlayer")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                ServerAddView()
                    .environmentObject(appState)
                    .environmentObject(serverStore)
            }
            .sheet(item: $editingServer) { s in
                ServerEditView(server: s)
                    .environmentObject(appState)
                    .environmentObject(serverStore)
            }
            .sheet(isPresented: Binding(
                get: { appState.currentServer != nil && !appState.isLoggedIn },
                set: { if !$0 {} }
            )) {
                if let server = appState.currentServer {
                    NavigationStack {
                        LoginView(server: server) { savedServer in
                            serverStore.update(server: savedServer)
                            serverStore.setActive(server: savedServer)
                            Task { await appState.connect(to: savedServer) }
                        }
                    }
                }
            }
        }
    }
}

struct ServerRow: View {
    let server: EmbyServer
    let isActive: Bool
    let isConnecting: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? Color.indigo.opacity(0.35) : Color.gray.opacity(0.2))
                Image(systemName: "server.rack")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isActive ? .indigo : .secondary)
            }
            .frame(width: 44, height: 44)
            
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(server.name)
                        .font(.headline)
                    if isActive {
                        Text("当前")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.indigo.opacity(0.25)))
                            .foregroundStyle(.indigo)
                    }
                }
                Text(server.baseURL())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if server.accessToken != nil || server.apiKey != nil {
                        Label("已认证", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Label("未登录", systemImage: "lock.open")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if let date = server.lastConnected {
                        Text(date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            
            Spacer()
            if isConnecting {
                ProgressView()
            }
            Image(systemName: "chevron.right")
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Server Edit View

struct ServerEditView: View {
    let server: EmbyServer
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String
    @State private var host: String
    @State private var apiKey: String
    @State private var saving: Bool = false
    
    init(server: EmbyServer) {
        self.server = server
        self._name = State(initialValue: server.name)
        self._host = State(initialValue: server.host)
        self._apiKey = State(initialValue: server.apiKey ?? "")
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("服务器信息") {
                    HStack {
                        Label("名称", systemImage: "server.rack")
                        TextField("名称", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Label("地址", systemImage: "network")
                        TextField("地址", text: $host)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Label("API Key", systemImage: "key")
                        SecureField("API Key", text: $apiKey)
                            .multilineTextAlignment(.trailing)
                    }
                }
                
                Section {
                    if saving {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Button("保存") {
                            Task { await save() }
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .listRowInsets(.init())
                        .listRowBackground(Color.clear)
                    }
                }
                
                Section("危险操作") {
                    Button(role: .destructive) {
                        serverStore.logout(server: server)
                        appState.logout()
                        dismiss()
                    } label: {
                        Label("退出登录", systemImage: "pip.exit")
                    }
                    
                    Button(role: .destructive) {
                        serverStore.remove(server: server)
                        appState.logout()
                        dismiss()
                    } label: {
                        Label("删除服务器", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("编辑服务器")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
    
    private func save() async {
        saving = true
        defer { saving = false }
        var updated = EmbyServer(name: name.isEmpty ? server.name : name, host: host, apiKey: apiKey.isEmpty ? nil : apiKey)
        updated.userId = server.userId
        updated.accessToken = server.accessToken
        updated.lastConnected = Date()
        serverStore.update(server: updated)
        if serverStore.activeServer?.id == server.id {
            serverStore.setActive(server: updated)
            await appState.connect(to: updated)
        }
        dismiss()
    }
}

#Preview {
    ServerListView()
        .environmentObject(AppState.shared)
        .environmentObject(ServerStore.shared)
}
