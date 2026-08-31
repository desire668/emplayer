import Foundation
import Combine

// MARK: - App State / Global Store

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()
    
    // MARK: Published state
    
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
        currentServer = server
        EmbyClient.shared.setServer(server)

        guard let token = server.accessToken, !token.isEmpty else {
            // 无令牌，需要登录
            isLoggedIn = false
            return
        }

        do {
            let user: EmbyUser
            if let uid = server.userId, !uid.isEmpty {
                user = try await EmbyClient.shared.getCurrentUser()
            } else {
                // 旧数据可能缺 userId：拉取公开用户取第一个（多数家用服务器即本人账号）
                let users = try await EmbyClient.shared.getPublicUsers(baseURL: server.baseURL(), skipSSL: server.skipSSL)
                guard let first = users.first else {
                    isLoggedIn = false
                    return
                }
                user = first
            }
            currentUser = user
            isLoggedIn = true
            var updated = server
            updated.userId = user.id
            updated.lastConnected = Date()
            ServerStore.shared.add(server: updated)
            currentServer = updated
        } catch {
            // 令牌过期等：回到登录态
            handleError(error, fallback: "登录已过期，请重新登录")
            isLoggedIn = false
        }
    }

    /// 「添加服务器」表单直连：校验地址 → 用户名密码登录 → 保存并激活
    @discardableResult
    public func configureServer(_ server: EmbyServer, username: String, password: String) async throws -> EmbyServer {
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. 探测服务器（顺便取真实服务器名；失败不阻塞登录）
        let info = try? await EmbyClient.shared.getPublicSystemInfo(baseURL: server.baseURL(), skipSSL: server.skipSSL)

        // 2. 用户名密码登录（login 内部会临时切换 currentServer，结束时还原）
        let auth = try await EmbyClient.shared.login(server: server, username: trimmedUser, password: password)

        var saved = server
        if saved.name.isEmpty {
            saved.name = info?.serverName ?? "Emby Server"
        }
        saved.username = trimmedUser
        saved.userId = auth.user.id
        saved.accessToken = auth.accessToken
        saved.lastConnected = Date()

        // 3. 关键：login() 返回时会还原 currentServer，必须显式把客户端
        //    切到已登录的服务器，否则后续 API 会打到旧服务器/空地址
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
        guard let server = currentServer else { return }
        do {
            let auth = try await EmbyClient.shared.login(server: server, username: username, password: password)
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
