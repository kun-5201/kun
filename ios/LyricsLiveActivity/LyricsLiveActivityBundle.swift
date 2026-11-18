// LyricsLiveActivityBundle.swift — Widget Extension entry point.
//
// Target: LyricsLiveActivity (app-extension, XcodeGen — see LiveActivity-edits.md).
// The extension links KumoneCore for LyricsLiveActivityAttributes; it owns no
// playback state. All lyric data arrives in the Activity ContentState pushed
// from the app. The cover is the one thing the extension fetches itself: the
// ContentState carries the cover URL and the extension downloads the
// thumbnail (URLSession + its own memory/disk cache, see IslandCoverCache).
// That replaced the App Group shared container (#52): re-signed builds have
// no App Group entitlement, so the container never opened and the cover was
// always ♪. The extension never touches location.
//
// Visual spec (user screenshot, 07:52; Kugou 05:01 screenshot):
// - Compact pill: LEFT = the pill line, RIGHT = album cover as a small
//   rounded thumbnail (downloaded from the cover URL in ContentState,
//   cached; music-note icon fallback). The pill line depends on the mode
//   (#59): lyric mode = current lyric line in the album-derived color
//   (white fallback when there is no cover), truncated with ellipsis —
//   and scrolling (marquee, right-to-left loop) when too long for the
//   pill, so the whole line is readable; playlist mode = the scrolling
//   hint "长按开启歌词" (the song title lives in the expanded view).
//   No song title / artist / extra controls in the pill. Tapping the
//   pill opens the app to the player (widgetURL, kumone://now-playing).
// - Expanded: leading = cover (CD-disc circle) + title/artist;
//   trailing = refresh link; bottom = lyric mode: 3 lyric lines +
//   progress bar + time + controls (repeat / prev / play-pause / next /
//   heart); playlist mode: upcoming queue + "点击开启歌词" pill button +
//   the same controls. The enable button switches the island to lyric
//   mode (kumone://enable-island-lyrics deep link); it only shows while
//   lyrics are off. Long-press the pill to expand (system gesture).
// - Minimal: same line as the compact pill (lyric line or hint),
//   marquee when too long; tapping opens the player.
// - Lock Screen: lyric mode = 3 lines (previous dimmed / current bold in
//   the album color / next dimmed) + refresh link bottom-left + "K" mark
//   bottom-right; playlist mode = current song + upcoming queue titles.
// Previous/next lines use the same album color at 55% opacity.

#if os(iOS)
import ActivityKit
import KumoneCore
import SwiftUI
import WidgetKit

@main
struct LyricsLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LyricsLiveActivity()
    }
}

struct LyricsLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LyricsLiveActivityAttributes.self) { context in
            // Lock Screen: the lyrics card below the system Now Playing card.
            LockScreenLyricsView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded: title/artist + three lyric lines + progress + controls.
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        // #59: CD-disc circle, like Kugou's expanded cover.
                        IslandCoverThumbnail(size: 44, coverURL: context.state.coverURL)
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(context.state.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    // #59: tapping the island opens kun to the player.
                    .widgetURL(URL(string: "kumone://now-playing")!)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // Refresh: deep-links back into the app, which re-publishes
                    // the current lyric line (see KumoneIOSApp onOpenURL).
                    Link(destination: URL(string: "kumone://lyrics-refresh")!) {
                        Image(systemName: "arrow.clockwise")
                            .font(.title3)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if context.state.isPlaylistMode {
                            // #59 playlist mode: the upcoming queue, then the
                            // "点击开启歌词" pill (Kugou's expanded button).
                            // Tapping it deep-links into the app, which
                            // switches the island mode to lyrics — the pill
                            // then shows the lyric line and this view the
                            // three lyric lines. The button only shows
                            // while lyrics are off; in lyric mode it is gone.
                            VStack(alignment: .leading, spacing: 4) {
                                if let queue = context.state.queueTitles, !queue.isEmpty {
                                    ForEach(Array(queue.enumerated()), id: \.offset) { _, title in
                                        Text(title)
                                            .font(.subheadline)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                    }
                                } else {
                                    Text("队列为空")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .widgetURL(URL(string: "kumone://now-playing")!)
                            Link(destination: URL(string: "kumone://enable-island-lyrics")!) {
                                Text("点击开启歌词")
                                    .font(.headline)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(isLightHex(context.state.lyricColorHex) ? .black : .white)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 10)
                                    .background(Color(hex: context.state.lyricColorHex))
                                    .clipShape(Capsule())
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            // Lyric mode: three lines + progress + time.
                            // Tapping the lyrics opens the player.
                            VStack(alignment: .leading, spacing: 8) {
                                LyricsThreeLinesView(state: context.state)
                                if context.state.duration > 0 {
                                    HStack(spacing: 8) {
                                        Text(mmss(context.state.progress))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                        ProgressView(value: context.state.progress, total: context.state.duration)
                                            .tint(Color(hex: context.state.lyricColorHex))
                                        Text(mmss(context.state.duration))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                            .widgetURL(URL(string: "kumone://now-playing")!)
                        }
                        // Bottom controls, Kugou's row: repeat / previous /
                        // play-pause / next / heart. Each is a deep link
                        // into the app (the app performs the action and
                        // re-publishes the island state, so the icon
                        // updates). The repeat/heart icons reflect the
                        // state carried in ContentState.
                        HStack(spacing: 24) {
                            Spacer()
                            Link(destination: URL(string: "kumone://cycle-repeat")!) {
                                Image(systemName: repeatIconName(mode: context.state.repeatMode))
                                    .font(.title3)
                            }
                            .foregroundStyle(context.state.repeatMode == "off" ? .secondary : .primary)
                            Link(destination: URL(string: "kumone://previous-track")!) {
                                Image(systemName: "backward.fill")
                                    .font(.title3)
                            }
                            Link(destination: URL(string: "kumone://toggle-play")!) {
                                Image(systemName: context.state.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.title3)
                            }
                            Link(destination: URL(string: "kumone://next-track")!) {
                                Image(systemName: "forward.fill")
                                    .font(.title3)
                            }
                            Link(destination: URL(string: "kumone://toggle-like")!) {
                                Image(systemName: context.state.isLiked ? "heart.fill" : "heart")
                                    .font(.title3)
                            }
                            .foregroundStyle(context.state.isLiked ? .red : .primary)
                            Spacer()
                        }
                        // #60 diagnostic: "·60" (compact pill) and "扩展 v60"
                        // prove the new extension is rendering; the session
                        // tag (activity start time "HHmm") proves WHICH
                        // activity — a stale leftover shows an old time, a
                        // live one the current session's start. No tag at
                        // all means the device still runs a pre-#60 extension.
                        // (Remove once the root cause is confirmed.)
                        Text("扩展 v60 · \(context.state.isPlaylistMode ? "歌单" : "歌词") · 歌词\(context.state.currentLine == nil ? "无" : "有") · 封面\(context.state.coverURL == nil ? "无" : "有") · 活动 \(context.state.sessionTag ?? "无")")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                // #60: the pill shows EXACTLY 3 characters of the lyric,
                // complete, SCROLLING (never static). #59's point marquee
                // (GeometryReader + TimelineView 0.05s + .offset) froze
                // mid-scroll on device and showed a 1–2 char slice
                // ("我入怀中）", "9（", no ·59 — 05:46 screenshots).
                // Marquee3Char scrolls by CHARACTER (3-char window, 1
                // char/s, TimelineView 1s), so 3 complete chars are
                // always visible and nothing is cut mid-character. The
                // "·60" marker is a SEPARATE non-scrolling Text, so it
                // is always visible and proves the new extension is
                // rendering; the session tag stays in the expanded
                // diagnostic only. Lyric mode → the real line (title
                // while lyrics load, never a lone ♪, never blank);
                // playlist mode (lyrics off) → the scrolling hint
                // "长按开启歌词". Tapping the pill opens kun to the player.
                HStack(spacing: 4) {
                    Marquee3Char(
                        text: compactLine(state: context.state),
                        color: Color(hex: context.state.lyricColorHex)
                    )
                    Text("·60")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .widgetURL(URL(string: "kumone://now-playing")!)
            } compactTrailing: {
                // #54: synchronous thumbnail only — the async loader broke
                // the whole pill rendering. Cover shows once the expanded
                // view's download has populated the cache; note icon until
                // then, never a blank.
                // #59: tapping the cover opens the player too.
                IslandCoverThumbnailSync(size: 28, coverURL: context.state.coverURL)
                    .widgetURL(URL(string: "kumone://now-playing")!)
            } minimal: {
                // #59: the user wants the lyric in the minimal view too.
                // Minimal holds exactly one element; the lyric wins over
                // the cover (the 04:43 screenshot's right pill was the
                // minimal view showing cover only, no lyric). Same
                // 3-char scrolling window as compactLeading. The "·60"
                // marker is NOT here — minimal holds exactly one
                // element and the lyric is the priority; the marker is
                // proven by compactLeading + the expanded diagnostic.
                // Tapping opens the player.
                Marquee3Char(
                    text: compactLine(state: context.state),
                    color: Color(hex: context.state.lyricColorHex)
                )
                .widgetURL(URL(string: "kumone://now-playing")!)
            }
        }
    }
}

/// In-memory + disk cache for island cover thumbnails, keyed by URL string.
/// The extension has no App Group container on re-signed builds, so it
/// downloads the cover itself (URLSession) and caches it in its own sandbox
/// (memory + the extension's caches directory). A static memory cache + one
/// shared in-flight task per URL mean a song that is already playing never
/// re-downloads on every lyric update, and the compact pill and the expanded
/// view share one download.
enum IslandCoverCache {
    private static let memory = NSCache<NSString, UIImage>()
    private static var inFlight: [String: Task<UIImage?, Never>] = [:]
    private static let lock = NSLock()

    /// Synchronous memory-cache lookup (fast path for view rendering).
    static func memoryImage(for urlString: String?) -> UIImage? {
        guard let urlString else { return nil }
        return memory.object(forKey: urlString as NSString)
    }

    /// Memory + disk lookup; nil when nothing is cached yet.
    static func cachedImage(for urlString: String) -> UIImage? {
        if let image = memory.object(forKey: urlString as NSString) { return image }
        guard let fileURL = diskCacheURL(for: urlString),
              let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else { return nil }
        memory.setObject(image, forKey: urlString as NSString)
        return image
    }

    /// The shared download task for a URL, or the one already running.
    /// Callers await the same task, so two views asking for the same cover
    /// share one network request.
    static func downloadTask(for urlString: String, url: URL) -> Task<UIImage?, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let existing = inFlight[urlString] { return existing }
        let task = Task<UIImage?, Never> {
            defer {
                lock.lock()
                inFlight.removeValue(forKey: urlString)
                lock.unlock()
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else { return nil }
                memory.setObject(image, forKey: urlString as NSString)
                if let fileURL = diskCacheURL(for: urlString) {
                    try? data.write(to: fileURL, options: [.atomic])
                }
                return image
            } catch {
                return nil
            }
        }
        inFlight[urlString] = task
        return task
    }

    private static func diskCacheURL(for urlString: String) -> URL? {
        guard let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("island-cover-\(stableHash(urlString)).jpg")
    }

    /// FNV-1a: deterministic across launches (Swift's hashValue is seeded
    /// per process, so it must not be used for a cache filename).
    private static func stableHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

/// Loads one island cover from its URL (memory + disk cache first, then one
/// shared network download). Publishes the image so the pill re-renders when
/// it arrives; while loading (or with no URL) the view shows the music-note
/// fallback — never a black block.
@MainActor
final class IslandCoverLoader: ObservableObject {
    @Published private(set) var image: UIImage?

    func load(_ urlString: String?) {
        guard let urlString, let url = URL(string: urlString) else {
            image = nil
            return
        }
        if let cached = IslandCoverCache.cachedImage(for: urlString) {
            image = cached
            return
        }
        let task = IslandCoverCache.downloadTask(for: urlString, url: url)
        Task { [weak self] in
            let downloaded = await task.value
            self?.image = downloaded
        }
    }
}

/// Album cover thumbnail, loaded from the cover URL in ContentState.
/// The extension downloads it itself (no App Group container on re-signed
/// builds) and caches it, so a song that is already playing never
/// re-downloads on every lyric update. Falls back to a music-note icon
/// while loading or when the track has no cover.
/// NOTE: used ONLY in the expanded view. The compact pill and minimal
/// view use IslandCoverThumbnailSync below — the async loader here
/// (@StateObject + .task) broke the whole pill rendering (#54).
struct IslandCoverThumbnail: View {
    var size: CGFloat
    var coverURL: String?

    @StateObject private var loader = IslandCoverLoader()

    var body: some View {
        Group {
            // Synchronous memory-cache lookup: when the cover is already
            // cached, the pill shows it on the very first render instead
            // of flashing the note icon until .task runs.
            if let image = loader.image ?? IslandCoverCache.memoryImage(for: coverURL) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // Re-runs only when the URL changes: lyric updates for the same
        // song do not restart the load.
        .task(id: coverURL) { loader.load(coverURL) }
    }
}

/// Synchronous cover thumbnail for the compact pill and minimal view.
/// #54: the async thumbnail above (@StateObject IslandCoverLoader +
/// .task(id:) + URLSession) broke the whole pill rendering — the lock
/// screen, which is pure text with no thumbnail/task/StateObject, renders
/// fine, and #51's pill worked when the cover was read synchronously
/// from the App Group container. Compact/minimal regions render in a
/// constrained WidgetKit context where an async loader can blank the
/// region, so these two spots read the memory/disk cache only and fall
/// back to the note icon when nothing is cached yet. The async download
/// still runs in the expanded view, which populates the cache; the next
/// pill render then shows the cover. No @StateObject, no .task, no
/// network here.
struct IslandCoverThumbnailSync: View {
    var size: CGFloat
    var coverURL: String?

    var body: some View {
        Group {
            if let coverURL, let image = IslandCoverCache.cachedImage(for: coverURL) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // #57: warm the cover cache from the compact pill itself. Before,
        // the only download trigger was the expanded view's async loader,
        // so a user who never expands the island never gets a cover and
        // the pill's trailing is ♪ forever (log-11, screenshot 2). This
        // task only STARTS the shared download — it observes no state and
        // publishes nothing, so it cannot blank the region the way #54's
        // observing loader did. The next pill render (next lyric push,
        // ~5s) then finds the cover in cache and shows it.
        .task(id: coverURL) {
            guard let coverURL,
                  let url = URL(string: coverURL),
                  IslandCoverCache.cachedImage(for: coverURL) == nil else { return }
            _ = IslandCoverCache.downloadTask(for: coverURL, url: url)
        }
    }
}

/// #54 diagnostic: the pill line must never be blank without explanation.
/// Real line → the line; no line → the song title; no title either →
/// an explicit "无歌词". A blank pill therefore proves the extension is
/// not running (system placeholder); any text proves it is.
private func pillLine(state: LyricsLiveActivityAttributes.ContentState) -> String {
    if let line = state.currentLine, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return line
    }
    if !state.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return state.title
    }
    return "无歌词"
}

/// #59: the pill line, by mode. Lyric mode → the lyric line (pillLine:
/// real line, else title, else "无歌词"). Playlist mode (lyrics off) →
/// the hint "长按开启歌词" — the song title lives in the expanded view,
/// and the hint tells the user how to turn lyrics on (long-press the
/// island, tap "点击开启歌词"). Used by compactLeading and minimal.
private func compactLine(state: LyricsLiveActivityAttributes.ContentState) -> String {
    if state.isPlaylistMode {
        return "长按开启歌词"
    }
    return pillLine(state: state)
}

/// #60: scrolling (marquee) lyric for the compact pill / minimal view,
/// showing EXACTLY 3 characters, complete, SCROLLING (never static).
/// #59's MarqueeText scrolled by POINTS (GeometryReader + TimelineView
/// 0.05s + .offset): on device it froze mid-scroll and showed an
/// arbitrary 1–2 char slice ("我入怀中）", "9（", no ·59 — 05:46
/// screenshots). Why, read from the code + the screenshots:
/// - TimelineView 0.05s (20 fps) does not animate in a Live Activity
///   extension — WidgetKit throttles widget re-renders, so the offset
///   froze at a pseudo-random phase from render time; the visible
///   window was a random slice, not the line start (the closing "）"
///   in "我入怀中）" proves it is a mid-line slice, not a line start).
/// - GeometryReader has no intrinsic size; in the content-sized compact
///   regions it can collapse, narrowing the visible window further.
/// - The "·59" marker + session tag sat at the END of the scrolling
///   string, so any nonzero offset pushed them off-screen.
///
/// This version scrolls by CHARACTER, not by point:
/// - The display string is sliced into grapheme clusters; the view
///   shows a window of exactly 3 characters, advancing 1 char per
///   second (TimelineView 1s cadence — the rate Live Activities can
///   actually honor), pausing 1s at the start and 1s at the end, then
///   jumping back to the start. At every moment exactly 3 complete
///   characters are visible; nothing is ever cut mid-character.
/// - No GeometryReader (no width to measure — the window is counted
///   in characters), no .offset, no .clipped: the rendered Text IS
///   exactly 3 characters, so it cannot be pushed off-screen.
/// - A line of ≤3 characters does not scroll (it already fits).
/// - The "·60" marker is a SEPARATE non-scrolling Text next to the
///   marquee (compactLeading), so it is always visible.
/// If TimelineView 1s still does not tick in the compact pill on
/// device, the next round drives the window from app-side pushes
/// (stated honestly: this build cannot prove motion on the VM).
struct Marquee3Char: View {
    var text: String
    var color: Color
    /// Characters visible at once (the user pinned this: 3).
    var windowSize: Int = 3
    /// Seconds per step (1 char). 1s is the cadence Live Activities
    /// can actually honor; 0.05s (#59) was throttled/frozen.
    var stepSeconds: TimeInterval = 1.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: stepSeconds)) { timeline in
            Text(Self.window(
                text: text, at: timeline.date,
                windowSize: windowSize, stepSeconds: stepSeconds))
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    /// The 3-char window visible at a moment. Pure function of time,
    /// so the scroll is continuous across view re-renders.
    static func window(
        text: String, at date: Date,
        windowSize: Int, stepSeconds: TimeInterval
    ) -> String {
        let clean = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let chars = Array(clean)
        guard chars.count > windowSize else { return clean }
        // Windows: 0 ..< (count - windowSize + 1). The cycle adds a 1s
        // pause at the end (repeat the last window) and a 1s pause at
        // the start (repeat the first window across the cycle boundary),
        // then jumps back to the start.
        let windows = chars.count - windowSize + 1
        let cycle = windows + 2
        let step = Int(date.timeIntervalSinceReferenceDate / stepSeconds) % cycle
        let start: Int
        if step < windows {
            start = step
        } else if step == windows {
            start = windows - 1 // end pause
        } else {
            start = 0 // start pause (also shown at step 0 of next cycle)
        }
        return String(chars[start..<(start + windowSize)])
    }
}

/// "m:ss" for the expanded view's progress row (Kugou shows the time
/// next to the progress bar).
private func mmss(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    return "\(total / 60):\(String(format: "%02d", total % 60))"
}

/// Whether a "#RRGGBB" color is light (relative luminance > 0.5). Used
/// for the "点击开启歌词" pill: the capsule is the album color, and the
/// text is black on a light album color, white on a dark one.
private func isLightHex(_ hex: String) -> Bool {
    let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "#", with: "")
    var value: UInt64 = 0
    guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else { return false }
    let r = Double((value >> 16) & 0xFF) / 255
    let g = Double((value >> 8) & 0xFF) / 255
    let b = Double(value & 0xFF) / 255
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5
}

/// Repeat icon for the expanded view's repeat control, from the
/// ContentState repeatMode raw value ("off"/"all"/"one").
private func repeatIconName(mode: String) -> String {
    switch mode {
    case "one": return "repeat.1"
    case "all": return "repeat"
    default: return "repeat"
    }
}

/// Three lyric lines: previous (dimmed album color), current (bold album
/// color), next (dimmed album color). Used by the Lock Screen view and the
/// expanded island bottom region.
struct LyricsThreeLinesView: View {
    var state: LyricsLiveActivityAttributes.ContentState

    var body: some View {
        let lyricColor = Color(hex: state.lyricColorHex)
        VStack(alignment: .leading, spacing: 6) {
            if let previous = state.previousLine {
                Text(previous)
                    .font(.subheadline)
                    .foregroundStyle(lyricColor.opacity(0.55))
                    .lineLimit(1)
            }
            // No singable line (no lyrics, or only markers): show the song
            // title, never a lone ♪ — that was the #47 bug.
            Text(state.currentLine ?? state.title)
                .font(.headline)
                .fontWeight(.bold)
                .foregroundStyle(lyricColor)
                .lineLimit(1)
            if let next = state.nextLine {
                Text(next)
                    .font(.subheadline)
                    .foregroundStyle(lyricColor.opacity(0.55))
                    .lineLimit(1)
            }
        }
    }
}

/// Lock Screen lyrics card: lyric mode = 3 lines + bottom row (refresh
/// left, K mark right), matching the screenshot the user sent. Playlist
/// mode = current song + upcoming queue titles (the refresh link and K
/// mark stay — the refresh deep link re-publishes the island state in
/// either mode, so a stuck island recovers with one tap).
struct LockScreenLyricsView: View {
    var context: ActivityViewContext<LyricsLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(context.state.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Spacer()
                Text(context.state.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if context.state.isPlaylistMode {
                if let queue = context.state.queueTitles, !queue.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(queue.enumerated()), id: \.offset) { _, title in
                            Text(title)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text("队列为空")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                LyricsThreeLinesView(state: context.state)
            }
            HStack {
                // Refresh: re-requests / re-publishes the current lyric line so
                // a stuck island can be refreshed without restarting playback.
                // Falls back to the in-app button in Settings > 歌词 if Link
                // does not fire in this context.
                Link(destination: URL(string: "kumone://lyrics-refresh")!) {
                    Image(systemName: "arrow.clockwise")
                        .font(.callout)
                }
                Spacer()
                Text("K")
                    .font(.headline)
                    .fontWeight(.bold)
            }
            .foregroundStyle(.secondary)
        }
        .padding()
    }
}

extension Color {
    /// "#RRGGBB" (as stored in ContentState.lyricColorHex) → Color.
    /// Anything unparseable becomes white, the documented fallback.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&value) else {
            self = .white
            return
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
#endif
