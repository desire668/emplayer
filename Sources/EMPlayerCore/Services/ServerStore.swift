import Foundation
import KeychainSwift

// MARK: - Server Store

public final class ServerStore: ObservableObject {
    public static let shared = ServerStore()

    @Published public private(set) var servers: [EmbyServer] = []
    @Published public private(set) var activeServerId: String?

    private let keychain = KeychainSwift()
    private let userDefaults = UserDefaults(suiteName: "group.com.emplayer.app") ?? .standard

    private struct Keys {
        static let servers = "emplayer.servers.list"
        static let activeServerId = "emplayer.servers.active"
    }

    public init() {
        load()
    }

    // MARK: Active server

    public var activeServer: EmbyServer? {
        guard let id = activeServerId else { return servers.first }
        return servers.first { $0.id == id }
    }

    public func setActive(server: EmbyServer?) {
        activeServerId = server?.id
        save()
    }

    // MARK: CRUD

    public func add(server: EmbyServer) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
        } else {
            servers.append(server)
        }
        save()
    }

    public func remove(server: EmbyServer) {
        servers.removeAll { $0.id == server.id }
        // 清理 Keychain 中的令牌
        keychain.delete("emplayer.server.\(server.id).accessToken")
        if activeServerId == server.id {
            activeServerId = servers.first?.id
        }
        save()
    }

    public func update(server: EmbyServer) {
        if let idx = servers.firstIndex(where: { $0.id == server.id }) {
            servers[idx] = server
            save()
        }
    }

    /// 编辑服务器后连接信息可能变化（id 变化）：删旧记录、加新记录
    public func replace(serverId oldId: String, with newServer: EmbyServer) {
        if oldId != newServer.id {
            keychain.delete("emplayer.server.\(oldId).accessToken")
        }
        servers.removeAll { $0.id == oldId }
        add(server: newServer)
    }

    // MARK: Persistence

    private func save() {
        // 非敏感元数据存 UserDefaults；accessToken 单独进 Keychain
        let stripped = servers.map { s -> StoredServer in
            StoredServer(
                name: s.name,
                remark: s.remark,
                scheme: s.scheme,
                host: s.host,
                port: s.port,
                path: s.path,
                skipSSL: s.skipSSL,
                username: s.username,
                userId: s.userId,
                lastConnected: s.lastConnected
            )
        }
        if let data = try? JSONEncoder().encode(stripped) {
            userDefaults.set(data, forKey: Keys.servers)
        }
        userDefaults.set(activeServerId, forKey: Keys.activeServerId)

        for server in servers {
            let base = "emplayer.server.\(server.id)"
            if let token = server.accessToken, !token.isEmpty {
                keychain.set(token, forKey: base + ".accessToken", withAccess: .accessibleAfterFirstUnlock)
            } else {
                keychain.delete(base + ".accessToken")
            }
        }
    }

    private func load() {
        guard let data = userDefaults.data(forKey: Keys.servers),
              let stored = try? JSONDecoder().decode([StoredServer].self, from: data) else {
            self.servers = []
            self.activeServerId = nil
            return
        }

        self.servers = stored.compactMap { s -> EmbyServer? in
            var server: EmbyServer
            if let scheme = s.scheme, !scheme.isEmpty {
                // 新格式：拆分字段
                server = EmbyServer(
                    name: s.name,
                    remark: s.remark,
                    scheme: scheme,
                    host: s.host,
                    port: s.port,
                    path: s.path,
                    skipSSL: s.skipSSL ?? false,
                    username: s.username
                )
            } else if let migrated = EmbyServer(baseURLString: s.host, name: s.name) {
                // 旧格式迁移：host 字段曾存的是完整 URL
                server = migrated
                server.remark = s.remark
                server.username = s.username
            } else {
                return nil
            }
            server.userId = s.userId
            server.lastConnected = s.lastConnected
            let base = "emplayer.server.\(server.id)"
            server.accessToken = keychain.get(base + ".accessToken")
            return server
        }
        self.activeServerId = userDefaults.string(forKey: Keys.activeServerId) ?? servers.first?.id
    }

    public func logout(server: EmbyServer) {
        var s = server
        s.accessToken = nil
        s.userId = nil
        update(server: s)
    }
}

/// UserDefaults 中持久化的服务器元数据（全部字段可选，兼容旧版本数据）
private struct StoredServer: Codable {
    let name: String
    let remark: String?
    let scheme: String?
    let host: String
    let port: Int?
    let path: String?
    let skipSSL: Bool?
    let username: String?
    let userId: String?
    let lastConnected: Date?
}
