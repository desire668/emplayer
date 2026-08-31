import SwiftUI
import EMPlayerCore

// MARK: - Add Server View（按「添加 Emby」截图重做）

struct ServerAddView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    // 服务器地址（单字段，支持粘贴完整 URL）
    @State private var address: String = ""
    // 基本信息
    @State private var name: String = ""
    @State private var remark: String = ""
    // 凭据
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var showPassword: Bool = false
    // 安全
    @State private var skipSSL: Bool = false
    // 状态
    @State private var isLoading: Bool = false
    @State private var errorMsg: String?

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        !isLoading && !trimmedAddress.isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: 服务器地址
                Section {
                    fieldRow(label: "地址", placeholder: "https://emby.taotu.ink", text: $address, keyboard: .URL)
                } footer: {
                    Text("可直接粘贴完整网址（含端口/路径，如 https://emby.taotu.ink:443）；不填协议时会自动尝试 HTTPS（443、8920）与 HTTP（80、8096）。")
                }

                // MARK: 名称 / 备注
                Section {
                    fieldRow(label: "名称", placeholder: "名称（可选，默认用服务器名）", text: $name)
                    fieldRow(label: "备注", placeholder: "备注（可选）", text: $remark)
                }

                // MARK: 用户名 / 密码
                Section {
                    fieldRow(label: "用户名", placeholder: "用户名（必填）", text: $username, keyboard: .asciiCapable)
                        .textContentType(.username)
                    HStack {
                        Text("密码")
                        Spacer()
                        Group {
                            if showPassword {
                                TextField("密码", text: $password)
                            } else {
                                SecureField("密码", text: $password)
                            }
                        }
                        .multilineTextAlignment(.trailing)
                        .textContentType(.password)
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 6)
                    }
                }

                // MARK: SSL
                Section {
                    Toggle(isOn: $skipSSL) {
                        Text("跳过 SSL 验证")
                    }
                } footer: {
                    Text("适用于自签名证书或 IP 直连 HTTPS 的服务器。首次连接遇到证书错误时 App 会自动跳过校验并重试；仅建议在可信网络中开启。")
                }

                // MARK: 提交
                Section {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView()
                            Text("正在连接…").foregroundStyle(.secondary)
                            Spacer()
                        }
                    } else {
                        Button {
                            Task { await submit() }
                        } label: {
                            Text("连接并添加")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(!canSubmit)
                        .listRowInsets(.init(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                    if let errorMsg {
                        Text(errorMsg)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("添加 Emby")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }

    // MARK: - 控件复用

    @ViewBuilder
    private func fieldRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        keyboard: UIKeyboardType = .default
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 动作

    private func submit() async {
        guard canSubmit else { return }
        isLoading = true
        errorMsg = nil
        defer { isLoading = false }

        do {
            try await appState.addServer(
                address: trimmedAddress,
                displayName: name,
                remark: remark,
                username: username,
                password: password,
                skipSSL: skipSSL
            )
            dismiss()
        } catch {
            errorMsg = "连接失败：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
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
                                        if s.accessToken != nil {
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
                            serverStore.add(server: savedServer)
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
                    Text(displayName)
                        .font(.headline)
                    if isActive {
                        Text("当前")
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color.indigo.opacity(0.25)))
                            .foregroundStyle(.indigo)
                    }
                }
                Text(server.displayURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if server.accessToken != nil {
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

    private var displayName: String {
        server.name.isEmpty ? server.host : server.name
    }
}

// MARK: - Server Edit View

struct ServerEditView: View {
    let originalServer: EmbyServer
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var serverStore: ServerStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var remark: String
    @State private var scheme: String
    @State private var host: String
    @State private var path: String
    @State private var port: String
    @State private var skipSSL: Bool
    @State private var saving: Bool = false

    init(server: EmbyServer) {
        self.originalServer = server
        self._name = State(initialValue: server.name)
        self._remark = State(initialValue: server.remark ?? "")
        self._scheme = State(initialValue: server.scheme)
        self._host = State(initialValue: server.host)
        self._path = State(initialValue: server.path ?? "")
        self._port = State(initialValue: server.port.map(String.init) ?? "")
        self._skipSSL = State(initialValue: server.skipSSL)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("名称")
                        Spacer()
                        TextField("名称（可选）", text: $name)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("备注")
                        Spacer()
                        TextField("备注（可选）", text: $remark)
                            .multilineTextAlignment(.trailing)
                    }
                }

                Section {
                    HStack {
                        Text("协议")
                        Spacer()
                        Menu {
                            Button { scheme = "https" } label: {
                                if scheme == "https" { Label("HTTPS", systemImage: "checkmark") } else { Text("HTTPS") }
                            }
                            Button { scheme = "http" } label: {
                                if scheme == "http" { Label("HTTP", systemImage: "checkmark") } else { Text("HTTP") }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(scheme.uppercased()).foregroundStyle(.primary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    HStack {
                        Text("主机")
                        Spacer()
                        TextField("主机（必填）", text: $host)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("路径")
                        Spacer()
                        TextField("路径（可选）", text: $path)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("端口")
                        Spacer()
                        TextField(scheme == "https" ? "443" : "8096", text: $port)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 120)
                    }
                }

                Section {
                    Toggle(isOn: $skipSSL) {
                        Text("跳过 SSL 验证")
                    }
                } footer: {
                    Text("适用于自签名证书或 IP 直连 HTTPS 的服务器（Emby HTTPS 默认端口 8920）。首次连接遇到证书错误时 App 会自动跳过校验重试；仅建议在可信网络中开启。")
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
                        .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty)
                        .listRowInsets(.init())
                        .listRowBackground(Color.clear)
                    }
                }

                Section("危险操作") {
                    Button(role: .destructive) {
                        serverStore.logout(server: originalServer)
                        appState.logout()
                        dismiss()
                    } label: {
                        Label("退出登录", systemImage: "pip.exit")
                    }

                    Button(role: .destructive) {
                        serverStore.remove(server: originalServer)
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

        var updated = originalServer
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.remark = remark.isEmpty ? nil : remark
        updated.scheme = scheme
        updated.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.port = Int(port.filter { $0.isNumber })
        let rawPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawPath.isEmpty {
            updated.path = nil
        } else {
            var p = rawPath
            while p.hasSuffix("/") { p.removeLast() }
            if !p.hasPrefix("/") { p = "/" + p }
            updated.path = p
        }
        updated.skipSSL = skipSSL
        updated.lastConnected = Date()

        // 连接信息变化会导致 id 变化：替换旧记录（保留登录令牌）
        serverStore.replace(serverId: originalServer.id, with: updated)
        if serverStore.activeServerId == originalServer.id || serverStore.activeServer == nil {
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
