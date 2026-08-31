import SwiftUI
import EMPlayerCore

struct LoginView: View {
    @EnvironmentObject var appState: AppState

    let server: EmbyServer
    var onSuccess: (EmbyServer) -> Void
    
    @State private var publicUsers: [EmbyUser] = []
    @State private var selectedUserId: String?
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var useManualUsername: Bool = false
    @State private var isLoading: Bool = false
    @State private var errorMsg: String?
    @State private var fetched: Bool = false
    
    private var canSubmit: Bool {
        isLoading == false && (
            useManualUsername
                ? !username.isEmpty
                : !(selectedUserId ?? "").isEmpty
        )
    }
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.indigo)
                        Text(server.name)
                            .font(.headline)
                    }
                    Text(server.baseURL())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("登录到服务器")
            }
            
            if !useManualUsername {
                Section("选择用户") {
                    if fetched && publicUsers.isEmpty {
                        HStack {
                            Spacer()
                            Text("服务器未公开用户，请手动输入用户名。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    } else if !fetched {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        ForEach(publicUsers) { u in
                            UserRow(user: u, selected: selectedUserId == u.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedUserId = u.id
                                    username = u.name
                                    if !u.hasPassword { password = "" }
                                }
                        }
                    }
                }
            }
            
            Section {
                Toggle(isOn: $useManualUsername.animation()) {
                    Label("手动输入用户名", systemImage: "person.text.rectangle")
                }
                
                if useManualUsername {
                    HStack {
                        Label("用户名", systemImage: "person")
                        TextField("用户名", text: $username)
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }
                }
                
                if shouldShowPassword {
                    HStack {
                        Label("密码", systemImage: "lock")
                        SecureField("密码", text: $password)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            
            Section {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    Button {
                        Task { await submit() }
                    } label: {
                        Label("登录", systemImage: "person.crop.circle.badge.checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canSubmit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowInsets(.init())
                    .listRowBackground(Color.clear)
                }
                if let m = errorMsg {
                    Text(m).font(.footnote).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("登录")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !fetched else { return }
            fetched = true
            if !publicUsers.isEmpty { return }
            do {
                let users = try await EmbyClient.shared.getPublicUsers(baseURL: server.baseURL(), skipSSL: server.skipSSL)
                publicUsers = users
                if let first = users.first {
                    selectedUserId = first.id
                    username = first.name
                }
            } catch {
                errorMsg = "获取用户列表失败，请手动输入用户名。"
            }
        }
    }
    
    private var shouldShowPassword: Bool {
        guard let uid = selectedUserId, let u = publicUsers.first(where: { $0.id == uid }) else { return true }
        return u.hasPassword
    }
    
    private func submit() async {
        isLoading = true
        errorMsg = nil
        defer { isLoading = false }
        
        // 使用服务器地址 + 用户名密码登录
        do {
            let auth = try await EmbyClient.shared.login(
                server: server,
                username: username,
                password: password
            )
            var saved = server
            saved.accessToken = auth.accessToken
            saved.userId = auth.user.id
            saved.username = username
            saved.lastConnected = Date()
            if saved.name.isEmpty {
                saved.name = (try? await EmbyClient.shared.getPublicSystemInfo(baseURL: server.baseURL(), skipSSL: server.skipSSL).serverName) ?? "Emby Server"
            }
            onSuccess(saved)
        } catch {
            errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct UserRow: View {
    let user: EmbyUser
    let selected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(selected ? Color.indigo.opacity(0.35) : Color.gray.opacity(0.2))
                    .frame(width: 40, height: 40)
                Image(systemName: user.isAdministrator ? "person.crop.circle.badge.star" : "person.crop.circle")
                    .foregroundStyle(selected ? .indigo : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name).font(.headline)
                HStack(spacing: 6) {
                    if user.isAdministrator {
                        Label("管理员", systemImage: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                    if user.hasPassword {
                        Label("已设置密码", systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("免密码", systemImage: "lock.open")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.indigo)
                    .font(.title3)
            }
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.indigo.opacity(0.1) : Color.clear)
        )
    }
}

#Preview {
    NavigationStack {
        LoginView(server: EmbyServer(name: "Test", scheme: "http", host: "localhost", port: 8096)) { _ in }
    }
    .environmentObject(AppState.shared)
}
