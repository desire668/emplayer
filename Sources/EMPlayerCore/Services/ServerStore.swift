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
    
    // MARK: Persistence
    
    private func save() {
        // Save server list with tokens removed from UserDefaults; store tokens separately in Keychain
        let stripped = servers.map { s -> StoredServer in
            StoredServer(name: s.name, host: s.host, userId: s.userId, lastConnected: s.lastConnected)
        }
        if let data = try? JSONEncoder().encode(stripped) {
            userDefaults.set(data, forKey: Keys.servers)
        }
        userDefaults.set(activeServerId, forKey: Keys.activeServerId)
        
        // Store secrets in Keychain
        for server in servers {
            let base = "emplayer.server.\(server.id)"
            if let token = server.accessToken, !token.isEmpty {
                keychain.set(token, forKey: base + ".accessToken", withAccess: .accessibleAfterFirstUnlock)
            } else {
                keychain.delete(base + ".accessToken")
            }
            if let key = server.apiKey, !key.isEmpty {
                keychain.set(key, forKey: base + ".apiKey", withAccess: .accessibleAfterFirstUnlock)
            } else {
                keychain.delete(base + ".apiKey")
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
        
        self.servers = stored.map { s in
            var server = EmbyServer(name: s.name, host: s.host)
            server.userId = s.userId
            server.lastConnected = s.lastConnected
            let base = "emplayer.server.\(server.id)"
            server.accessToken = keychain.get(base + ".accessToken")
            server.apiKey = keychain.get(base + ".apiKey")
            return server
        }
        self.activeServerId = userDefaults.string(forKey: Keys.activeServerId) ?? servers.first?.id
    }
    
    public func logout(server: EmbyServer) {
        var s = server
        s.accessToken = nil
        s.userId = nil
        s.apiKey = nil
        update(server: s)
    }
}

private struct StoredServer: Codable {
    let name: String
    let host: String
    let userId: String?
    let lastConnected: Date?
}
