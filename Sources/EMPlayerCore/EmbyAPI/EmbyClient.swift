import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Emby API Error

public enum EmbyAPIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case unauthorized
    case notFound
    case decodingError(Error)
    case networkError(Error)
    case serverError(String)
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "无效的服务器地址"
        case .invalidResponse: return "服务器响应无效"
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        case .unauthorized: return "未授权，请重新登录"
        case .notFound: return "资源未找到"
        case .decodingError(let err): return "数据解析失败: \(err.localizedDescription)"
        case .networkError(let err): return "网络错误: \(err.localizedDescription)"
        case .serverError(let msg): return "服务器错误: \(msg)"
        case .cancelled: return "请求已取消"
        }
    }
}

// MARK: - Emby HTTP Client

public final class EmbyClient {
    public static let shared = EmbyClient()
    
    public private(set) var currentServer: EmbyServer?
    public private(set) var currentUser: EmbyUser?
    public private(set) var accessToken: String?
    
    private let session: URLSession
    private let jsonDecoder: JSONDecoder
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        
        self.jsonDecoder = JSONDecoder()
        self.jsonDecoder.keyDecodingStrategy = .useDefaultKeys
        self.jsonDecoder.dateDecodingStrategy = .iso8601
    }
    
    // MARK: - Setup / Auth
    
    public func setServer(_ server: EmbyServer) {
        self.currentServer = server
        self.accessToken = server.accessToken
        if let uid = server.userId, uid.isEmpty == false {
            self.currentUser = EmbyUser(
                id: uid,
                name: "",
                serverId: nil,
                hasPassword: true,
                hasConfiguredPassword: true,
                isAdministrator: false,
                isDisabled: false,
                policy: nil,
                configuration: nil
            )
        }
    }
    
    public func setAuth(user: EmbyUser, accessToken: String) {
        self.currentUser = user
        self.accessToken = accessToken
        self.currentServer?.accessToken = accessToken
        self.currentServer?.userId = user.id
    }
    
    public func clearAuth() {
        self.currentUser = nil
        self.accessToken = nil
        self.currentServer?.accessToken = nil
        self.currentServer?.userId = nil
    }
    
    // MARK: - Request Builder
    
    public func buildURL(path: String, queryItems: [URLQueryItem]? = nil) -> URL? {
        guard let server = currentServer else { return nil }
        let base = server.baseURL()
        var comps = URLComponents(string: base + path)
        comps?.queryItems = queryItems
        return comps?.url
    }
    
    private func authHeaders() -> [String: String] {
        let appName = "EMPlayer"
        let appVersion = "1.0.0"
        #if canImport(UIKit)
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "emplayer-ios-device"
        let deviceName = UIDevice.current.name
        #else
        let deviceId = "emplayer-device"
        let deviceName = "EMPlayer Device"
        #endif
        
        var headerComponents: [String] = [
            "MediaBrowser Client=\"\(appName)\"",
            "Device=\"\(deviceName)\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(appVersion)\""
        ]
        if let token = accessToken, !token.isEmpty {
            headerComponents.append("Token=\"\(token)\"")
        } else if let key = currentServer?.apiKey, !key.isEmpty {
            headerComponents.append("Token=\"\(key)\"")
        }
        
        return [
            "X-Emby-Authorization": headerComponents.joined(separator: ", "),
            "Accept": "application/json",
            "Content-Type": "application/json; charset=utf-8",
            "User-Agent": "EMPlayer/\(appVersion) iOS"
        ]
    }
    
    // MARK: - Core Request
    
    @discardableResult
    private func request<T: Decodable>(
        method: String,
        path: String,
        queryItems: [URLQueryItem]? = nil,
        body: Encodable? = nil,
        expectBody: Bool = true
    ) async throws -> T {
        guard let url = buildURL(path: path, queryItems: queryItems) else {
            throw EmbyAPIError.invalidURL
        }
        
        var req = URLRequest(url: url)
        req.httpMethod = method
        authHeaders().forEach { req.addValue($1, forHTTPHeaderField: $0) }
        
        if let body = body {
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = []
                req.httpBody = try encoder.encode(body)
            } catch {
                throw EmbyAPIError.decodingError(error)
            }
        }
        
        do {
            let (data, response) = try await session.data(for: req)
            
            guard let http = response as? HTTPURLResponse else {
                throw EmbyAPIError.invalidResponse
            }
            
            switch http.statusCode {
            case 200...299:
                if !expectBody {
                    if let empty = EmptyResponse() as? T { return empty }
                }
                do {
                    return try jsonDecoder.decode(T.self, from: data)
                } catch {
                    // Try to decode error response
                    if let errResp = try? jsonDecoder.decode(EmbyErrorResponse.self, from: data) {
                        throw EmbyAPIError.serverError(errResp.message ?? errResp.message ?? "Unknown Error")
                    }
                    throw EmbyAPIError.decodingError(error)
                }
            case 401:
                throw EmbyAPIError.unauthorized
            case 404:
                throw EmbyAPIError.notFound
            default:
                let msg = String(data: data, encoding: .utf8) ?? ""
                throw EmbyAPIError.httpError(statusCode: http.statusCode, message: msg)
            }
        } catch let err as EmbyAPIError {
            throw err
        } catch {
            if (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled {
                throw EmbyAPIError.cancelled
            }
            throw EmbyAPIError.networkError(error)
        }
    }
    
    private struct EmptyResponse: Codable {}
    private struct EmbyErrorResponse: Codable {
        let message: String?
        let Message: String?
    }
}

// MARK: - Emby Public API (no auth)

extension EmbyClient {
    /// Get public server info without authentication.
    public func getPublicSystemInfo(host: String) async throws -> PublicSystemInfo {
        let savedServer = currentServer
        defer { currentServer = savedServer }
        
        let tempHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        currentServer = EmbyServer(name: "temp", host: tempHost)
        return try await request(method: "GET", path: "/emby/System/Info/Public")
    }
    
    /// Get public users on server (for login screen user picker).
    public func getPublicUsers(host: String) async throws -> [EmbyUser] {
        let savedServer = currentServer
        defer { currentServer = savedServer }
        
        currentServer = EmbyServer(name: "temp", host: host)
        let result: QueryResult<EmbyUser> = try await request(
            method: "GET",
            path: "/emby/Users/Public"
        )
        // Some Emby versions return array directly
        if result.items.isEmpty {
            do {
                guard let url = currentServer?.baseURL().appending("/emby/Users/Public") else {
                    return []
                }
                var req = URLRequest(url: url)
                authHeaders().forEach { req.addValue($1, forHTTPHeaderField: $0) }
                let (data, _) = try await session.data(for: req)
                if let arr = try? jsonDecoder.decode([EmbyUser].self, from: data) {
                    return arr
                }
            } catch {}
        }
        return result.items
    }
    
    /// Authenticate with username / password.
    public func login(server: EmbyServer, username: String, password: String) async throws -> EmbyAuthResult {
        let savedServer = currentServer
        currentServer = server
        defer { currentServer = savedServer }
        
        var body: [String: String] = [
            "Username": username
        ]
        if password.isEmpty == false {
            body["Pw"] = password
        }
        
        let result: EmbyAuthResult = try await request(
            method: "POST",
            path: "/emby/Users/AuthenticateByName",
            body: body
        )
        return result
    }
}

// MARK: - Authenticated API

extension EmbyClient {
    
    // MARK: User
    
    public func getCurrentUser() async throws -> EmbyUser {
        guard let uid = currentUser?.id else { throw EmbyAPIError.unauthorized }
        let user: EmbyUser = try await request(method: "GET", path: "/emby/Users/\(uid)")
        return user
    }
    
    // MARK: Libraries
    
    public func getMediaFolders() async throws -> [MediaFolder] {
        guard let uid = currentUser?.id else { throw EmbyAPIError.unauthorized }
        let result: QueryResult<MediaFolder> = try await request(
            method: "GET",
            path: "/emby/Users/\(uid)/Views"
        )
        return result.items
    }
    
    // MARK: Items
    
    public func getItem(_ itemId: String) async throws -> MediaItem {
        guard let uid = currentUser?.id else { throw EmbyAPIError.unauthorized }
        var qs: [URLQueryItem] = []
        qs.append(URLQueryItem(name: "Fields", value: "MediaSources,MediaStreams,Overview,Tagline,Genres,Studios,ProviderIds,RunTimeTicks,OfficialRating,ProductionYear,PremiereDate,DateCreated,ImageTags,BackdropImageTags,UserData,ChildCount,RecursiveItemCount,Artists,Album,SeriesName,SeasonName,IndexNumber,ParentIndexNumber,SeriesId,SeasonId,VideoType,LocationType"))
        qs.append(URLQueryItem(name: "UserId", value: uid))
        let item: MediaItem = try await request(
            method: "GET",
            path: "/emby/Users/\(uid)/Items/\(itemId)",
            queryItems: qs
        )
        return item
    }
    
    public func getItems(
        parentId: String? = nil,
        mediaTypes: [String]? = nil,
        filters: [String]? = nil,
        sortBy: [String]? = nil,
        sortOrder: String? = "Ascending",
        recursive: Bool = false,
        includeItemTypes: [String]? = nil,
        searchTerm: String? = nil,
        limit: Int? = nil,
        startIndex: Int? = nil,
        isFavorite: Bool? = nil,
        hasPlayed: Bool? = nil
    ) async throws -> QueryResult<MediaItem> {
        guard let uid = currentUser?.id else { throw EmbyAPIError.unauthorized }
        
        var qs: [URLQueryItem] = []
        qs.append(URLQueryItem(name: "UserId", value: uid))
        qs.append(URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"))
        qs.append(URLQueryItem(
            name: "Fields",
            value: "Overview,Tagline,Genres,Studios,ProviderIds,RunTimeTicks,CumulativeRunTimeTicks,OfficialRating,ProductionYear,PremiereDate,DateCreated,ImageTags,BackdropImageTags,UserData,ChildCount,RecursiveItemCount,Artists,Album,SeriesName,SeasonName,IndexNumber,ParentIndexNumber,SeriesId,SeasonId,VideoType,LocationType,MediaSources"
        ))
        if let parentId = parentId { qs.append(URLQueryItem(name: "ParentId", value: parentId)) }
        if let types = mediaTypes, !types.isEmpty { qs.append(URLQueryItem(name: "MediaTypes", value: types.joined(separator: ","))) }
        if let types = includeItemTypes, !types.isEmpty { qs.append(URLQueryItem(name: "IncludeItemTypes", value: types.joined(separator: ","))) }
        if let f = filters, !f.isEmpty { qs.append(URLQueryItem(name: "Filters", value: f.joined(separator: ","))) }
        if let s = sortBy, !s.isEmpty { qs.append(URLQueryItem(name: "SortBy", value: s.joined(separator: ","))) }
        if let o = sortOrder { qs.append(URLQueryItem(name: "SortOrder", value: o)) }
        if let t = searchTerm, !t.isEmpty { qs.append(URLQueryItem(name: "SearchTerm", value: t)) }
        if let l = limit { qs.append(URLQueryItem(name: "Limit", value: String(l))) }
        if let si = startIndex { qs.append(URLQueryItem(name: "StartIndex", value: String(si))) }
        if let fav = isFavorite { qs.append(URLQueryItem(name: "IsFavorite", value: fav ? "true" : "false")) }
        if let played = hasPlayed { qs.append(URLQueryItem(name: "IsPlayed", value: played ? "true" : "false")) }
        
        let result: QueryResult<MediaItem> = try await request(
            method: "GET",
            path: "/emby/Users/\(uid)/Items",
            queryItems: qs
        )
        return result
    }
    
    // MARK: Seasons / Episodes helpers
    
    public func getSeasons(seriesId: String) async throws -> QueryResult<MediaItem> {
        guard let uid = currentUser?.id else { throw EmbyAPIError.unauthorized }
        let result: QueryResult<MediaItem> = try await request(
            method: "GET",
            path: "/emby/Shows/\(seriesId)/Seasons",
            queryItems: [
                URLQueryItem(name: "UserId", value: uid),
                URLQueryItem(name: "Fields", value: "Overview,ImageTags,BackdropImageTags,UserData,IndexNumber,ChildCount,RecursiveItemCount")
            ]
        )
        return result
    }
    
    public func getEpisodes(seriesId: String, seasonId: String? = nil) async throws -> QueryResult<MediaItem> {
        guard let uid = currentUser?.id else { throw EmbyAPIError.unauthorized }
        var qs: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: uid),
            URLQueryItem(name: "Fields", value: "Overview,ImageTags,BackdropImageTags,UserData,IndexNumber,ParentIndexNumber,RunTimeTicks,SeriesName,SeasonName")
        ]
        if let sid = seasonId { qs.append(URLQueryItem(name: "SeasonId", value: sid)) }
        let result: QueryResult<MediaItem> = try await request(
            method: "GET",
            path: "/emby/Shows/\(seriesId)/Episodes",
            queryItems: qs
        )
        return result
    }
    
    public func getNextUp(limit: Int = 50, userId: String? = nil) async throws -> QueryResult<MediaItem> {
        guard let uid = currentUser?.id ?? userId else { throw EmbyAPIError.unauthorized }
        let result: QueryResult<MediaItem> = try await request(
            method: "GET",
            path: "/emby/Shows/NextUp",
            queryItems: [
                URLQueryItem(name: "UserId", value: uid),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "Fields", value: "Overview,ImageTags,BackdropImageTags,UserData,IndexNumber,ParentIndexNumber,RunTimeTicks,SeriesName,SeasonName")
            ]
        )
        return result
    }
    
    public func getResumeItems(limit: Int = 50) async throws -> QueryResult<MediaItem> {
        guard let uid = currentUser?.id else { throw EmbyAPIError.unauthorized }
        let result: QueryResult<MediaItem> = try await request(
            method: "GET",
            path: "/emby/Users/\(uid)/Items/Resume",
            queryItems: [
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "MediaTypes", value: "Video"),
                URLQueryItem(name: "Fields", value: "Overview,ImageTags,BackdropImageTags,UserData,RunTimeTicks,SeriesName,SeasonName,IndexNumber,ParentIndexNumber")
            ]
        )
        return result
    }
    
    // MARK: Playback
    
    public func getPlaybackInfo(
        itemId: String,
        mediaSourceId: String? = nil,
        startTimeTicks: Int64 = 0,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
    ) async throws -> PlaybackInfoResponse {
        guard let uid = currentUser?.id else { throw EmbyAPIError.unauthorized }
        
        let reqBody = PlaybackInfoRequest(
            id: itemId,
            userId: uid,
            startTimeTicks: startTimeTicks,
            audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
            mediaSourceId: mediaSourceId
        )
        
        let result: PlaybackInfoResponse = try await request(
            method: "POST",
            path: "/emby/Items/\(itemId)/PlaybackInfo",
            body: reqBody
        )
        return result
    }
    
    /// Report playback start to Emby
    public func reportPlaybackStart(
        itemId: String,
        mediaSourceId: String,
        playSessionId: String?,
        playbackStartTimeTicks: Int64 = 0,
        isPaused: Bool = false
    ) async throws {
        guard let uid = currentUser?.id else { return }
        let body: [String: AnyCodable] = [
            "UserId": .string(uid),
            "Id": .string(itemId),
            "MediaSourceId": .string(mediaSourceId),
            "PlaySessionId": .string(playSessionId ?? UUID().uuidString),
            "PlayMethod": .string("DirectStream"),
            "StartTimeTicks": .int64(playbackStartTimeTicks),
            "IsPaused": .bool(isPaused)
        ]
        let _: EmptyResponse = try await request(
            method: "POST",
            path: "/emby/Sessions/Playing",
            body: body
        )
    }
    
    /// Report playback progress
    public func reportPlaybackProgress(
        itemId: String,
        mediaSourceId: String,
        playSessionId: String?,
        positionTicks: Int64,
        isPaused: Bool = false,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil
    ) async throws {
        guard let uid = currentUser?.id else { return }
        var body: [String: AnyCodable] = [
            "UserId": .string(uid),
            "Id": .string(itemId),
            "MediaSourceId": .string(mediaSourceId),
            "PlaySessionId": .string(playSessionId ?? UUID().uuidString),
            "PlayMethod": .string("DirectStream"),
            "PositionTicks": .int64(positionTicks),
            "IsPaused": .bool(isPaused),
            "EventName": .string("timeupdate")
        ]
        if let ai = audioStreamIndex { body["AudioStreamIndex"] = .int(ai) }
        if let si = subtitleStreamIndex { body["SubtitleStreamIndex"] = .int(si) }
        let _: EmptyResponse = try await request(
            method: "POST",
            path: "/emby/Sessions/Playing/Progress",
            body: body
        )
    }
    
    /// Report playback stop
    public func reportPlaybackStop(
        itemId: String,
        mediaSourceId: String,
        playSessionId: String?,
        positionTicks: Int64,
        playedToCompletion: Bool = false
    ) async throws {
        guard let uid = currentUser?.id else { return }
        let body: [String: AnyCodable] = [
            "UserId": .string(uid),
            "Id": .string(itemId),
            "MediaSourceId": .string(mediaSourceId),
            "PlaySessionId": .string(playSessionId ?? UUID().uuidString),
            "PositionTicks": .int64(positionTicks),
            "PlayedToCompletion": .bool(playedToCompletion)
        ]
        let _: EmptyResponse = try await request(
            method: "POST",
            path: "/emby/Sessions/Playing/Stopped",
            body: body
        )
    }
    
    public func markWatched(itemId: String) async throws {
        guard let uid = currentUser?.id else { return }
        let _: EmptyResponse = try await request(
            method: "POST",
            path: "/emby/Users/\(uid)/PlayedItems/\(itemId)"
        )
    }
    
    public func markUnwatched(itemId: String) async throws {
        guard let uid = currentUser?.id else { return }
        let _: EmptyResponse = try await request(
            method: "DELETE",
            path: "/emby/Users/\(uid)/PlayedItems/\(itemId)"
        )
    }
    
    public func setFavorite(itemId: String, isFavorite: Bool) async throws {
        guard let uid = currentUser?.id else { return }
        if isFavorite {
            let _: EmptyResponse = try await request(
                method: "POST",
                path: "/emby/Users/\(uid)/FavoriteItems/\(itemId)"
            )
        } else {
            let _: EmptyResponse = try await request(
                method: "DELETE",
                path: "/emby/Users/\(uid)/FavoriteItems/\(itemId)"
            )
        }
    }
    
    // MARK: Chapters
    
    public func getChapters(itemId: String) async throws -> [ChapterInfo] {
        guard let uid = currentUser?.id else { throw EmbyAPIError.unauthorized }
        let result: [ChapterInfo] = try await request(
            method: "GET",
            path: "/emby/Items/\(itemId)/Chapters",
            queryItems: [URLQueryItem(name: "UserId", value: uid)]
        )
        return result
    }
    
    // MARK: - Image URLs
    
    public func imageURL(itemId: String, tag: String?, type: String = "Primary", width: Int? = nil, height: Int? = nil, maxWidth: Int? = nil, fillWidth: Bool = false) -> URL? {
        guard let server = currentServer else { return nil }
        guard let tag = tag, !tag.isEmpty else { return nil }
        let base = server.baseURL()
        var path = "/emby/Items/\(itemId)/Images/\(type)/\(tag)"
        var queryParts: [String] = []
        if let w = width { queryParts.append("Width=\(w)") }
        if let h = height { queryParts.append("Height=\(h)") }
        if let mw = maxWidth { queryParts.append("MaxWidth=\(mw)") }
        if fillWidth { queryParts.append("FillWidth=\(maxWidth ?? 600)") }
        if let token = accessToken, !token.isEmpty {
            queryParts.append("api_key=\(token)")
        } else if let key = server.apiKey, !key.isEmpty {
            queryParts.append("api_key=\(key)")
        }
        let qs = queryParts.isEmpty ? "" : "?" + queryParts.joined(separator: "&")
        return URL(string: base + path + qs)
    }
    
    public func primaryImageURL(for item: MediaItem, maxWidth: Int = 500) -> URL? {
        imageURL(itemId: item.id, tag: item.imageTags?.primary, type: "Primary", maxWidth: maxWidth)
    }
    
    public func thumbImageURL(for item: MediaItem, maxWidth: Int = 800) -> URL? {
        let tag = item.imageTags?.thumb ?? item.imageTags?.primary
        return imageURL(itemId: item.id, tag: tag, type: "Thumb", maxWidth: maxWidth) ?? primaryImageURL(for: item, maxWidth: maxWidth)
    }
    
    public func backdropURL(for item: MediaItem, index: Int = 0, maxWidth: Int = 1920) -> URL? {
        let tags = item.backdropImageTags ?? []
        guard index < tags.count else { return nil }
        let tag = tags[index]
        return imageURL(itemId: item.id, tag: tag, type: "Backdrop", maxWidth: maxWidth)
    }
    
    public func logoImageURL(for item: MediaItem) -> URL? {
        imageURL(itemId: item.id, tag: item.imageTags?.logo, type: "Logo")
    }
    
    public func chapterImageURL(itemId: String, chapterIndex: Int, imageTag: String?, width: Int = 400) -> URL? {
        imageURL(itemId: item.id, tag: imageTag, type: "Chapter", maxWidth: width)
    }
    
    // MARK: - Stream / File URLs
    
    public func directStreamURL(mediaSource: MediaSource, startTimeTicks: Int64 = 0) -> URL? {
        guard let server = currentServer else { return nil }
        let base = server.baseURL()
        var qs: [String] = []
        qs.append("MediaSourceId=\(mediaSource.id)")
        qs.append("Static=true")
        qs.append("api_key=\(accessToken ?? server.apiKey ?? "")")
        if startTimeTicks > 0 {
            qs.append("StartTimeTicks=\(startTimeTicks)")
        }
        let path = "/emby/Videos/\(mediaSource.id)/stream?\(qs.joined(separator: "&"))"
        return URL(string: base + path)
    }
    
    public func hlsTranscodeURL(
        mediaSource: MediaSource,
        playSessionId: String,
        startTimeTicks: Int64 = 0,
        maxBitrate: Int = 20_000_000,
        videoCodec: String = "h264",
        audioCodec: String = "aac",
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        maxAudioChannels: Int = 8
    ) -> URL? {
        guard let server = currentServer else { return nil }
        let base = server.baseURL()
        var qs: [String] = []
        qs.append("MediaSourceId=\(mediaSource.id)")
        qs.append("PlaySessionId=\(playSessionId)")
        qs.append("StartTimeTicks=\(startTimeTicks)")
        qs.append("VideoCodec=\(videoCodec)")
        qs.append("AudioCodec=\(audioCodec)")
        qs.append("MaxBitrate=\(maxBitrate)")
        qs.append("MaxAudioChannels=\(maxAudioChannels)")
        qs.append("api_key=\(accessToken ?? server.apiKey ?? "")")
        if let ai = audioStreamIndex { qs.append("AudioStreamIndex=\(ai)") }
        if let si = subtitleStreamIndex { qs.append("SubtitleStreamIndex=\(si)") }
        let path = "/emby/Videos/\(mediaSource.id)/master.m3u8?\(qs.joined(separator: "&"))"
        return URL(string: base + path)
    }
    
    public func audioStreamURL(mediaSource: MediaSource, container: String = "aac") -> URL? {
        guard let server = currentServer else { return nil }
        let base = server.baseURL()
        let path = "/emby/Audio/\(mediaSource.id)/stream.\(container)?Static=true&api_key=\(accessToken ?? server.apiKey ?? "")"
        return URL(string: base + path)
    }
    
    public func subtitleURL(itemId: String, mediaSourceId: String, subtitleStreamIndex: Int, format: String = "srt") -> URL? {
        guard let server = currentServer else { return nil }
        let base = server.baseURL()
        let path = "/emby/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(subtitleStreamIndex)/0/Stream.\(format)?api_key=\(accessToken ?? server.apiKey ?? "")"
        return URL(string: base + path)
    }
}

// MARK: - AnyCodable helper (for posting mixed JSON)

enum AnyCodable: Encodable {
    case string(String)
    case int(Int)
    case int64(Int64)
    case double(Double)
    case bool(Bool)
    case dictionary([String: AnyCodable])
    case array([AnyCodable])
    case null
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .int64(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .dictionary(let d): try container.encode(d)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}
