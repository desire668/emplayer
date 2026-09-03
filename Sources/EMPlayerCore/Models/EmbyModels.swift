import Foundation

// MARK: - Lenient Decoding Helpers

// Emby（ServiceStack.Text）与 Jellyfin（System.Text.Json）序列化行为不同：
// null/默认值字段可能被省略，部分字段类型在不同版本间也有差异
// （如 MediaStream.NalLengthSize 是字符串、可空布尔会返回 null、枚举偶尔以数字返回）。
// 以下容错解码保证「单个字段异常不会导致整个响应解码失败」，避免首页整屏报错。

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue) }
}

extension KeyedDecodingContainer {
    /// 字符串：字段缺失 / null / 类型不符均返回 nil；数字与布尔会被转成字符串
    func lenientString(forKey key: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let n = try? decodeIfPresent(Int64.self, forKey: key) { return String(n) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return String(d) }
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return String(b) }
        return nil
    }

    /// 布尔：兼容 0/1 数字与 "true"/"false" 字符串；缺失或 null 返回 default
    func lenientBool(forKey key: Key, default def: Bool = false) -> Bool {
        if let b = try? decodeIfPresent(Bool.self, forKey: key) { return b }
        if let n = try? decodeIfPresent(Int.self, forKey: key) { return n != 0 }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            switch s.lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return def
            }
        }
        return def
    }

    /// Int：兼容数字字符串
    func lenientInt(forKey key: Key) -> Int? {
        if let n = try? decodeIfPresent(Int.self, forKey: key) { return n }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int(s) }
        return nil
    }

    /// Int64：兼容数字字符串（ticks / size 等大数值）
    func lenientInt64(forKey key: Key) -> Int64? {
        if let n = try? decodeIfPresent(Int64.self, forKey: key) { return n }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Int64(d) }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Int64(s) }
        return nil
    }

    /// Double：兼容数字字符串
    func lenientDouble(forKey key: Key) -> Double? {
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return d }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }

    /// 枚举字段：正常返回字符串名；个别版本/场景返回数字时按 numericMapping 转换
    func lenientEnumName(forKey key: Key, numericMapping: [Int: String]) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key), !s.isEmpty { return s }
        if let n = try? decodeIfPresent(Int.self, forKey: key) { return numericMapping[n] }
        return nil
    }
}

/// ProviderIds：服务端声明为 Dictionary<string,string>，
/// 但个别刮削器/插件可能写入数字值，统一转成字符串，避免整个条目解码失败
public struct ProviderIdMap: Codable, Equatable, Hashable {
    public let values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: AnyCodingKey.self) else {
            values = [:]
            return
        }
        var dict: [String: String] = [:]
        for key in c.allKeys {
            if let s = try? c.decodeIfPresent(String.self, forKey: key), let s {
                dict[key.stringValue] = s
            } else if let n = try? c.decodeIfPresent(Int64.self, forKey: key), let n {
                dict[key.stringValue] = String(n)
            } else if let d = try? c.decodeIfPresent(Double.self, forKey: key), let d {
                dict[key.stringValue] = String(d)
            } else if let b = try? c.decodeIfPresent(Bool.self, forKey: key), let b {
                dict[key.stringValue] = String(b)
            }
        }
        values = dict
    }
}

// MARK: - Emby Server Info

public struct EmbyServer: Codable, Identifiable, Equatable, Hashable {
    /// 稳定标识：只与连接信息有关（改名称/备注不影响 id）
    public var id: String {
        "\(scheme)://\(host.lowercased()):\(port ?? 0)\(normalizedPath)"
    }
    /// 用户自定义显示名称，可空；为空时用服务器返回的 ServerName
    public var name: String
    /// 备注（可选）
    public var remark: String?
    /// "http" 或 "https"
    public var scheme: String
    /// 纯主机名 / IP（不含协议、端口、路径）
    public var host: String
    /// 端口；nil 表示使用协议默认端口
    public var port: Int?
    /// 反向代理子路径，如 "/emby"，可空
    public var path: String?
    /// 跳过 SSL 证书校验（自签名证书场景）
    public var skipSSL: Bool
    /// 上次登录使用的用户名（用于回填）
    public var username: String?
    public var userId: String?
    public var accessToken: String?
    public var lastConnected: Date?

    public init(
        name: String = "",
        remark: String? = nil,
        scheme: String = "https",
        host: String,
        port: Int? = nil,
        path: String? = nil,
        skipSSL: Bool = false,
        username: String? = nil
    ) {
        self.name = name
        self.remark = remark
        self.scheme = scheme.lowercased() == "http" ? "http" : "https"
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
        self.path = path
        self.skipSSL = skipSSL
        self.username = username
    }

    /// 从完整 URL 字符串解析（兼容旧数据 / 手填地址），失败返回 nil
    public init?(baseURLString: String, name: String = "") {
        var str = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !str.isEmpty else { return nil }
        if !str.contains("://") { str = "https://" + str }
        guard let comps = URLComponents(string: str), let host = comps.host, !host.isEmpty else { return nil }
        self.init(
            name: name,
            scheme: comps.scheme ?? "https",
            host: host,
            port: comps.port,
            path: comps.path.isEmpty ? nil : comps.path
        )
    }

    /// 智能解析用户在「服务器地址」栏输入的内容：
    /// - 支持粘贴完整 URL（`https://emby.taotu.ink:443`、`http://192.168.1.10:8096/emby`）
    /// - 支持只填主机 / IP（`emby.taotu.ink`、`192.168.1.10:8920`），缺协议时默认 HTTPS
    public static func parse(address raw: String, name: String = "", remark: String? = nil, username: String? = nil) -> EmbyServer? {
        var str = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !str.isEmpty else { return nil }
        // 容错：误输入重复协议头（如 https://https://host），只保留最后一个
        while true {
            let lower = str.lowercased()
            if lower.hasPrefix("https://https://") || lower.hasPrefix("https://http://") {
                str = String(str.dropFirst("https://".count))
            } else if lower.hasPrefix("http://http://") || lower.hasPrefix("http://https://") {
                str = String(str.dropFirst("http://".count))
            } else {
                break
            }
        }
        if !str.lowercased().hasPrefix("http://"), !str.lowercased().hasPrefix("https://") {
            str = "https://" + str
        }
        guard let comps = URLComponents(string: str), let host = comps.host, !host.isEmpty else { return nil }
        var path = comps.path
        while path.hasSuffix("/") { path.removeLast() }
        return EmbyServer(
            name: name,
            remark: remark,
            scheme: comps.scheme ?? "https",
            host: host,
            port: comps.port,
            path: path.isEmpty ? nil : path,
            username: username
        )
    }

    /// 生成连接尝试候选列表：
    /// - 用户写了协议（http:// 或 https://）→ 只试该地址
    /// - 没写协议 → 依次尝试 https(443)、http(80)，以及 Emby 常见默认端口 https(8920)、http(8096)
    public static func candidates(
        from address: String,
        name: String = "",
        remark: String? = nil,
        username: String? = nil,
        skipSSL: Bool = false
    ) -> [EmbyServer] {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = parse(address: raw, name: name, remark: remark, username: username) else { return [] }
        let hadScheme = raw.lowercased().contains("://")

        func make(_ scheme: String, _ port: Int?) -> EmbyServer {
            var s = parsed
            s.scheme = scheme
            s.port = port
            s.skipSSL = skipSSL
            return s
        }

        if hadScheme {
            return [parsed]
        }
        var list: [EmbyServer] = [
            make("https", 443),
            make("http", 80)
        ]
        if parsed.port == nil {
            list.append(make("https", 8920))
            list.append(make("http", 8096))
        }
        // 去重（同 scheme/host/port/path 只试一次）
        var seen = Set<String>()
        return list.filter { seen.insert($0.id).inserted }
    }

    /// 规范化后的子路径：保证以 "/" 开头、不以 "/" 结尾；空路径返回 ""
    public var normalizedPath: String {
        guard var p = path?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return "" }
        while p.hasSuffix("/") { p.removeLast() }
        if !p.hasPrefix("/") { p = "/" + p }
        return p
    }

    /// 完整基础地址，如 "https://emby.example.com:443/emby"
    public func baseURL() -> String {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var portPart = ""
        if let port = port, port > 0 { portPart = ":\(port)" }
        return "\(scheme)://\(h)\(portPart)\(normalizedPath)"
    }

    /// 展示给用户看的地址（默认端口不显示）
    public var displayURL: String {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var portPart = ""
        if let port = port, port > 0 {
            let isDefault = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
            if !isDefault { portPart = ":\(port)" }
        }
        return "\(scheme)://\(h)\(portPart)\(normalizedPath)"
    }
}

// MARK: - User Info

public struct EmbyUser: Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let serverId: String?
    public let hasPassword: Bool
    public let hasConfiguredPassword: Bool
    /// 注意：Emby 的 User DTO 顶层并不总是返回 IsAdministrator/IsDisabled（它们在 Policy 内），必须容错
    public let isAdministrator: Bool
    public let isDisabled: Bool
    public let policy: UserPolicy?
    public let configuration: UserConfiguration?

    public init(
        id: String,
        name: String,
        serverId: String? = nil,
        hasPassword: Bool = false,
        hasConfiguredPassword: Bool = false,
        isAdministrator: Bool = false,
        isDisabled: Bool = false,
        policy: UserPolicy? = nil,
        configuration: UserConfiguration? = nil
    ) {
        self.id = id
        self.name = name
        self.serverId = serverId
        self.hasPassword = hasPassword
        self.hasConfiguredPassword = hasConfiguredPassword
        self.isAdministrator = isAdministrator
        self.isDisabled = isDisabled
        self.policy = policy
        self.configuration = configuration
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverId = "ServerId"
        case hasPassword = "HasPassword"
        case hasConfiguredPassword = "HasConfiguredPassword"
        case isAdministrator = "IsAdministrator"
        case isDisabled = "IsDisabled"
        case policy = "Policy"
        case configuration = "Configuration"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        serverId = try? c.decodeIfPresent(String.self, forKey: .serverId)
        hasPassword = (try? c.decodeIfPresent(Bool.self, forKey: .hasPassword)) ?? false
        hasConfiguredPassword = (try? c.decodeIfPresent(Bool.self, forKey: .hasConfiguredPassword)) ?? false
        isAdministrator = (try? c.decodeIfPresent(Bool.self, forKey: .isAdministrator)) ?? false
        isDisabled = (try? c.decodeIfPresent(Bool.self, forKey: .isDisabled)) ?? false
        policy = try? c.decodeIfPresent(UserPolicy.self, forKey: .policy)
        configuration = try? c.decodeIfPresent(UserConfiguration.self, forKey: .configuration)
    }
}

public struct UserPolicy: Codable, Equatable, Hashable {
    public let isAdministrator: Bool
    public let isHidden: Bool
    public let isDisabled: Bool

    enum CodingKeys: String, CodingKey {
        case isAdministrator = "IsAdministrator"
        case isHidden = "IsHidden"
        case isDisabled = "IsDisabled"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isAdministrator = (try? c.decodeIfPresent(Bool.self, forKey: .isAdministrator)) ?? false
        isHidden = (try? c.decodeIfPresent(Bool.self, forKey: .isHidden)) ?? false
        isDisabled = (try? c.decodeIfPresent(Bool.self, forKey: .isDisabled)) ?? false
    }
}

public struct UserConfiguration: Codable, Equatable, Hashable {
    public let audioLanguagePreference: String?
    public let subtitleLanguagePreference: String?
    public let playDefaultAudioTrack: Bool
    public let displayMissingEpisodes: Bool

    enum CodingKeys: String, CodingKey {
        case audioLanguagePreference = "AudioLanguagePreference"
        case subtitleLanguagePreference = "SubtitleLanguagePreference"
        case playDefaultAudioTrack = "PlayDefaultAudioTrack"
        case displayMissingEpisodes = "DisplayMissingEpisodes"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        audioLanguagePreference = try? c.decodeIfPresent(String.self, forKey: .audioLanguagePreference)
        subtitleLanguagePreference = try? c.decodeIfPresent(String.self, forKey: .subtitleLanguagePreference)
        playDefaultAudioTrack = (try? c.decodeIfPresent(Bool.self, forKey: .playDefaultAudioTrack)) ?? true
        displayMissingEpisodes = (try? c.decodeIfPresent(Bool.self, forKey: .displayMissingEpisodes)) ?? false
    }
}

// MARK: - Auth Result

public struct EmbyAuthResult: Codable {
    public let accessToken: String
    public let serverId: String
    public let user: EmbyUser
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken"
        case serverId = "ServerId"
        case user = "User"
    }
}

// MARK: - Public System Info

public struct PublicSystemInfo: Codable {
    public let localAddress: String?
    public let wanAddress: String?
    public let serverName: String
    public let version: String
    public let id: String?
    
    enum CodingKeys: String, CodingKey {
        case localAddress = "LocalAddress"
        case wanAddress = "WanAddress"
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
    }
}

// MARK: - Media Item (Base Item DTO)

public struct MediaItem: Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let originalTitle: String?
    public let type: String?
    public let mediaType: String?
    public let overview: String?
    public let tagline: String?
    public let officialRating: String?
    public let cumulativeRunTimeTicks: Int64?
    public let runTimeTicks: Int64?
    public let productionYear: Int?
    public let indexNumber: Int?
    public let parentIndexNumber: Int?
    public let seriesId: String?
    public let seasonId: String?
    public let seriesName: String?
    public let seasonName: String?
    public let album: String?
    public let artists: [String]?
    public let imageTags: ImageTags?
    public let backdropImageTags: [String]?
    public let userData: UserData?
    public let locationType: String?
    public let videoType: String?
    public var mediaSources: [MediaSource]?
    public let mediaStreams: [MediaStream]?
    public let genres: [String]?
    public let studios: [NameIdPair]?
    public let providerIds: ProviderIdMap?
    public let dateCreated: String?
    public let premiereDate: String?
    public let childCount: Int?
    public let recursiveItemCount: Int?
    
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case originalTitle = "OriginalTitle"
        case type = "Type"
        case mediaType = "MediaType"
        case overview = "Overview"
        case tagline = "Tagline"
        case officialRating = "OfficialRating"
        case cumulativeRunTimeTicks = "CumulativeRunTimeTicks"
        case runTimeTicks = "RunTimeTicks"
        case productionYear = "ProductionYear"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case seriesId = "SeriesId"
        case seasonId = "SeasonId"
        case seriesName = "SeriesName"
        case seasonName = "SeasonName"
        case album = "Album"
        case artists = "Artists"
        case imageTags = "ImageTags"
        case backdropImageTags = "BackdropImageTags"
        case userData = "UserData"
        case locationType = "LocationType"
        case videoType = "VideoType"
        case mediaSources = "MediaSources"
        case mediaStreams = "MediaStreams"
        case genres = "Genres"
        case studios = "Studios"
        case providerIds = "ProviderIds"
        case dateCreated = "DateCreated"
        case premiereDate = "PremiereDate"
        case childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount"
    }
    
    public var durationSeconds: Int {
        let ticks = (runTimeTicks ?? cumulativeRunTimeTicks ?? 0)
        return Int(ticks / 10_000_000)
    }
    
    public var durationString: String {
        let sec = durationSeconds
        if sec <= 0 { return "" }
        let h = sec / 3600
        let m = (sec % 3600) / 60
        let s = sec % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
    
    public var played: Bool {
        userData?.played ?? false
    }
    
    public var playbackPositionTicks: Int64 {
        userData?.playbackPositionTicks ?? 0
    }
}

public struct ImageTags: Codable, Equatable, Hashable {
    public let primary: String?
    public let thumb: String?
    public let logo: String?
    public let art: String?
    public let banner: String?
    public let box: String?
    public let screenshot: String?
    public let menu: String?
    public let chapter: String?
    public let boxRear: String?
    public let profile: String?
    
    enum CodingKeys: String, CodingKey {
        case primary = "Primary"
        case thumb = "Thumb"
        case logo = "Logo"
        case art = "Art"
        case banner = "Banner"
        case box = "Box"
        case screenshot = "Screenshot"
        case menu = "Menu"
        case chapter = "Chapter"
        case boxRear = "BoxRear"
        case profile = "Profile"
    }
}

public struct ImageTag: Codable, Equatable, Hashable {
    public let imageType: String?
    public let imageTag: String?
}

public struct UserData: Codable, Equatable, Hashable {
    public let rating: Double?
    public let playedPercentage: Double?
    public let playbackPositionTicks: Int64?
    public let playCount: Int?
    public let isFavorite: Bool
    public let likes: Bool?
    public let played: Bool
    public let key: String?
    public let itemId: String?

    enum CodingKeys: String, CodingKey {
        case rating = "Rating"
        case playedPercentage = "PlayedPercentage"
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case likes = "Likes"
        case played = "Played"
        case key = "Key"
        case itemId = "ItemId"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rating = c.lenientDouble(forKey: .rating)
        playedPercentage = c.lenientDouble(forKey: .playedPercentage)
        playbackPositionTicks = c.lenientInt64(forKey: .playbackPositionTicks)
        playCount = c.lenientInt(forKey: .playCount)
        // Emby（ServiceStack.Text）可能省略值为 false 的布尔字段，缺失时按 false 处理
        isFavorite = c.lenientBool(forKey: .isFavorite)
        likes = (try? c.decodeIfPresent(Bool.self, forKey: .likes)) ?? nil
        played = c.lenientBool(forKey: .played)
        key = c.lenientString(forKey: .key)
        itemId = c.lenientString(forKey: .itemId)
    }
}

public struct NameIdPair: Codable, Equatable, Hashable {
    public let name: String
    /// 注意：Emby 的 Studios 返回 NameLongIdPair（Id 为数字，可能为 null），
    /// Jellyfin 才返回字符串 GUID；这里统一容错解码
    public let id: String?

    public init(name: String, id: String? = nil) {
        self.name = name
        self.id = id
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case id = "Id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        if let s = try? c.decodeIfPresent(String.self, forKey: .id), let s {
            id = s
        } else if let n = try? c.decodeIfPresent(Int64.self, forKey: .id), let n {
            id = String(n)
        } else {
            id = nil
        }
    }
}

// MARK: - Media Source & Media Stream

public struct MediaSource: Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let `protocol`: String?
    public let path: String?
    public let container: String?
    public let size: Int64?
    public let name: String?
    public let runTimeTicks: Int64?
    public let supportsDirectPlay: Bool
    public let supportsDirectStream: Bool
    public let supportsTranscoding: Bool
    public let transcodingSubProfiles: [String]?
    public let mediaStreams: [MediaStream]?
    public let bitrate: Int?
    public let formats: [String]?
    
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case `protocol` = "Protocol"
        case path = "Path"
        case container = "Container"
        case size = "Size"
        case name = "Name"
        case runTimeTicks = "RunTimeTicks"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case transcodingSubProfiles = "TranscodingSubProfiles"
        case mediaStreams = "MediaStreams"
        case bitrate = "Bitrate"
        case formats = "Formats"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lenientString(forKey: .id) ?? ""
        // Protocol 枚举：服务端正常返回字符串名（File/Http...），个别版本返回数字；
        // 字段整体缺失时对应服务端枚举默认值 File(0)，即本地文件直连
        let protocolNames = [0: "File", 1: "Http", 2: "Rtmp", 3: "Rtsp", 4: "Udp", 5: "Rtp", 6: "Ftp"]
        if let name = c.lenientEnumName(forKey: .protocol, numericMapping: protocolNames) {
            `protocol` = name
        } else if c.contains(.protocol) {
            `protocol` = nil
        } else {
            `protocol` = "File"
        }
        path = c.lenientString(forKey: .path)
        container = c.lenientString(forKey: .container)
        size = c.lenientInt64(forKey: .size)
        name = c.lenientString(forKey: .name)
        runTimeTicks = c.lenientInt64(forKey: .runTimeTicks)
        // 服务端构造函数中这三个字段默认值为 true，字段缺失（默认值被省略）时按 true 处理
        supportsDirectPlay = c.lenientBool(forKey: .supportsDirectPlay, default: true)
        supportsDirectStream = c.lenientBool(forKey: .supportsDirectStream, default: true)
        supportsTranscoding = c.lenientBool(forKey: .supportsTranscoding, default: true)
        transcodingSubProfiles = (try? c.decodeIfPresent([String].self, forKey: .transcodingSubProfiles)) ?? nil
        mediaStreams = (try? c.decodeIfPresent([MediaStream].self, forKey: .mediaStreams)) ?? nil
        bitrate = c.lenientInt(forKey: .bitrate)
        formats = (try? c.decodeIfPresent([String].self, forKey: .formats)) ?? nil
    }
}

public struct MediaStream: Codable, Equatable, Hashable {
    public let codec: String?
    public let codecTag: String?
    public let language: String?
    public let colorTransfer: String?
    public let colorPrimaries: String?
    public let colorSpace: String?
    public let comment: String?
    public let streamStartTimeTicks: Int64?
    public let timeBase: String?
    public let videoRange: String?
    public let displayTitle: String?
    /// 注意：服务端该字段为字符串（如 "0"、"4"、""），不是数字
    public let nalLengthSize: String?
    public let isInterlaced: Bool
    public let isAnamorphic: Bool
    public let width: Int?
    public let height: Int?
    public let averageFrameRate: Double?
    public let realFrameRate: Double?
    public let level: Double?
    public let bitDepth: Int?
    public let bitRate: Int?
    public let refFrames: Int?
    public let rotation: Int?
    public let channels: Int?
    public let sampleRate: Int?
    public let isDefault: Bool
    public let isForced: Bool
    public let type: String? // "Video", "Audio", "Subtitle"
    public let profile: String?
    public let aspectRatio: String?
    public let index: Int
    public let score: Int?
    
    enum CodingKeys: String, CodingKey {
        case codec = "Codec"
        case codecTag = "CodecTag"
        case language = "Language"
        case colorTransfer = "ColorTransfer"
        case colorPrimaries = "ColorPrimaries"
        case colorSpace = "ColorSpace"
        case comment = "Comment"
        case streamStartTimeTicks = "StreamStartTimeTicks"
        case timeBase = "TimeBase"
        case videoRange = "VideoRange"
        case displayTitle = "DisplayTitle"
        case nalLengthSize = "NalLengthSize"
        case isInterlaced = "IsInterlaced"
        case isAnamorphic = "IsAnamorphic"
        case width = "Width"
        case height = "Height"
        case averageFrameRate = "AverageFrameRate"
        case realFrameRate = "RealFrameRate"
        case level = "Level"
        case bitDepth = "BitDepth"
        case bitRate = "BitRate"
        case refFrames = "RefFrames"
        case rotation = "Rotation"
        case channels = "Channels"
        case sampleRate = "SampleRate"
        case isDefault = "IsDefault"
        case isForced = "IsForced"
        case type = "Type"
        case profile = "Profile"
        case aspectRatio = "AspectRatio"
        case index = "Index"
        case score = "Score"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        codec = c.lenientString(forKey: .codec)
        codecTag = c.lenientString(forKey: .codecTag)
        language = c.lenientString(forKey: .language)
        colorTransfer = c.lenientString(forKey: .colorTransfer)
        colorPrimaries = c.lenientString(forKey: .colorPrimaries)
        colorSpace = c.lenientString(forKey: .colorSpace)
        comment = c.lenientString(forKey: .comment)
        streamStartTimeTicks = c.lenientInt64(forKey: .streamStartTimeTicks)
        timeBase = c.lenientString(forKey: .timeBase)
        videoRange = c.lenientString(forKey: .videoRange)
        displayTitle = c.lenientString(forKey: .displayTitle)
        nalLengthSize = c.lenientString(forKey: .nalLengthSize)
        // 非可选布尔：服务端可能省略（默认 false）或返回 null，缺失时按 false 处理
        isInterlaced = c.lenientBool(forKey: .isInterlaced)
        isAnamorphic = c.lenientBool(forKey: .isAnamorphic)
        width = c.lenientInt(forKey: .width)
        height = c.lenientInt(forKey: .height)
        averageFrameRate = c.lenientDouble(forKey: .averageFrameRate)
        realFrameRate = c.lenientDouble(forKey: .realFrameRate)
        level = c.lenientDouble(forKey: .level)
        bitDepth = c.lenientInt(forKey: .bitDepth)
        bitRate = c.lenientInt(forKey: .bitRate)
        refFrames = c.lenientInt(forKey: .refFrames)
        rotation = c.lenientInt(forKey: .rotation)
        channels = c.lenientInt(forKey: .channels)
        sampleRate = c.lenientInt(forKey: .sampleRate)
        isDefault = c.lenientBool(forKey: .isDefault)
        isForced = c.lenientBool(forKey: .isForced)
        // Type 枚举：正常返回字符串名，个别版本/场景返回数字（0=Audio,1=Video,2=Subtitle...）；
        // 字段整体缺失时对应服务端枚举默认值 Audio(0)
        let streamTypeNames = [0: "Audio", 1: "Video", 2: "Subtitle", 3: "EmbeddedImage", 4: "Data", 5: "Lyric"]
        if let name = c.lenientEnumName(forKey: .type, numericMapping: streamTypeNames) {
            type = name
        } else if c.contains(.type) {
            type = nil
        } else {
            type = "Audio"
        }
        profile = c.lenientString(forKey: .profile)
        aspectRatio = c.lenientString(forKey: .aspectRatio)
        // 视频流的 Index 通常为 0，服务端可能省略该默认值字段
        index = c.lenientInt(forKey: .index) ?? 0
        score = c.lenientInt(forKey: .score)
    }
}

// MARK: - Playback Info

public struct PlaybackInfoResponse: Codable {
    public let mediaSources: [MediaSource]
    public let playSessionId: String?
    public let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
        case errorCode = "ErrorCode"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let arr = try? c.decodeIfPresent([MediaSource].self, forKey: .mediaSources), let arr {
            mediaSources = arr
        } else {
            mediaSources = []
        }
        playSessionId = c.lenientString(forKey: .playSessionId)
        errorCode = c.lenientString(forKey: .errorCode)
    }
}

public struct PlaybackInfoRequest: Codable {
    public let id: String
    public let userId: String
    public let maxStreamingBitrate: Int
    public let startTimeTicks: Int64
    public let audioStreamIndex: Int?
    public let subtitleStreamIndex: Int?
    public let maxAudioChannels: Int
    public let mediaSourceId: String?
    public let liveStreamId: String?
    public let deviceProfile: DeviceProfile
    
    public init(
        id: String,
        userId: String,
        maxStreamingBitrate: Int = 20_000_000,
        startTimeTicks: Int64 = 0,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        maxAudioChannels: Int = 8,
        mediaSourceId: String? = nil
    ) {
        self.id = id
        self.userId = userId
        self.maxStreamingBitrate = maxStreamingBitrate
        self.startTimeTicks = startTimeTicks
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.maxAudioChannels = maxAudioChannels
        self.mediaSourceId = mediaSourceId
        self.liveStreamId = nil
        self.deviceProfile = .iOSDefault()
    }
    
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case userId = "UserId"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case startTimeTicks = "StartTimeTicks"
        case audioStreamIndex = "AudioStreamIndex"
        case subtitleStreamIndex = "SubtitleStreamIndex"
        case maxAudioChannels = "MaxAudioChannels"
        case mediaSourceId = "MediaSourceId"
        case liveStreamId = "LiveStreamId"
        case deviceProfile = "DeviceProfile"
    }
}

public struct DeviceProfile: Codable {
    public let name: String
    public let maxStreamingBitrate: Int
    public let maxStaticBitrate: Int
    public let musicStreamingTranscodingBitrate: Int
    public let directPlayProfiles: [DirectPlayProfile]
    public let transcodingProfiles: [TranscodingProfile]
    public let codecProfiles: [CodecProfile]
    public let subtitleProfiles: [SubtitleProfile]
    public let responseProfiles: [ResponseProfile]
    
    static func iOSDefault() -> DeviceProfile {
        DeviceProfile(
            name: "EMPlayer iOS",
            maxStreamingBitrate: 20_000_000,
            maxStaticBitrate: 20_000_000,
            musicStreamingTranscodingBitrate: 192_000,
            directPlayProfiles: [
                DirectPlayProfile(container: "mp4,m4v,mov", audioCodec: "aac,mp3,ac3,eac3,alac,flac", videoCodec: "h264,hevc,h265,mpeg4", type: "Video"),
                DirectPlayProfile(container: "mkv", audioCodec: "aac,mp3,ac3,eac3,dts,flac,opus", videoCodec: "h264,hevc,vp9,av1,mpeg4", type: "Video"),
                DirectPlayProfile(container: "avi", audioCodec: "mp3,ac3", videoCodec: "mpeg4,h264", type: "Video"),
                DirectPlayProfile(container: "ts,m2ts", audioCodec: "aac,ac3,eac3,dts,mp3", videoCodec: "h264,hevc,mpeg2", type: "Video"),
                DirectPlayProfile(container: "wmv,asf", audioCodec: "wmav2,wma", videoCodec: "wmv3,wmv2,vc1", type: "Video"),
                DirectPlayProfile(container: "flv", audioCodec: "mp3,aac", videoCodec: "h264,flv", type: "Video"),
                DirectPlayProfile(container: "webm", audioCodec: "opus,vorbis", videoCodec: "vp9,vp8", type: "Video"),
                DirectPlayProfile(container: "iso", type: "Video"),
                DirectPlayProfile(container: "aac,mp3,wav,flac,ogg,oga,m4a,wma,alac", type: "Audio"),
                DirectPlayProfile(container: "jpg,jpeg,png,gif,bmp,tiff,webp,heic", type: "Photo")
            ],
            transcodingProfiles: [
                TranscodingProfile(container: "ts", type: "Video", videoCodec: "h264", audioCodec: "aac", protocol: "hls", estimateContentLength: false, enableMpegtsM2TsMode: true, transcodeSeekInfo: "Auto", copyTimestamps: true, context: "Streaming", maxAudioChannels: "8", minSegments: 1, segmentLength: 0, breakOnNonKeyFrames: true),
                TranscodingProfile(container: "mp4", type: "Video", videoCodec: "h264", audioCodec: "aac", protocol: "http", context: "Static", maxAudioChannels: "8", breakOnNonKeyFrames: false, optimizeForWebStreaming: true),
                TranscodingProfile(container: "mp3", type: "Audio", audioCodec: "mp3", protocol: "http", context: "Streaming", maxAudioChannels: "2"),
                TranscodingProfile(container: "aac", type: "Audio", audioCodec: "aac", protocol: "http", context: "Streaming", maxAudioChannels: "2"),
                TranscodingProfile(container: "wav", type: "Audio", audioCodec: "pcm_s16le", protocol: "http", context: "Streaming", maxAudioChannels: "8")
            ],
            codecProfiles: [
                CodecProfile(type: "Video", codec: "h264", conditions: [
                    ProfileCondition(property: "Width", condition: "LessThanEqual", value: "3840", isRequired: false),
                    ProfileCondition(property: "Height", condition: "LessThanEqual", value: "2160", isRequired: false),
                    ProfileCondition(property: "VideoProfile", condition: "EqualsAny", value: "high|main|baseline|high 10", isRequired: false)
                ]),
                CodecProfile(type: "Video", codec: "hevc,h265", conditions: [
                    ProfileCondition(property: "Width", condition: "LessThanEqual", value: "3840", isRequired: false),
                    ProfileCondition(property: "Height", condition: "LessThanEqual", value: "2160", isRequired: false)
                ]),
                CodecProfile(type: "VideoAudio", codec: "aac", conditions: [
                    ProfileCondition(property: "AudioChannels", condition: "LessThanEqual", value: "8", isRequired: false)
                ]),
                CodecProfile(type: "VideoAudio", codec: "mp3", conditions: [
                    ProfileCondition(property: "AudioChannels", condition: "LessThanEqual", value: "2", isRequired: false)
                ])
            ],
            subtitleProfiles: [
                SubtitleProfile(format: "srt", method: "External"),
                SubtitleProfile(format: "subrip", method: "External"),
                SubtitleProfile(format: "vtt", method: "External"),
                SubtitleProfile(format: "webvtt", method: "External"),
                SubtitleProfile(format: "ass", method: "External"),
                SubtitleProfile(format: "ssa", method: "External"),
                SubtitleProfile(format: "pgs", method: "Embed"),
                SubtitleProfile(format: "dvdsub", method: "Encode"),
                SubtitleProfile(format: "dvbsub", method: "Encode")
            ],
            responseProfiles: [
                ResponseProfile(type: "Video", mimeType: "video/x-matroska", container: "mkv")
            ]
        )
    }
    
    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case maxStreamingBitrate = "MaxStreamingBitrate"
        case maxStaticBitrate = "MaxStaticBitrate"
        case musicStreamingTranscodingBitrate = "MusicStreamingTranscodingBitrate"
        case directPlayProfiles = "DirectPlayProfiles"
        case transcodingProfiles = "TranscodingProfiles"
        case codecProfiles = "CodecProfiles"
        case subtitleProfiles = "SubtitleProfiles"
        case responseProfiles = "ResponseProfiles"
    }
}

public struct DirectPlayProfile: Codable {
    public let container: String?
    public let audioCodec: String?
    public let videoCodec: String?
    public let type: String
    
    public init(container: String? = nil, audioCodec: String? = nil, videoCodec: String? = nil, type: String) {
        self.container = container
        self.audioCodec = audioCodec
        self.videoCodec = videoCodec
        self.type = type
    }
    
    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case audioCodec = "AudioCodec"
        case videoCodec = "VideoCodec"
        case type = "Type"
    }
}

public struct TranscodingProfile: Codable {
    public let container: String
    public let type: String
    public let videoCodec: String?
    public let audioCodec: String
    public let `protocol`: String
    public let estimateContentLength: Bool?
    public let enableMpegtsM2TsMode: Bool?
    public let transcodeSeekInfo: String?
    public let copyTimestamps: Bool?
    public let context: String
    public let maxAudioChannels: String?
    public let minSegments: Int?
    public let segmentLength: Int?
    public let breakOnNonKeyFrames: Bool?
    public let optimizeForWebStreaming: Bool?
    
    public init(container: String, type: String, videoCodec: String? = nil, audioCodec: String, protocol: String, estimateContentLength: Bool? = nil, enableMpegtsM2TsMode: Bool? = nil, transcodeSeekInfo: String? = nil, copyTimestamps: Bool? = nil, context: String, maxAudioChannels: String? = nil, minSegments: Int? = nil, segmentLength: Int? = nil, breakOnNonKeyFrames: Bool? = nil, optimizeForWebStreaming: Bool? = nil) {
        self.container = container
        self.type = type
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.`protocol` = `protocol`
        self.estimateContentLength = estimateContentLength
        self.enableMpegtsM2TsMode = enableMpegtsM2TsMode
        self.transcodeSeekInfo = transcodeSeekInfo
        self.copyTimestamps = copyTimestamps
        self.context = context
        self.maxAudioChannels = maxAudioChannels
        self.minSegments = minSegments
        self.segmentLength = segmentLength
        self.breakOnNonKeyFrames = breakOnNonKeyFrames
        self.optimizeForWebStreaming = optimizeForWebStreaming
    }
    
    enum CodingKeys: String, CodingKey {
        case container = "Container"
        case type = "Type"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case `protocol` = "Protocol"
        case estimateContentLength = "EstimateContentLength"
        case enableMpegtsM2TsMode = "EnableMpegtsM2TsMode"
        case transcodeSeekInfo = "TranscodeSeekInfo"
        case copyTimestamps = "CopyTimestamps"
        case context = "Context"
        case maxAudioChannels = "MaxAudioChannels"
        case minSegments = "MinSegments"
        case segmentLength = "SegmentLength"
        case breakOnNonKeyFrames = "BreakOnNonKeyFrames"
        case optimizeForWebStreaming = "OptimizeForWebStreaming"
    }
}

public struct CodecProfile: Codable {
    public let type: String
    public let codec: String
    public let conditions: [ProfileCondition]
    
    public init(type: String, codec: String, conditions: [ProfileCondition]) {
        self.type = type
        self.codec = codec
        self.conditions = conditions
    }
    
    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case codec = "Codec"
        case conditions = "Conditions"
    }
}

public struct ProfileCondition: Codable {
    public let property: String
    public let condition: String
    public let value: String
    public let isRequired: Bool
    
    public init(property: String, condition: String, value: String, isRequired: Bool) {
        self.property = property
        self.condition = condition
        self.value = value
        self.isRequired = isRequired
    }
    
    enum CodingKeys: String, CodingKey {
        case property = "Property"
        case condition = "Condition"
        case value = "Value"
        case isRequired = "IsRequired"
    }
}

public struct SubtitleProfile: Codable {
    public let format: String
    public let method: String // "External", "Embed", "Encode"
    
    public init(format: String, method: String) {
        self.format = format
        self.method = method
    }
    
    enum CodingKeys: String, CodingKey {
        case format = "Format"
        case method = "Method"
    }
}

public struct ResponseProfile: Codable {
    public let type: String
    public let mimeType: String?
    public let container: String?
    
    public init(type: String, mimeType: String? = nil, container: String? = nil) {
        self.type = type
        self.mimeType = mimeType
        self.container = container
    }
    
    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case mimeType = "MimeType"
        case container = "Container"
    }
}

// MARK: - Query Result

public struct QueryResult<T: Codable>: Codable {
    public let items: [T]
    public let totalRecordCount: Int

    public init(items: [T] = [], totalRecordCount: Int = 0) {
        self.items = items
        self.totalRecordCount = totalRecordCount
    }

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let arr = try? c.decodeIfPresent([T].self, forKey: .items), let arr {
            items = arr
        } else {
            items = []
        }
        totalRecordCount = c.lenientInt(forKey: .totalRecordCount) ?? 0
    }
}

// MARK: - Chapter Info

public struct ChapterInfo: Codable, Identifiable, Equatable {
    public var id: Int { startPositionTicks.hashValue }
    public let startPositionTicks: Int64
    public let name: String?
    public let imageTag: String?
    
    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"
        case name = "Name"
        case imageTag = "ImageTag"
    }
    
    public var startTime: Double {
        Double(startPositionTicks) / 10_000_000.0
    }
}

// MARK: - Media Folder (Library)

public struct MediaFolder: Codable, Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let path: String?
    public let imageTags: ImageTags?
    public let collectionType: String? // "movies", "tvshows", "music", "boxsets", "books", "mixed", "homevideos", "photos", "livetv", "playlists", "folders"
    
    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case imageTags = "ImageTags"
        case collectionType = "CollectionType"
    }
    
    public var collectionName: String {
        guard let type = collectionType?.lowercased() else { return name }
        switch type {
        case "movies": return "电影"
        case "tvshows": return "剧集"
        case "music": return "音乐"
        case "boxsets": return "合集"
        case "books": return "图书"
        case "mixed": return "混合内容"
        case "homevideos": return "家庭视频"
        case "photos": return "照片"
        case "livetv": return "直播电视"
        case "playlists": return "播放列表"
        case "folders": return "文件夹"
        default: return name
        }
    }
    
    public var sfSymbol: String {
        guard let type = collectionType?.lowercased() else { return "folder" }
        switch type {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "boxsets": return "collection"
        case "books": return "book"
        case "mixed": return "square.stack.3d.up"
        case "homevideos": return "video"
        case "photos": return "photo"
        case "livetv": return "tv.badge.wifi"
        case "playlists": return "list.star"
        case "folders": return "folder"
        default: return "folder"
        }
    }
}
