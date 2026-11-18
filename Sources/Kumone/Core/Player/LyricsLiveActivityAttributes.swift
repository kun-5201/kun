// LyricsLiveActivityAttributes.swift — True Live Activity (Dynamic Island / Lock Screen) attributes.
//
// Ported pattern: standard ActivityKit (iOS 16.1+). No Moumusic/kun prior art —
// neither project ships a Live Activity; the system Now Playing lyrics on
// dynamic-island-lyrics (NowPlayingManager.updateCurrentLyric) stays as fallback.
//
// This file lives in KumoneCore and MUST be public: the LyricsLiveActivity widget
// extension links KumoneCore and requests/updates activities with this exact type.
// Everything dynamic goes in ContentState (updatable); there are no static
// attributes — the activity is scoped to a playback session, not a track
// (#53): a track change only updates the ContentState (title / lines /
// color / cover URL / progress) via activity.update, which works from the
// background. Restarting the activity per track required Activity.request,
// which throws "Target is not foreground" in the background and killed the
// island on every background track change. Keep every update well under
// Apple's 4 KB payload limit: three short lyric lines + title/artist +
// numbers + one cover URL string (~100-200 chars — the extension downloads
// the thumbnail itself).

#if os(iOS)
import ActivityKit
import Foundation

/// Lyrics Live Activity: the Dynamic Island / Lock Screen companion to the
/// system Now Playing lyric (which writes the current line into the Now Playing
/// artist field). When this activity runs, the island shows its compact view;
/// the Lock Screen shows the three-line lyrics card below the Now Playing card.
public struct LyricsLiveActivityAttributes: ActivityAttributes {
    /// Lyric color when there is no cover or color extraction fails: white.
    public static let fallbackLyricColorHex = "#FFFFFF"

    public struct ContentState: Codable, Hashable {
        public var title: String
        public var artist: String
        /// Line before the current one; nil at the start of the song.
        public var previousLine: String?
        /// Current line; nil before the first timed line (then the first line is used).
        public var currentLine: String?
        /// Line after the current one; nil at the last line.
        public var nextLine: String?
        public var isPlaying: Bool
        public var progress: TimeInterval
        public var duration: TimeInterval
        /// Album-derived lyric color as "#RRGGBB" (white fallback when there
        /// is no cover or extraction fails). Drives the current line in the
        /// compact pill, the expanded view and the lock-screen 3-line view.
        public var lyricColorHex: String
        /// Album cover URL (string, e.g. a 200px CDN URL). The widget
        /// extension downloads the thumbnail itself (URLSession + its own
        /// cache) and shows it in the compact pill / expanded view. This
        /// replaced the App Group shared container (#52): re-signed builds
        /// have no App Group entitlement, so the container never opens and
        /// the cover was always ♪. Nil when the track has no cover; the
        /// extension falls back to a music-note icon.
        public var coverURL: String?
        /// Whether a cover is available for this track (coverURL != nil).
        /// Kept so readers of the state can tell at a glance; the extension
        /// loads from coverURL directly.
        public var hasCover: Bool
        /// #57: which activity this state belongs to — the activity's start
        /// time as "HHmm" (e.g. "1427"). The compact pill shows it next to
        /// the lyric, so one screenshot tells a live activity from a stale
        /// one (a leftover from a killed session shows an old time) and a
        /// #57 extension from an old one (no tag at all). Optional so an
        /// old extension decoding a new state (or a new extension decoding
        /// an old state) still works — the key is simply absent / nil.
        public var sessionTag: String?
        /// #59: playlist mode (Kugou's 歌单). When true the island shows
        /// the play queue instead of lyric lines: compact/minimal show the
        /// current song title, expanded/lock show the upcoming queue
        /// (queueTitles). False = lyric mode (the default). Optional keys
        /// keep old states decodable.
        public var isPlaylistMode: Bool
        /// Upcoming track titles for playlist mode (max 5, in play order).
        /// Nil in lyric mode. The extension renders these in the expanded
        /// view and on the lock screen; the compact pill still shows only
        /// the current song title + cover.
        public var queueTitles: [String]?
        /// #59: repeat mode for the expanded view's repeat control
        /// (Kugou's bottom row: repeat / prev / play-pause / next / heart).
        /// Raw value of PlayerService RepeatMode ("off"/"all"/"one"); the
        /// extension maps it to the repeat icon (dimmed when off, repeat.1
        /// when one). "off" default keeps old states decodable.
        public var repeatMode: String
        /// #59: whether the current track is in the user's liked songs.
        /// Drives the expanded view's heart icon (filled when liked).
        public var isLiked: Bool

        public init(
            title: String,
            artist: String,
            previousLine: String? = nil,
            currentLine: String? = nil,
            nextLine: String? = nil,
            isPlaying: Bool,
            progress: TimeInterval,
            duration: TimeInterval,
            lyricColorHex: String = "#FFFFFF",
            coverURL: String? = nil,
            hasCover: Bool = false,
            sessionTag: String? = nil,
            isPlaylistMode: Bool = false,
            queueTitles: [String]? = nil,
            repeatMode: String = "off",
            isLiked: Bool = false
        ) {
            self.title = title
            self.artist = artist
            self.previousLine = previousLine
            self.currentLine = currentLine
            self.nextLine = nextLine
            self.isPlaying = isPlaying
            self.progress = progress
            self.duration = duration
            self.lyricColorHex = lyricColorHex
            self.coverURL = coverURL
            self.hasCover = hasCover
            self.sessionTag = sessionTag
            self.isPlaylistMode = isPlaylistMode
            self.queueTitles = queueTitles
            self.repeatMode = repeatMode
            self.isLiked = isLiked
        }
    }

    /// No static attributes: the activity belongs to a playback session,
    /// not to one track. The manager tracks the current track id itself
    /// (see LyricsLiveActivityManager.currentTrackID) and pushes track
    /// changes as ContentState updates.
    public init() {}
}
#endif
