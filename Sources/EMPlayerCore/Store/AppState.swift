import Foundation
import Combine

// MARK: - App State / Global Store

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()
    
    // MARK: Published state
    
    @Published public private(set) var isAutoConnecting: Bool = false
    @Published public private(set) var isLoggedIn: Bool = false
    @Published public private(set) var currentUser: EmbyUser?
    @Published public private(set) var currentServer: EmbyServer?
    @Published public private(set) var libraries: [MediaFolder] = []
    @Published public private(set) var isLoadingLibraries: Bool = false
    @Published public private(set) var errorMessage: String? = nil
    @Published public private(set) var libraryCache: [String: QueryResult<MediaItem>] = [:]
    
    // MARK: Init
    
    public init() {
        _ = ServerStore.shared
    }
    
    // MARK: - Connection & Login
    
    public func connect(to server: EmbyServer) async {
        isAutoConnecting = true
        defer { isAutoConnecting = false }

        var server = server
        currentServer = server
        EmbyClient.shared.setServer(server)

        guard let token = server.accessToken, !token.isEmpty else {
            // 无令牌，需要登录
            isLoggedIn = false
            return
        }

        do {
            guard let user = try await fetchLoggedInUser(for: server) else {
                // 服务器无公开用户且本地缺 userId：回到登录态
                isLoggedIn = false
                return
            }
            currentUser = user
            isLoggedIn = true
            var updated = server
            updated.userId = user.id
            updated.lastConnected = Date()
            ServerStore.shared.add(server: updated)
            currentServer = updated
            invalidateCache()
            await loadLibraries(force: true)
        } catch {
            // 自签名 HTTPS 兜底：旧记录可能没开 skipSSL，自动信任证书后重试一次
            if server.scheme == "https", !server.skipSSL, EmbyAPIError.isTLSTrustFailure(error) {
                server.skipSSL = true
                currentServer = server
                EmbyClient.shared.setServer(server)
                do {
                    guard let user = try await fetchLoggedInUser(for: server) else {
                        isLoggedIn = false
                        return
                    }
                    currentUser = user
                    isLoggedIn = true
                    var updated = server
                    updated.userId = user.id
                    updated.lastConnected = Date()
                    ServerStore.shared.add(server: updated)
                    currentServer = updated
                    invalidateCache()
                    await loadLibraries(force: true)
                    return
                } catch {
                    handleError(error, fallback: "登录已过期，请重新登录")
                    isLoggedIn = false
                }
            } else {
                // 令牌过期等：回到登录态
                handleError(error, fallback: "登录已过期，请重新登录")
                isLoggedIn = false
            }
        }
    }

    /// 拉取已登录用户：有 userId 走 /Users/{id}，否则取公开用户列表第一个
    private func fetchLoggedInUser(for server: EmbyServer) async throws -> EmbyUser? {
        if let uid = server.userId, !uid.isEmpty {
            return try await EmbyClient.shared.getCurrentUser()
        }
        // 旧数据可能缺 userId：拉取公开用户取第一个（多数家用服务器即本人账号）
        let users = try await EmbyClient.shared.getPublicUsers(baseURL: server.baseURL(), skipSSL: server.skipSSL)
        return users.first
    }

    /// 「添加服务器」完整流程（重写版）：
    /// 地址智能解析 → 多候选依次尝试（https 443 / http 80 / https 8920 / http 8096）
    /// → 自签名证书自动信任重试 → 用户名密码登录 → 保存并激活。
    /// - Parameters:
    ///   - address: 用户输入的服务器地址（可粘贴完整 URL 或只填主机/IP）
    ///   - displayName: 可选自定义名称
    ///   - skipSSL: 用户手动开启「跳过 SSL 验证」
    @discardableResult
    public func addServer(
        address: String,
        displayName: String = "",
        remark: String = "",
        username: String,
        password: String,
        skipSSL: Bool = false
    ) async throws -> EmbyServer {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRemark = remark.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else { throw EmbyAPIError.invalidCredentials }

        let candidates = EmbyServer.candidates(
            from: address,
            name: trimmedName,
            remark: trimmedRemark.isEmpty ? nil : trimmedRemark,
            username: trimmedUser,
            skipSSL: skipSSL
        )
        guard !candidates.isEmpty else { throw EmbyAPIError.invalidURL }

        var lastError: Error = EmbyAPIError.invalidURL

        for var server in candidates {
            do {
                // 1. 探测服务器（最多 10 秒），取真实服务器名
                //    自签名证书 / 主机名不匹配：自动信任后再试一次；
                //    探测仍失败：协议/端口/路径可能不对（如 443 是路由器后台、8096 才是 Emby），
                //    无论什么错误都换下一个候选地址继续尝试
                var info: PublicSystemInfo? = nil
                do {
                    info = try await probeSystemInfo(server: server, timeoutSeconds: 10)
                } catch {
                    if server.scheme == "https", !server.skipSSL, EmbyAPIError.isTLSTrustFailure(error) {
                        server.skipSSL = true
                        info = try? await probeSystemInfo(server: server, timeoutSeconds: 10)
                    }
                    if info == nil {
                        lastError = error
                        continue
                    }
                }

                // 2. 用户名密码登录（TLS 失败同样自动信任重试一次）
                let auth: EmbyAuthResult
                do {
                    auth = try await EmbyClient.shared.login(server: server, username: trimmedUser, password: password)
                } catch EmbyAPIError.unauthorized {
                    // 401：服务器可达但凭据无效，立即提示，不必再试其他候选
                    throw EmbyAPIError.invalidCredentials
                } catch {
                    guard server.scheme == "https", !server.skipSSL, EmbyAPIError.isTLSTrustFailure(error) else { throw error }
                    server.skipSSL = true
                    let retriedAuth = try await EmbyClient.shared.login(server: server, username: trimmedUser, password: password)
                    // 3a. 自动信任后登录成功 → 保存并激活
                    return try await finishLogin(server: server, info: info, auth: retriedAuth, username: trimmedUser)
                }

                // 3. 登录成功 → 保存并激活
                return try await finishLogin(server: server, info: info, auth: auth, username: trimmedUser)
            } catch {
                // 登录阶段：网络层错误（连接中断/超时/取消）尝试下一个候选；
                // 业务错误（凭据错误/4xx/5xx/解码失败）立即抛出
                if isRetryableCandidateError(error) {
                    lastError = error
                    continue
                }
                throw error
            }
        }

        throw lastError
    }

    /// 探测 PublicSystemInfo，带超时控制（避免不可达地址长时间卡住整个候选列表）
    private func probeSystemInfo(server: EmbyServer, timeoutSeconds: UInt64) async throws -> PublicSystemInfo {
        let baseURL = server.baseURL()
        let skip = server.skipSSL
        return try await withThrowingTaskGroup(of: PublicSystemInfo.self) { group in
            group.addTask {
                try await EmbyClient.shared.getPublicSystemInfo(baseURL: baseURL, skipSSL: skip)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                throw EmbyAPIError.networkError(
                    NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
                )
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// 连接拒绝/超时/找不到主机/TLS 失败等「换个协议或端口可能成功」的错误；
    /// 401/404/4xx/5xx/解码失败等「服务器已响应」的错误不属于此类
    private func isRetryableCandidateError(_ error: Error) -> Bool {
        switch error as? EmbyAPIError {
        case .networkError, .cancelled, .invalidResponse:
            return true
        default:
            return false
        }
    }

    /// 登录成功后的统一收尾：补全名称 → 持久化 → 激活客户端与全局状态
    @discardableResult
    private func finishLogin(
        server: EmbyServer,
        info: PublicSystemInfo?,
        auth: EmbyAuthResult,
        username: String
    ) async throws -> EmbyServer {
        var saved = server
        if saved.name.isEmpty {
            saved.name = info?.serverName ?? "Emby Server"
        }
        saved.username = username
        saved.userId = auth.user.id
        saved.accessToken = auth.accessToken
        saved.lastConnected = Date()

        // login() 返回时会还原 currentServer，必须显式切到已登录服务器，
        // 否则后续 API 会打到旧服务器/空地址
        EmbyClient.shared.setServer(saved)
        EmbyClient.shared.setAuth(user: auth.user, accessToken: auth.accessToken)

        ServerStore.shared.add(server: saved)
        ServerStore.shared.setActive(server: saved)

        currentServer = saved
        currentUser = auth.user
        isLoggedIn = true
        libraries = []
        libraryCache = [:]
        return saved
    }
    
    public func login(username: String, password: String) async {
        guard var server = currentServer else { return }
        do {
            let auth: EmbyAuthResult
            do {
                auth = try await EmbyClient.shared.login(server: server, username: username, password: password)
            } catch {
                // 自签名 HTTPS 兜底：自动信任证书后重试一次
                guard server.scheme == "https", !server.skipSSL, EmbyAPIError.isTLSTrustFailure(error) else { throw error }
                server.skipSSL = true
                currentServer = server
                EmbyClient.shared.setServer(server)
                auth = try await EmbyClient.shared.login(server: server, username: username, password: password)
            }
            EmbyClient.shared.setAuth(user: auth.user, accessToken: auth.accessToken)
            currentUser = auth.user
            isLoggedIn = true
            var updated = server
            updated.accessToken = auth.accessToken
            updated.userId = auth.user.id
            updated.lastConnected = Date()
            ServerStore.shared.add(server: updated)
            ServerStore.shared.setActive(server: updated)
            currentServer = updated
        } catch {
            handleError(error, fallback: "登录失败")
        }
    }
    
    public func logout() {
        if let server = currentServer {
            ServerStore.shared.logout(server: server)
        }
        EmbyClient.shared.clearAuth()
        isLoggedIn = false
        currentUser = nil
        libraries = []
        libraryCache = [:]
    }
    
    // MARK: Libraries
    
    public func loadLibraries(force: Bool = false) async {
        guard isLoggedIn else { return }
        if !force && !libraries.isEmpty { return }
        isLoadingLibraries = true
        defer { isLoadingLibraries = false }
        do {
            libraries = try await EmbyClient.shared.getMediaFolders()
        } catch {
            handleError(error, fallback: "加载媒体库失败")
        }
    }
    
    // MARK: Library items
    
    public func loadLibraryItems(
        folder: MediaFolder,
        recursive: Bool = true,
        sortBy: [String] = ["SortName"],
        filters: [String] = []
    ) async throws -> QueryResult<MediaItem> {
        let key = "\(folder.id)-\(recursive)-\(sortBy.joined())-\(filters.joined())"
        if let cached = libraryCache[key] { return cached }
        let result = try await EmbyClient.shared.getItems(
            parentId: folder.id,
            filters: filters.isEmpty ? nil : filters,
            sortBy: sortBy,
            recursive: recursive
        )
        libraryCache[key] = result
        return result
    }
    
    public func invalidateCache() {
        libraryCache.removeAll()
    }
    
    // MARK: Error handling
    
    public func handleError(_ error: Error, fallback: String = "发生错误") {
        let msg = (error as? LocalizedError)?.errorDescription ?? fallback
        errorMessage = msg
    }
    
    public func clearError() {
        errorMessage = nil
    }
}
