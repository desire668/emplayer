import Foundation

public enum TimeUtils {
    public static func formatSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
    
    public static func formatTicks(_ ticks: Int64) -> String {
        formatSeconds(Double(ticks) / 10_000_000.0)
    }
    
    public static func formatRemaining(current: Double, total: Double) -> String {
        let remaining = max(0, total - current)
        return "-\(formatSeconds(remaining))"
    }
    
    public static func formatDate(_ dateString: String?, style: DateFormatter.Style = .medium) -> String {
        guard let str = dateString, !str.isEmpty else { return "" }
        let fmts = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "zh_CN")
        df.timeZone = TimeZone.current
        for f in fmts {
            df.dateFormat = f
            if let date = df.date(from: str) {
                df.dateStyle = style
                df.timeStyle = .none
                return df.string(from: date)
            }
        }
        return String(str.prefix(10))
    }
    
    public static func formatSize(_ bytes: Int64) -> String {
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        let b = Double(bytes)
        if b >= gb { return String(format: "%.2f GB", b / gb) }
        if b >= mb { return String(format: "%.2f MB", b / mb) }
        if b >= kb { return String(format: "%.1f KB", b / kb) }
        return "\(bytes) B"
    }
    
    public static func formatBitrate(_ bps: Int) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f Mbps", Double(bps) / 1_000_000.0) }
        if bps >= 1000 { return String(format: "%.0f Kbps", Double(bps) / 1000.0) }
        return "\(bps) bps"
    }
}

public enum MediaTypeUtils {
    public static func isVideo(_ item: MediaItem) -> Bool {
        (item.mediaType ?? "").caseInsensitiveCompare("Video") == .orderedSame
            || (item.type ?? "").caseInsensitiveCompare("Video") == .orderedSame
            || (item.type ?? "").caseInsensitiveCompare("Movie") == .orderedSame
            || (item.type ?? "").caseInsensitiveCompare("Episode") == .orderedSame
            || (item.type ?? "").caseInsensitiveCompare("MusicVideo") == .orderedSame
            || (item.type ?? "").caseInsensitiveCompare("Trailer") == .orderedSame
    }
    
    public static func isAudio(_ item: MediaItem) -> Bool {
        (item.mediaType ?? "").caseInsensitiveCompare("Audio") == .orderedSame
            || (item.type ?? "").caseInsensitiveCompare("Audio") == .orderedSame
            || (item.type ?? "").caseInsensitiveCompare("MusicAlbum") == .orderedSame
            || (item.type ?? "").caseInsensitiveCompare("MusicArtist") == .orderedSame
            || (item.type ?? "").caseInsensitiveCompare("AudioBook") == .orderedSame
    }
    
    public static func isPhoto(_ item: MediaItem) -> Bool {
        (item.mediaType ?? "").caseInsensitiveCompare("Photo") == .orderedSame
            || (item.type ?? "").caseInsensitiveCompare("Photo") == .orderedSame
            || (item.type ?? "").caseInsensitiveCompare("PhotoAlbum") == .orderedSame
    }
    
    public static func isCollection(_ item: MediaItem) -> Bool {
        let t = (item.type ?? "").lowercased()
        return t == "folder" || t == "collectionfolder" || t == "boxset"
            || t == "season" || t == "series" || t == "musicalbum"
            || t == "musicartist" || t == "photoalbum"
            || (item.childCount ?? 0) > 0
    }
    
    public static func displayTitle(_ item: MediaItem) -> String {
        let isEpisode = (item.type ?? "").caseInsensitiveCompare("Episode") == .orderedSame
        // 集的 Name 常是未刮削的文件名，优先显示剧名 + 季集号
        if isEpisode, let series = item.seriesName, !series.isEmpty {
            if let s = item.parentIndexNumber, let e = item.indexNumber {
                return String(format: "%@ · S%02d E%02d", series, s, e)
            }
            return series
        }
        if let season = item.parentIndexNumber, let ep = item.indexNumber {
            return String(format: "S%02d E%02d  %@", season, ep, item.name)
        }
        if let ep = item.indexNumber, isEpisode {
            return String(format: "E%02d  %@", ep, item.name)
        }
        return item.name
    }
}

/// Convenience wrapper for `Task.sleep(nanoseconds:)` that accepts seconds as `Double`.
/// Works inside any `Task` / `Task.detached` closure without constrained generics.
@inlinable
public func sleepTask(seconds: Double) async throws {
    let ns = UInt64(seconds * 1_000_000_000.0)
    try await Task.sleep(nanoseconds: ns)
}
