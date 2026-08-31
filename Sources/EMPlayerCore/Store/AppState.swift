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
        
        if server.accessToken != nil || server.apiKey != nil {
            // Token/API key present: try fetching user
            do {
                let uid = server.userId
                if uid == nil || uid!.isEmpty {
                    // Use API key without user (admin-style); fetch public users first and pick first admin
                    let users = try await EmbyClient.shared.getPublicUsers(host: server.host)
                    if let user = users.first {
                        var updated = server
                        updated.userId = user.id
                        updated.lastConnected = Date()
                        ServerStore.shared.update(server: updated)
                        currentServer = updated
                        currentUser = user
                        isLoggedIn = true
                    }
                } else {
                    do {
                        let user = try await EmbyClient.shared.getCurrentUser()
                        currentUser = user
                        isLoggedIn = true
                        var updated = server
                        updated.lastConnected = Date()
                        ServerStore.shared.update(server: updated)
                    } catch {
                        // Token likely expired
                        handleError(error, fallback: "登录已过期，请重新登录")
                        isLoggedIn = false
                    }
                }
            } catch {
                handleError(error, fallback: "连接服务器失败")
                isLoggedIn = false
            }
        } else {
            // No credentials — user needs to log in
            isLoggedIn = false
        }
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
