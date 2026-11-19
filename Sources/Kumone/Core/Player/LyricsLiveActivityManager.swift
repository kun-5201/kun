// LyricsLiveActivityManager.swift — App-side owner of the lyrics Live Activity.
//
// Rules enforced here (user requirements):
//  1. App closed => island closes: the activity is ended with dismissalPolicy
//     .immediate on every path we control — playback pause/stop/track-end,
//     mode off, app termination (applicationWillTerminate) and entering
//     background while not playing. A staleDate is set on every update so an
//     app that dies without running termination code still goes stale quickly.
//     LIMIT (Apple platform behaviour, not a bug in this file): if iOS kills a
//     suspended app (jetsam) or the user force-quits it, applicationWillTerminate
//     does not run and no app code can end the activity. With dismissalPolicy
//     .immediate the system removes a stale activity promptly, so a
//     force-quit island is gone within ~8s of the last push (staleDate 8s,
//     #59 — Kugou's window is ~10s; kun is no slower), typically 2–6s.
//     The 8-hour lifetime is only the hard cap; the stale date is what
//     removes it in practice. See LiveActivity-edits.md §7.
//  2. The activity only ever starts when the user chose an island mode
//     (lyrics or playlist; default off) AND Live Activities are authorized.
//     It never starts silently. The mode gates the island: off = no
//     activity at all; lyrics = lyric island; playlist = queue island (the
//     pill shows the scrolling "长按开启歌词" hint until the user switches
//     to lyrics, from Settings or the expanded island's enable button).
//     Kugou gates the same way: a mode must be chosen first, no mode = no
//     island lyrics.
//  3. Lyric updates are event-driven and debounced Kugou-style: only a
//     lyric line change, a track change, or no activity yet triggers a push,
//     and the push is debounced 0.2s (each trigger cancels the pending push
//     and schedules a fresh one). Progress ticks that leave the lines
//     unchanged trigger nothing — pushing on every tick (~2x/sec) burns
//     Apple's Live Activity update budget and the island goes stale with
//     no lyric. See scheduleDebouncedPush.
//  4. A heartbeat re-pushes the current state every 6s while playing,
//     but only after 6s with no line-change push (every real push resets
//     the timer). The stale date is 8s (#59: was 10s, heartbeat 8s — the
//     same 2s margin, but a force-quit island now disappears within ~8s
//     instead of ~10s; Kugou's window is ~10s, kun is no slower), so
//     without it a line lasting longer than 8s — or one dropped update —
//     leaves the island frozen on an old line (#48: the pill still showed
//     the 03:09:43 line at 03:11:18). The heartbeat also heals a stale
//     manager reference: if the system already ended the activity, the
//     next push would silently no-op on the dead object; the heartbeat
//     detects that and restarts the activity. See scheduleHeartbeat /
//     liveActivity.
//  5. A failed FIRST start must recover, not strand the island (#51):
//     log-4 showed one "Target is not foreground" failure, then 44s with
//     no island, because the only retry was the next lyric tick's
//     debounced push (sparse — the 0.2s tick churn cancels most pushes
//     before they fire) and the heartbeat had been stopped by endActivity.
//     A failed or deferred start is now logged every time with the
//     foreground state, and a 2s retry loop re-attempts it while the song
//     plays; returning to the foreground rebuilds it at once. A background
//     start is deferred, never attempted (Activity.request requires
//     foreground). This is only the first-start safety net now — see
//     rule 7: track changes no longer start anything.
//  6. A user-dismissed island stays dismissed for the track and stops
//     all push work (#51): lyricDidChange no longer schedules pushes
//     once dismissed, and the push log is written only when a real
//     update or start is attempted, so dropped pushes leave no trace.
//     Before, the gate passed on every tick while activity was nil and
//     log-4 shows 25 dropped pushes in 16s after a dismiss.
//  7. One activity per playback session, NOT one per track (#53): a track
//     change only updates the running activity's ContentState in place
//     (title / lines / color / cover URL / progress — and, since #59,
//     mode / queue / repeat / like), via activity.update,
//     which is allowed from the background. The old per-track restart
//     (endActivity + Activity.request on every track change) killed the
//     island whenever a song advanced while backgrounded: the request
//     throws "Target is not foreground" (log-7), the start deferred to
//     pendingStartState, and the island stayed dead until the user
//     foregrounded the app. Attributes carry no track id any more; the
//     manager tracks the current track id itself (currentTrackID) to
//     detect switches and reset cover/color/lyrics. The activity ends
//     only on pause/stop, user dismiss, a 30s unrecovered stall, or app
//     shutdown while not playing.

#if os(iOS)
import ActivityKit
import Combine
import CoreLocation
import Foundation
import UIKit

/// Result of the first-time authorization check for 歌词上岛.
/// Only the Live Activities switch itself gates the toggle: "更频繁更新"
/// (frequent pushes) only affects how often the island may refresh, so it
/// warns instead of blocking — blocking on it left users with the toggle on
/// but no island at all when the system switch was off, with no feedback.
enum LyricsIslandAuthorization: Equatable {
    /// Live Activities enabled. The activity may start; frequent updates
    /// may still be off (see frequentUpdatesEnabled), in which case
    /// updates are throttled but lyrics still show.
    case granted
    /// Live Activities disabled: the caller must show an alert with a
    /// "去设置" button that opens the system Settings.
    case needsSettings(reason: String)
}

/// App-side owner of the lyrics Live Activity. iOS only; macOS has no island.
@MainActor
public final class LyricsLiveActivityManager: ObservableObject {
    public static let shared = LyricsLiveActivityManager()

    private var activity: Activity<LyricsLiveActivityAttributes>?
    private var lastState: LyricsLiveActivityAttributes.ContentState?
    private var cancellables = Set<AnyCancellable>()
    private let locationKeepAlive = LyricsLocationKeepAlive()
    /// Album-derived lyric color for the current track ("#RRGGBB"); white
    /// until the new cover loads or when there is no cover. Recomputed on
    /// every track change together with the cover (see updateArtwork).
    private var currentLyricColorHex: String = LyricsIslandCover.fallbackLyricColorHex
    /// Cover URL string for the current track (200px CDN URL, see
    /// LyricsIslandCover.islandCoverSize). The extension downloads the
    /// thumbnail itself from this URL — no App Group container (#52).
    /// Nil when the track has no cover; the island falls back to ♪.
    private var currentCoverURL: String?
    /// Whether the current track has a cover (currentCoverURL != nil).
    private var currentHasCover = false
    /// Whether "封面已就绪" was already logged for the current track, so a
    /// repeated artwork callback for the same track does not re-log.
    private var coverReadyLogged = false
    /// Last lyric lines pushed to the island. Updates are Kugou-style
    /// debounced (see scheduleDebouncedPush): a push only happens when the
    /// line changes (or the track changes); pushing on every progress tick
    /// (~2x/sec) burns Apple's Live Activity update budget, after which the
    /// system drops updates and the island goes stale with no lyric — that
    /// is why #41/#42 showed no lyrics. Progress ticks that leave the lines
    /// unchanged trigger nothing at all.
    private var lastPublishedLines: (previous: String?, current: String?, next: String?)?
    /// Kugou's debounce delay (delayUpdatePlayInfo: performSelector:
    /// updatePlayInfo afterDelay: 0.2, after cancelling any pending one).
    /// Every trigger cancels the pending push and schedules a fresh one
    /// 0.2s out, so a burst of line changes collapses into a single
    /// Activity update.
    private static let pushDebounceDelay: TimeInterval = 0.2
    /// The pending debounced push, if any. Cancelled by a newer trigger
    /// (scheduleDebouncedPush) and by endActivity, so a stop/pause inside
    /// the 0.2s window never starts an island.
    private var pendingPushTask: Task<Void, Never>?
    /// Heartbeat (see rule 4 in the file header): re-pushes the current
    /// state every 6s of quiet while playing, so the island never reaches
    /// its 8s stale date (#59: was 8s/10s — same 2s margin, faster
    /// force-kill removal). A line-change push resets the timer, so during
    /// normal playback the heartbeat almost never fires — it only covers
    /// long lines, gaps and dropped updates, at ~10 pushes/min worst case,
    /// far below the ~2x/sec that exhausted the budget in #42.
    private static let heartbeatInterval: TimeInterval = 6
    private var heartbeatTask: Task<Void, Never>?
    /// Last heartbeat re-push, for the diagnostic log: routine heartbeats
    /// are logged at most once a minute so they don't flood the journal.
    private var lastHeartbeatLogAt: Date?
    /// Last throttled "player tick stalled" log (same 60s window as the
    /// heartbeat log — without it a persisting stall would log every 8s).
    private var lastTickStallLogAt: Date?
    /// The user dismissed the island by hand: never auto-restart it for
    /// the same track. Cleared on the next track change.
    private var islandDismissedByUser = false
    /// Background-task assertion held while an activity end is in flight,
    /// so a pause issued from the Lock Screen / Control Center while the
    /// app is backgrounded still completes the dismissal instead of the
    /// Task being frozen by suspension and the island lingering on the
    /// last line.
    private var endBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// Audio stall watch (#50): the player can sit in
    /// .waitingToPlayAtSpecifiedRate forever on a dead LX stream without
    /// ever failing the item — isPlaying stays true, the 0.2s time
    /// observer stops firing (player time frozen), no code runs, and the
    /// island goes stale black. When a stall is reported, a first timer
    /// buys a background-task grace window for the heartbeat; a second
    /// timer ends the activity cleanly if the stall outlasts it, so the
    /// island disappears instead of sitting black — and restarts on the
    /// next lyric change when audio recovers.
    private var stallTask: Task<Void, Never>?
    private var stallEndTask: Task<Void, Never>?
    private var stallBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var stallBeganAt: Date?
    /// Last time the app entered the background, for the foreground log
    /// ("App 回到前台，距进入后台 X 秒") — the gap is the suspension
    /// window, and it is the only retroactive proof the app was frozen.
    private var backgroundedAt: Date?

    private init() {
        // Playback stopping anywhere (pause button, queue end, track cleared)
        // ends the island immediately — the player does not need to remember
        // to call us from every stop path.
        PlayerService.shared.$isPlaying
            .dropFirst()
            .sink { [weak self] playing in
                guard let self else { return }
                if !playing { self.endActivity() }
            }
            .store(in: &cancellables)
        PlayerService.shared.$currentTrack
            .dropFirst()
            .sink { [weak self] track in
                guard let self else { return }
                // A new track does NOT retire the activity (#53): the
                // session-scoped activity keeps running and the next lyric
                // tick updates it in place with the new song's state.
                // Ending + re-requesting here killed the island on every
                // background track change (Activity.request requires
                // foreground). Only the per-track visuals reset.
                if let track {
                    // #51: one line per switch (old -> new, with IDs) so the
                    // next log shows whether the churn is the user tapping
                    // fast or the player re-setting the same track: a
                    // re-set carries the same ID, a real switch a new one.
                    // startPlaying assigns currentTrack unconditionally, so
                    // re-tapping the same song also lands here.
                    if let old = self.lastSeenTrack, old.id == track.id {
                        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                            message: "同一首歌重新开始",
                            detail: "\(track.name) (id \(track.id))，播放中=\(PlayerService.shared.isPlaying)")
                    } else {
                        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                            message: "切歌",
                            detail: "\(self.lastSeenTrack.map { "\($0.name) (id \($0.id))" } ?? "无") → \(track.name) (id \(track.id))，播放中=\(PlayerService.shared.isPlaying)")
                    }
                    self.lastSeenTrack = (track.id, track.name)
                    self.currentTrackID = track.id
                    // A new song may start a fresh island even if the user
                    // dismissed the previous one.
                    self.islandDismissedByUser = false
                    self.resetArtworkForNewTrack()
                } else {
                    self.lastSeenTrack = nil
                    self.currentTrackID = nil
                    self.endActivity()
                }
            }
            .store(in: &cancellables)
        // #59: island mode changes (Settings picker, or the expanded
        // island's "点击开启歌词" deep link) re-drive the island. Off
        // ends it at once; lyrics/playlist rebuilds the state with the
        // new mode — refreshLyricsIsland recomputes lines + queue and
        // pushes, while refreshActivity alone would re-send lastState
        // with the OLD mode. The gate (rule 2) is never bypassed: a
        // change to .off ends, never starts.
        SettingsManager.shared.$islandMode
            .dropFirst()
            .sink { [weak self] mode in
                guard let self else { return }
                if mode == .off {
                    DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                        message: "灵动岛模式已关闭", detail: nil)
                    self.endActivity()
                } else {
                    DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                        message: "灵动岛模式已切换", detail: mode.displayName)
                    PlayerService.shared.refreshLyricsIsland()
                }
            }
            .store(in: &cancellables)
        // #59: in playlist mode the island shows the play queue, so a
        // queue change (add/remove/reorder) must republish even when the
        // lyric lines and the track are unchanged — lyricDidChange's push
        // guard now includes a queue change (see queueChanged). In lyric
        // mode the queue is not shown, so queue churn pushes nothing.
        PlayerService.shared.$queue
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                guard SettingsManager.shared.islandMode == .playlist else { return }
                PlayerService.shared.refreshLyricsIsland()
            }
            .store(in: &cancellables)
    }

    // MARK: - Toggle + authorization

    /// First-time enable flow. Checks ActivityAuthorizationInfo before anything
    /// starts; never starts the activity while Live Activities are disabled.
    /// "更频繁更新" is NOT required here: it only throttles refreshes, and
    /// gating on it meant the island silently never started whenever the
    /// system switch was off (the reference v22 build shows lyrics with
    /// Live Activities on alone). The toggle flow warns about it instead.
    func authorizationStatus() -> LyricsIslandAuthorization {
        let info = ActivityAuthorizationInfo()
        guard info.areActivitiesEnabled else {
            return .needsSettings(reason: "当前未开启实时活动，灵动岛歌词无法显示。请在系统设置中为 Kumone 开启「实时活动」。")
        }
        return .granted
    }

    /// Whether "更频繁更新" is on (iOS 17.2+). Off means the system may
    /// throttle lyric refreshes (the island can lag or stall), but lyrics
    /// still show. Below iOS 17.2 there is no such switch, so this is true.
    var frequentUpdatesEnabled: Bool {
        if #available(iOS 17.2, *) {
            return ActivityAuthorizationInfo().frequentPushesEnabled
        }
        return true
    }

    /// Whether a lyrics Live Activity is currently running. Exposed for the
    /// Settings diagnostics row so one glance separates "toggle off" /
    /// "system refused" / "activity never started" — the three states a
    /// black island can be in — instead of guessing from the toggle alone.
    var isActivityRunning: Bool { activity != nil }

    /// The most recent island entry in the diagnostic journal
    /// ("启动实时活动被系统拒绝" / "启动实时活动失败"), if any. It is the
    /// one line that tells whether a toggle-on + black-island case is a
    /// system refusal or something else. Nil when nothing was recorded.
    /// Entries persist across launches, so this is the latest record, not
    /// necessarily this launch.
    var lastIslandFailure: String? {
        DiagnosticLogStore.shared.entries
            .first { $0.category == "灵动岛" }
            .map { entry in
                if let detail = entry.detail, !detail.isEmpty {
                    return "\(entry.message)：\(detail)"
                }
                return entry.message
            }
    }

    /// Opens the system Settings app at this app's page.
    func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Forwards the location toggle: asks for WhenInUse authorization only
    /// when the user enables the keep-alive switch. Never requests Always.
    func requestLocationAuthorizationIfNeeded() {
        locationKeepAlive.requestAuthorizationIfNeeded()
    }

    // MARK: - Album color + cover (visual spec)

    /// Called when the current track's artwork loads (NowPlayingManager).
    /// Derives the lyric color from the cover. The cover itself is NOT
    /// written anywhere here: the ContentState already carries the cover
    /// URL (set on track change, see resetArtworkForNewTrack) and the
    /// extension downloads the thumbnail itself — the App Group container
    /// path is gone (#52, re-signed builds have no App Group entitlement).
    /// If an activity is already running, the new color is pushed at once
    /// together with the current lyric state.
    func updateArtwork(_ image: UIImage?) {
        guard SettingsManager.shared.lyricsOnIsland else { return }
        guard let image else {
            // The app's own artwork download failed; the color falls back
            // to white, but the cover URL (if any) stays valid — the
            // extension loads from the URL independently, so it may still
            // show the cover. NowPlayingManager already logs the download
            // failure; nothing more to say here.
            currentLyricColorHex = LyricsIslandCover.fallbackLyricColorHex
            return
        }
        currentLyricColorHex = LyricsIslandCover.dominantLyricColorHex(from: image)
        currentHasCover = currentCoverURL != nil
        // One line per track: the first artwork callback after the
        // per-track reset. A repeated callback for the same track does
        // not re-log.
        if currentHasCover, !coverReadyLogged {
            coverReadyLogged = true
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "封面已就绪",
                detail: "\(PlayerService.shared.currentTrack?.name ?? "")，颜色 \(currentLyricColorHex)")
        }
        guard var state = lastState, activity != nil else { return }
        state.lyricColorHex = currentLyricColorHex
        state.coverURL = currentCoverURL
        state.hasCover = currentHasCover
        guard state != lastState else { return }
        lastState = state
        Task { [activity] in await activity?.update(ActivityContent(state: state, staleDate: Self.staleDate())) }
    }

    /// A new track starts with the fallback color and its own cover URL
    /// (or none), so the previous album's color/cover never leaks into
    /// the new song's island. The URL is set here — not when the artwork
    /// image finishes downloading — so the island carries it from the
    /// first lyric push and the extension can start loading at once.
    private func resetArtworkForNewTrack() {
        currentLyricColorHex = LyricsIslandCover.fallbackLyricColorHex
        coverReadyLogged = false
        currentCoverURL = PlayerService.shared.currentTrack?.album.picUrl?
            .resizedImageURL(LyricsIslandCover.islandCoverSize)?.absoluteString
        currentHasCover = currentCoverURL != nil
        if currentCoverURL == nil {
            // A track with no cover URL: say so instead of going silent —
            // otherwise the ♪ fallback looks like a bug with no cause.
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "岛封面：本首歌无封面链接",
                detail: PlayerService.shared.currentTrack?.name)
        }
        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
            message: "新歌：封面已重置",
            detail: PlayerService.shared.currentTrack?.name)
    }

    // MARK: - Lyric updates (called only when the line changes)

    /// Whether a lyric line may reach the island: non-blank and not a
    /// marker (ParsedLyrics.isMarkerLine). The cursor in PlayerServiceIOS
    /// already skips markers, but this is the last check at the push
    /// boundary — a line from any path that bypassed the cursor (stale
    /// state, a re-publish, a future caller) must still never show as a
    /// bare ♪ in the pill.
    private static func isPresentableLyricLine(_ line: String?) -> Bool {
        guard let line, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !ParsedLyrics.isMarkerLine(line)
    }

    /// #59: upcoming track titles for playlist mode (max 5, in play order),
    /// from the queue after the current track. Empty when the queue ends at
    /// the current song. The extension renders these in the expanded view
    /// and on the lock screen; the compact pill shows the "长按开启歌词"
    /// hint instead — the title lives in the expanded view.
    private func upcomingQueueTitles() -> [String] {
        let queue = PlayerService.shared.activeQueue
        let idx = PlayerService.shared.currentIndex
        guard !queue.isEmpty, idx >= 0, idx + 1 < queue.count else { return [] }
        return Array(queue[(idx + 1)...].prefix(5)).map { $0.name }
    }

    /// Called from PlayerServiceIOS.updateLyricsCursor after it computes the
    /// new active line. Reads title/artist/progress from the player; the three
    /// lines come from ParsedLyrics around activeIndex.
    func lyricDidChange(previous: String?, current: String?, next: String?) {
        // #58: a blocked start must leave a trace. Before, this guard
        // returned silently, so a black island with the toggle off (the
        // default after every reinstall — log-12's 2h blackout: 42 track
        // changes, 18 lyrics fetched, zero starts, zero pushes, zero
        // defers, zero failures) left the journal completely empty.
        // #59: the gate is the island mode now (off/lyrics/playlist),
        // not a boolean toggle — same rule, new wording.
        guard SettingsManager.shared.lyricsOnIsland else {
            logBlockedStart(reason: "灵动岛模式未开启", detail: "去「设置 > 歌词」选择灵动岛模式（歌词/歌单）", throttleSeconds: 300)
            return
        }
        guard let track = PlayerService.shared.currentTrack else { return }
        // #56 last-resort guard: never let a bare marker reach the island.
        // The cursor already skips markers, but if one still arrives here
        // (a variant isMarkerLine missed, a stale re-publish, lyrics not
        // loaded yet so current is nil), the current line becomes the song
        // title and prev/next become nil — the pill shows the title, never
        // a lone ♪ and never a blank. Logged when it fires so the journal
        // shows exactly which line was replaced.
        let safePrevious = Self.isPresentableLyricLine(previous) ? previous : nil
        let safeNext = Self.isPresentableLyricLine(next) ? next : nil
        let safeCurrent: String
        if Self.isPresentableLyricLine(current) {
            safeCurrent = current!
        } else {
            if let raw = current, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                    message: "岛歌词已过滤标记行",
                    detail: "\(track.name)：\(raw)")
            }
            safeCurrent = track.name
        }
        let state = LyricsLiveActivityAttributes.ContentState(
            title: track.name,
            artist: track.artistNames,
            previousLine: safePrevious,
            currentLine: safeCurrent,
            nextLine: safeNext,
            isPlaying: PlayerService.shared.isPlaying,
            progress: PlayerService.shared.progress,
            duration: PlayerService.shared.duration,
            lyricColorHex: currentLyricColorHex,
            coverURL: currentCoverURL,
            hasCover: currentHasCover,
            // #57: activity identity tag (nil before the first start;
            // startActivity stamps the request state with the start time).
            sessionTag: activityStartedTag,
            // #59: mode + queue + control state ride in every ContentState
            // so the extension renders the right mode without asking the
            // app. Playlist mode carries the upcoming queue (max 5); lyric
            // mode carries nil. repeatMode/isLiked drive the expanded
            // view's repeat/heart icons.
            isPlaylistMode: SettingsManager.shared.islandMode == .playlist,
            queueTitles: SettingsManager.shared.islandMode == .playlist ? upcomingQueueTitles() : nil,
            repeatMode: PlayerService.shared.repeatMode.rawValue,
            isLiked: AccountStore.shared.isLiked(track.id),
            // #62: pure music — the track's resolve came back
            // definitively empty (all sources, not still loading).
            // While loading, or after a network error, this is false
            // and the island keeps the title fallback.
            isPureMusic: PlayerService.shared.noLyricsConfirmed
        )
        guard state != lastState else { return }
        let oldState = lastState
        lastState = state
        guard state.isPlaying else {
            // #58: say why no start happens when nothing is running:
            // endActivity is a silent no-op with no activity, so without
            // this line a paused/buffering player leaves no trace either.
            if activity == nil {
                logBlockedStart(reason: "未在播放", detail: track.name)
            }
            endActivity()
            return
        }
        // #51: dismissed by hand — stop scheduling pushes entirely. Before,
        // the gate below passed on every tick while activity was nil, so
        // the same line was pushed ~2x/sec after a dismiss and each one
        // was silently dropped — log-4 shows 25 of them in 16s. lastState
        // is still updated above, so a foreground refresh keeps a fresh
        // state.
        guard !islandDismissedByUser else {
            logBlockedStart(reason: "已被用户关闭", detail: track.name)
            return
        }
        // Kugou-style trigger (delayUpdatePlayInfo): only a line change, a
        // track change, or no activity yet justifies a push. Progress ticks
        // that leave the lines unchanged trigger nothing — the caller fires
        // on every tick, and pushing on each one (~2x/sec) exhausts the
        // system's update budget, after which updates are dropped and the
        // island goes stale with no lyric. The push itself is debounced
        // 0.2s (scheduleDebouncedPush), so a burst of changes collapses
        // into a single Activity update.
        let linesChanged = lastPublishedLines?.previous != safePrevious
            || lastPublishedLines?.current != safeCurrent
            || lastPublishedLines?.next != safeNext
        // #53: track identity lives in currentTrackID now (attributes
        // carry no track id — the activity is session-scoped). A switch
        // still justifies a push: the new song's title/lines must reach
        // the island promptly, as an update, not a restart.
        let isNewTrack = currentTrackID != track.id
        if isNewTrack { currentTrackID = track.id }
        // #59: the extension renders mode, queue, repeat and like state
        // too — a change in any of them must push even when the lyric
        // lines and the track are unchanged. Otherwise a mode switch
        // (lyrics ↔ playlist), a queue reorder, a repeat tap or a like
        // tap never reaches the island until the next lyric line, and
        // the "点击开启歌词" button would appear to do nothing.
        let modeChanged = state.isPlaylistMode != oldState?.isPlaylistMode
        let queueChanged = state.queueTitles != oldState?.queueTitles
        let controlsChanged = state.repeatMode != oldState?.repeatMode
            || state.isLiked != oldState?.isLiked
        // #62: pure-music flip (loading → confirmed no lyrics) must
        // push even though the lines are unchanged — the title was
        // already the fallback, so without this the pill keeps the
        // title and the expanded view never learns to show "纯音乐".
        let pureMusicChanged = state.isPureMusic != oldState?.isPureMusic
        guard linesChanged || isNewTrack || modeChanged || queueChanged || controlsChanged || pureMusicChanged || activity == nil else { return }
        lastPublishedLines = (safePrevious, safeCurrent, safeNext)
        scheduleDebouncedPush(state: state)
    }

    /// Schedules the island push 0.2s out, cancelling any pending one — the
    /// Swift equivalent of Kugou's cancelPreviousPerformRequestsWithTarget +
    /// performSelector:updatePlayInfo afterDelay:0.2 (this class is a Swift
    /// @MainActor type, not an NSObject subclass, so the same cancel+delay
    /// is done with a cancellable Task instead of the ObjC API). The
    /// pending push is cancelled by a newer trigger and by endActivity.
    private func scheduleDebouncedPush(state: LyricsLiveActivityAttributes.ContentState) {
        pendingPushTask?.cancel()
        // #58: a first start must not wait behind the 0.2s push debounce.
        // The debounce cancels the pending push on every new trigger, so
        // a start queued behind it only fires after 0.2s of quiet — during
        // rapid track changes the ticks keep cancelling it and the island
        // never starts. Throttle the pushes, never the start: attempt it
        // at once. Updates (activity already running) keep the debounce
        // below. liveActivity() also heals a stale manager reference here
        // (system-ended activity) so the start decision is made on the
        // live state, not a dead object.
        if liveActivity() == nil {
            guard !islandDismissedByUser else { return }
            // Same rule as the debounced path (#53): only log the push
            // when the start will actually be attempted — in the
            // background startActivity defers (and logs the defer itself,
            // 30s throttled), so a push line here would be a lie.
            if isAppForeground {
                DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                    message: "推送灵动岛歌词",
                    detail: state.currentLine ?? state.title)
            }
            startActivity(state: state)
            return
        }
        pendingPushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.pushDebounceDelay * 1_000_000_000))
            } catch {
                return // superseded by a newer trigger, or ended meanwhile
            }
            guard !Task.isCancelled, let self else { return }
            self.pendingPushTask = nil
            // Diagnostic trail: every actual push records the line the
            // island shows, so an exported log shows exactly why the pill
            // reads what it reads. Category is "歌词", not "灵动岛":
            // lastIslandFailure takes the newest "灵动岛" entry as the
            // failure line, and these info entries must not masquerade
            // as failures. #51: the log line moved below the dismissed
            // check — before, a push dropped after a user dismiss was
            // still logged, so log-4 shows 25 dropped pushes in 16s
            // after 20:19:45. A logged push now means a real update or
            // start was attempted; a dropped one leaves no trace.
            if let activity = self.liveActivity() {
                // Session-scoped activity (#53): a track change never
                // restarts anything — the same activity is updated in
                // place with the new song's title/lines/color/cover.
                // activity.update is allowed from the background, so a
                // song advancing while locked/backgrounded keeps the
                // island alive. The old end + re-request here killed it:
                // Activity.request throws "Target is not foreground"
                // in the background (log-7) and the island stayed dead
                // until the user foregrounded the app.
                DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                    message: "推送灵动岛歌词",
                    detail: state.currentLine ?? state.title)
                await activity.update(ActivityContent(state: state, staleDate: Self.staleDate()))
                self.restartHeartbeat()
            } else if !self.islandDismissedByUser {
                // The system already ended our activity (stale date passed
                // while an update was dropped): restart it with this state
                // instead of updating a dead object that silently no-ops.
                // #53: only log the push when the start will actually be
                // attempted. In the background startActivity defers (and
                // logs the defer itself, 30s throttled), so a push line
                // here would be a lie — log-7 shows ~50 of them while
                // switching tracks in the background.
                if self.isAppForeground {
                    DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                        message: "推送灵动岛歌词",
                        detail: state.currentLine ?? state.title)
                }
                self.startActivity(state: state)
            }
            // Dismissed by the user: drop the push silently.
        }
    }

    // MARK: - Heartbeat (stale-date guard)

    /// The running activity, if the system still lists it. The manager's
    /// `activity` reference can go stale: when the stale date passes
    /// (updates dropped, app suspended) the system ends the activity, but
    /// our var still holds it and further `update` calls silently no-op —
    /// the island freezes on the last accepted state (#48: the pill still
    /// showed the 03:09:43 line at 03:11:18). A user-dismissed activity is
    /// also dropped here, but it is NOT restarted: the user dismissed it
    /// on purpose (see islandDismissedByUser).
    private func liveActivity() -> Activity<LyricsLiveActivityAttributes>? {
        guard let activity else { return nil }
        if Activity<LyricsLiveActivityAttributes>.activities.contains(where: { $0.id == activity.id }) {
            return activity
        }
        self.activity = nil
        if activity.activityState == .dismissed {
            islandDismissedByUser = true
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "灵动岛活动已被用户关闭",
                detail: activity.content.state.title)
        } else {
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "灵动岛活动已被系统结束，将重新启动",
                detail: activity.content.state.title)
        }
        return nil
    }

    /// (Re)arms a single-shot 8s timer that re-pushes the current state
    /// while playing. Called after every real push and after a successful
    /// start; cancelled by endActivity. Because every push re-arms it, it
    /// only fires after 8s with no line change — the normal case (a new
    /// line every few seconds) never sees it.
    private func restartHeartbeat() {
        stopHeartbeat()
        scheduleHeartbeat()
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func scheduleHeartbeat() {
        guard activity != nil else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
            } catch {
                return // superseded by a newer push, or ended meanwhile
            }
            guard !Task.isCancelled, let self else { return }
            self.heartbeatTask = nil
            self.heartbeatFire()
        }
    }

    /// One heartbeat tick: refresh the stale date (and progress) while the
    /// song plays, and heal a manager reference the system already ended.
    /// Runs only while playing; pauses and track ends stop it via
    /// endActivity, and the guard below is a second lock.
    private func heartbeatFire() {
        guard SettingsManager.shared.lyricsOnIsland else {
            // Toggle off mid-flight: stop silently (no re-arm); endActivity
            // owns the teardown and logs it.
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "心跳停止：歌词上岛已关闭", detail: nil)
            return
        }
        guard PlayerService.shared.isPlaying,
              PlayerService.shared.currentTrack != nil,
              var state = lastState else {
            // Not playing any more (or toggle off): nothing to keep alive.
            // endActivity owns the teardown; just don't re-arm. Logged
            // (once per arm, never spams) because a bail here with no
            // preceding endActivity is exactly how a frozen island starts:
            // it means isPlaying went false, or the track/state vanished,
            // without the $isPlaying sink ever running.
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "心跳停止：不在播放或无状态",
                detail: "isPlaying=\(PlayerService.shared.isPlaying)，track=\(PlayerService.shared.currentTrack?.name ?? "无")，state=\(lastState == nil ? "无" : "有")")
            return
        }
        // The smoking gun for a stalled player: the heartbeat runs (the app
        // is alive) but the 0.2s time observer has not ticked for a while —
        // player time frozen, no line changes, no pushes. Throttled to
        // once a minute (same window as the heartbeat log) so a persisting
        // stall does not flood the journal.
        if let lastTick = PlayerService.shared.lastPlayerTickAt {
            let gap = Date().timeIntervalSince(lastTick)
            let now = Date()
            if gap > 10,
               lastTickStallLogAt == nil || now.timeIntervalSince(lastTickStallLogAt!) >= 60 {
                lastTickStallLogAt = now
                DiagnosticLogStore.shared.append(level: .warning, category: "歌词",
                    message: "播放器 tick 停滞",
                    detail: "距上次 tick \(Int(gap)) 秒，缓冲中=\(PlayerService.shared.isBuffering)")
            }
        }
        state.progress = PlayerService.shared.progress
        state.duration = PlayerService.shared.duration
        state.isPlaying = true
        state.lyricColorHex = currentLyricColorHex
        state.coverURL = currentCoverURL
        state.hasCover = currentHasCover
        // #59: the heartbeat re-pushes the last state, so it must carry
        // the current mode/queue/control state too — otherwise a repeat
        // or like tap (or a queue change) is overwritten by the next
        // heartbeat with the stale values from when the state was built.
        state.isPlaylistMode = SettingsManager.shared.islandMode == .playlist
        state.queueTitles = state.isPlaylistMode ? upcomingQueueTitles() : nil
        state.repeatMode = PlayerService.shared.repeatMode.rawValue
        if let track = PlayerService.shared.currentTrack {
            state.isLiked = AccountStore.shared.isLiked(track.id)
        }
        if let activity = liveActivity() {
            // Session-scoped activity (#53): the heartbeat updates in
            // place whatever song is current — a track change never ends
            // and restarts here either (see scheduleDebouncedPush).
            lastState = state
            Task { [activity] in
                await activity.update(ActivityContent(state: state, staleDate: Self.staleDate()))
            }
            logHeartbeatIfDue()
            scheduleHeartbeat()
        } else if !islandDismissedByUser {
            // The system ended the activity (stale date passed while an
            // update was dropped): restart it with the current state.
            startActivity(state: state)
        }
        // Dismissed by the user: no restart, no re-arm; the next track
        // change clears the flag and a fresh island may start.
    }

    /// Routine heartbeats are logged at most once a minute so the journal
    /// stays readable; heals and restarts always log (see liveActivity).
    private func logHeartbeatIfDue() {
        let now = Date()
        guard lastHeartbeatLogAt == nil || now.timeIntervalSince(lastHeartbeatLogAt!) >= 60 else { return }
        lastHeartbeatLogAt = now
        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
            message: "灵动岛心跳：重推当前行",
            detail: lastState?.currentLine ?? lastState?.title)
    }

    /// Re-publishes the last known lyric state (refresh button / deep link).
    /// Re-sends the same ContentState so a throttled or dropped update gets
    /// another chance. This does NOT lift Apple's update budget or the 8-hour
    /// lifetime — see LiveActivity-edits.md §7.
    func refreshActivity() {
        guard let state = lastState else { return }
        guard SettingsManager.shared.lyricsOnIsland, state.isPlaying else { return }
        if let activity = liveActivity() {
            Task { await activity.update(ActivityContent(state: state, staleDate: Self.staleDate())) }
        } else if !islandDismissedByUser, PlayerService.shared.currentTrack != nil {
            // Explicit re-publish (refresh button / deep link / foreground
            // return): bypass the 2s attempt throttle.
            startActivity(state: state, force: true)
        }
    }

    // MARK: - Lifecycle

    /// Whether the last start attempt failed (request threw) or was
    /// deferred (app not foreground). The retry loop and the 2s attempt
    /// throttle key off this: a failed start is retried, a successful one
    /// clears it.
    private var startFailed = false
    /// When the last start was attempted, so a burst of lyric ticks after
    /// a failure does not hammer Activity.request — attempts are at most
    /// one per 2s (the retry loop owns the cadence).
    private var lastStartAttemptAt: Date?
    /// The state a failed/deferred start should retry with. Overwritten
    /// by every newer tick, so the retry always uses the freshest line.
    /// (#53: just the state now — attributes carry no track id, and a
    /// start is a session start, not a per-track start.)
    private var pendingStartState: LyricsLiveActivityAttributes.ContentState?
    /// Retry loop for a failed start (see armStartRetry). One instance at
    /// most; cancelled on success, pause/end, or user dismiss.
    private var startRetryTask: Task<Void, Never>?
    /// Whether the "island failed to start" toast was already shown this
    /// failure episode, so a retrying start toasts once instead of every
    /// 2s. Reset on a successful start.
    private var startFailureToastShown = false
    /// Whether the "Live Activities disabled in Settings" refusal was
    /// already logged this launch (the authorization state cannot change
    /// without the user leaving for Settings, so once is enough).
    private var authorizationRefusalNoted = false
    /// Last "start deferred: app not foreground" log, so a backgrounded
    /// app with a dead island does not log the defer every 2s — once per
    /// 30s is enough to prove it is waiting for the foreground.
    private var lastDeferLogAt: Date?
    /// Last "start blocked" log per reason, so a blocked start leaves a
    /// trace without flooding the journal. (#58: log-12 proved a silent
    /// gate is undiagnosable — a 2h blackout left zero log lines because
    /// the toggle-off return in lyricDidChange was silent. Each reason
    /// logs at most once per its throttle window.)
    private var lastBlockedStartLogAt: [String: Date] = [:]

    /// Logs a blocked start attempt, throttled per reason. Callers are the
    /// gates that return before any start is attempted — without this the
    /// journal cannot tell "toggle off" from "never tried".
    private func logBlockedStart(reason: String, detail: String? = nil, throttleSeconds: TimeInterval = 60) {
        let now = Date()
        if let last = lastBlockedStartLogAt[reason], now.timeIntervalSince(last) < throttleSeconds { return }
        lastBlockedStartLogAt[reason] = now
        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
            message: "灵动岛未启动：\(reason)", detail: detail)
    }
    /// Last track seen by the $currentTrack sink, for the 切歌 log: the
    /// old name/ID next to the new one shows whether a switch is the user
    /// tapping fast or the player re-setting the same track.
    private var lastSeenTrack: (id: Int, name: String)?
    /// Track id the running activity is currently showing. The activity
    /// is session-scoped (#53), so this — not the attributes — is what
    /// lyricDidChange compares against to detect a switch. Set in the
    /// $currentTrack sink and in lyricDidChange; cleared when the track
    /// becomes nil (endActivity follows).
    private var currentTrackID: Int?
    /// #57: when the running activity was requested, and its "HHmm" tag.
    /// The tag rides in every ContentState (see lyricDidChange) and the
    /// pill shows it, so one screenshot tells a live activity from a
    /// stale leftover (old time) and a #57 extension from an old one
    /// (no tag). Set on a successful Activity.request, cleared by
    /// endActivity. The tag string is cached here — not recomputed per
    /// tick — because lyricDidChange runs on every 0.2s time-observer tick.
    private var activityStartedAt: Date?
    private var activityStartedTag: String?
    /// "HHmm" (e.g. "1427") for a date; the session tag is deliberately
    /// short — the pill is narrow and the lyric truncates first.
    private static func hhmm(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmm"
        return formatter.string(from: date)
    }
    /// How often the retry loop re-attempts a failed start, and the
    /// minimum gap between two attempts from any path.
    private static let startRetryInterval: TimeInterval = 2

    /// Whether the app is foreground right now. Activity.request throws
    /// "Target is not foreground" otherwise, so startActivity defers
    /// instead of requesting — and a push log written before such a
    /// deferred start would claim an update that never happened.
    private var isAppForeground: Bool {
        UIApplication.shared.applicationState == .active
    }

    /// Starts the session's activity. Called only for a first start (or a
    /// restart after the system ended it): track changes never come here
    /// any more (#53) — they update the running activity in place.
    private func startActivity(state: LyricsLiveActivityAttributes.ContentState, force: Bool = false) {
        // The user dismissed the island by hand: don't resurrect it for
        // the same track. Cleared on the next track change.
        guard !islandDismissedByUser else {
            logBlockedStart(reason: "已被用户关闭", detail: state.title)
            return
        }
        guard authorizationStatus() == .granted else {
            // Was silent: the toggle on + a black island with no feedback.
            // Note it once so the user knows to enable Live Activities.
            if !authorizationRefusalNoted {
                authorizationRefusalNoted = true
                DiagnosticLogStore.shared.append(level: .warning, category: "灵动岛", message: "启动实时活动被系统拒绝", detail: "系统设置中未开启实时活动。")
                ToastCenter.shared.show(String(localized: "灵动岛未启动：请在系统设置中为 Kumone 开启「实时活动」"))
            }
            return
        }
        // A burst of lyric ticks after a failure must not hammer
        // Activity.request: at most one attempt per 2s, and the retry loop
        // owns the next try. Forced attempts (retry loop, foreground
        // return, explicit refresh) always go through. #58: this used to
        // return silently — a throttled tick left no trace that a start
        // was even attempted, so the journal could not tell "throttled"
        // from "never tried".
        let now = Date()
        if !force, startFailed, let last = lastStartAttemptAt, now.timeIntervalSince(last) < Self.startRetryInterval {
            logBlockedStart(reason: "启动尝试节流", detail: state.title)
            armStartRetry()
            return
        }
        lastStartAttemptAt = now
        // Activity.request only works while the app is foreground — a
        // first start issued while backgrounded throws "Target is not
        // foreground" (log-4, 20:18:28). Defer instead of failing:
        // remember the state, retry on the foreground return, and say so
        // in the log with the state that proves it — the next export can
        // tell a background defer from a foreground refusal. (#53: this
        // is only the first-start path now; track changes update in place
        // and never reach Activity.request, so a background track change
        // no longer defers or dies.)
        guard UIApplication.shared.applicationState == .active else {
            startFailed = true
            pendingStartState = state
            if lastDeferLogAt == nil || now.timeIntervalSince(lastDeferLogAt!) >= 30 {
                lastDeferLogAt = now
                DiagnosticLogStore.shared.append(level: .warning, category: "灵动岛",
                    message: "启动实时活动推迟：App 不在前台",
                    detail: "\(foregroundStateDescription())，回到前台时重建")
            }
            armStartRetry()
            return
        }
        // A previous launch may have left a system activity behind:
        // force-quit runs no end code, so the old activity lingers until
        // its stale date. A new request while it exists is refused by the
        // guard below and the island would stay stuck on the old song, so
        // end the leftovers first and retry with this state once they are
        // gone. (The retry and lyricDidChange both run on the MainActor,
        // so two starts cannot interleave and duplicate the activity.)
        let leftovers = Activity<LyricsLiveActivityAttributes>.activities.filter { $0.id != activity?.id }
        if !leftovers.isEmpty {
            Task {
                for old in leftovers {
                    await old.end(ActivityContent(state: old.content.state, staleDate: nil), dismissalPolicy: .immediate)
                }
                self.startActivity(state: state, force: force)
            }
            return
        }
        guard Activity<LyricsLiveActivityAttributes>.activities.isEmpty else {
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "启动实时活动跳过：已有系统活动", detail: state.title)
            return
        }
        do {
            // #57: stamp the request state with this activity's start
            // time — the pill shows it, so a screenshot proves which
            // activity is displayed. lyricDidChange built this state
            // before the activity existed (tag nil); the request IS the
            // start, so "now" is the start time.
            var requestState = state
            let startedAt = Date()
            let tag = Self.hhmm(startedAt)
            requestState.sessionTag = tag
            activityStartedAt = startedAt
            activityStartedTag = tag
            activity = try Activity.request(
                attributes: LyricsLiveActivityAttributes(),
                content: ActivityContent(state: requestState, staleDate: Self.staleDate())
            )
            startFailed = false
            startFailureToastShown = false
            pendingStartState = nil
            disarmStartRetry()
            // The manager's record must match what the activity holds
            // (with the tag); otherwise the next tick's state (with the
            // tag) looks like a change and the heartbeat re-pushes a
            // duplicate, and refreshActivity would publish a tag-less state.
            lastState = requestState
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "灵动岛活动已启动", detail: "\(state.title) · 活动 \(tag)")
            locationKeepAlive.startIfEnabled()
            restartHeartbeat()
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "心跳已启动", detail: "8 秒无行变时重推")
        } catch {
            // #51: every failure is logged (with the foreground state at
            // the time), not just the first per launch — log-4's single
            // 20:18:28 entry hid whether later ticks retried and failed
            // again. The toast stays once per episode.
            activity = nil
            startFailed = true
            pendingStartState = state
            // #57: the stamp above was set before the request — a failed
            // request leaves no activity, so its tag must not survive to
            // the next tick's state; the retry stamps a fresh one on success.
            activityStartedAt = nil
            activityStartedTag = nil
            DiagnosticLogStore.shared.append(level: .warning, category: "灵动岛",
                message: "启动实时活动失败",
                detail: "\(error.localizedDescription) | \(foregroundStateDescription())")
            if !startFailureToastShown {
                startFailureToastShown = true
                ToastCenter.shared.show(String(localized: "灵动岛启动失败，请稍后重试"))
            }
            armStartRetry()
        }
    }

    /// App + scene foreground state in one line, for start-failure logs:
    /// the next export must be able to tell a background defer from a
    /// foreground refusal without guessing.
    private func foregroundStateDescription() -> String {
        let appState: String
        switch UIApplication.shared.applicationState {
        case .active: appState = "前台"
        case .inactive: appState = "未激活"
        case .background: appState = "后台"
        @unknown default: appState = "未知"
        }
        let sceneState: String
        switch UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.activationState {
        case .foregroundActive: sceneState = "场景前台活跃"
        case .foregroundInactive: sceneState = "场景前台未激活"
        case .background: sceneState = "场景后台"
        case .unattached: sceneState = "场景未挂接"
        case .none: sceneState = "无场景"
        @unknown default: sceneState = "场景未知"
        }
        return "App\(appState)，\(sceneState)"
    }

    /// Retries a failed/deferred start every 2s while the song plays and
    /// no activity runs — log-4's 44s dead gap happened because the only
    /// retry was the next lyric tick's debounced push (sparse: the 0.2s
    /// tick churn cancels most pushes before they fire) and the heartbeat
    /// had been stopped by endActivity. The loop reads the freshest state
    /// each round (lastState from the latest tick, else the pending one)
    /// and stops on success, pause, track end, or user dismiss. While
    /// backgrounded it idles quietly — Activity.request requires
    /// foreground, and noteAppForegrounded rebuilds on return.
    private func armStartRetry() {
        guard startRetryTask == nil else { return }
        startRetryTask = Task { @MainActor [weak self] in
            // #58: consecutive rounds with no playback (buffering between
            // tracks, a slow URL resolve). A transient not-playing used to
            // `return` here and kill the loop outright — one buffering blip
            // ended all retries until a later lyric tick happened to reach
            // startActivity. Keep waiting instead; a real pause still kills
            // the loop via endActivity → disarmStartRetry. Give up after
            // 30s of not playing so the loop cannot spin forever.
            var notPlayingRounds = 0
            while let self, !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: UInt64(Self.startRetryInterval * 1_000_000_000)) } catch { return }
                guard !Task.isCancelled else { return }
                guard PlayerService.shared.isPlaying,
                      PlayerService.shared.currentTrack != nil else {
                    notPlayingRounds += 1
                    if notPlayingRounds * 2 >= 30 { return }
                    continue
                }
                notPlayingRounds = 0
                guard self.activity == nil,
                      !self.islandDismissedByUser else { return }
                guard UIApplication.shared.applicationState == .active else { continue }
                guard let state = self.lastState ?? self.pendingStartState else { return }
                self.startActivity(state: state, force: true)
                if self.activity != nil { return }
            }
        }
    }

    private func disarmStartRetry() {
        startRetryTask?.cancel()
        startRetryTask = nil
    }

    /// Ends the activity with immediate dismissal: it disappears from the
    /// Dynamic Island and the Lock Screen at once instead of lingering.
    /// Also cancels any debounced push still inside its 0.2s window, so a
    /// stop/pause never starts an island after the fact. The cancel runs
    /// before the activity guard: a pending start (no activity yet) must
    /// be cancelled too, not just a pending update.
    func endActivity() {
        pendingPushTask?.cancel()
        pendingPushTask = nil
        stopHeartbeat()
        cancelStallWatch()
        // The island is intentionally gone (pause / track end / toggle
        // off): a pending start retry must not resurrect it, and the
        // stashed state is stale. A later lyric tick re-arms both if a
        // new song starts playing.
        disarmStartRetry()
        pendingStartState = nil
        guard let activity else { return }
        // Category "歌词" (see scheduleDebouncedPush): the "灵动岛"
        // category is reserved for start failures, which Settings shows
        // as the failure line.
        // #58: "已结束" used to be logged here, before the system end was
        // even attempted — log-12's 17:20:34 end was logged, yet the same
        // activity was still a leftover at the 17:20:49 relaunch: the
        // fire-and-forget end Task never ran before the process died.
        // Log "正在结束" now; "已结束" is logged only after the awaited
        // system end below actually completes, so a missing "已结束" in
        // the next export proves the end was lost.
        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
            message: "正在结束灵动岛活动", detail: activity.content.state.title)
        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
            message: "心跳已停止：活动结束", detail: nil)
        self.activity = nil
        lastState = nil
        // #57: the session tag dies with the activity — the next start
        // stamps a fresh one, so a pill can never show a new activity
        // under an old activity's time.
        activityStartedAt = nil
        activityStartedTag = nil
        locationKeepAlive.stop()
        let finalState = activity.content.state
        // The end call must survive the app being suspended a moment later
        // (pause from the Lock Screen / Control Center while backgrounded):
        // a bare Task can be frozen before it runs and the island lingers
        // showing the last line. A background-task assertion gives the
        // dismissal a window to complete.
        if endBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(endBackgroundTask)
            endBackgroundTask = .invalid
        }
        endBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "KumoneEndLiveActivity")
        // Capture this call's task id: a second endActivity before the
        // first Task finishes used to make the first Task end the second
        // call's assertion early, freezing the second dismissal mid-flight.
        //
        // #58: on the terminate path the process can die before a default-
        // priority Task is even scheduled (log-12: end logged 17:20:34,
        // activity still a leftover at 17:20:49), so the end runs at
        // .userInitiated — the best chance of executing before process
        // death. The completion log below is the only proof the system
        // end actually happened.
        let taskID = endBackgroundTask
        Task(priority: .userInitiated) { [weak self] in
            await activity.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "灵动岛活动已结束", detail: finalState.title)
            guard let self else {
                UIApplication.shared.endBackgroundTask(taskID)
                return
            }
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
            }
            if self.endBackgroundTask == taskID {
                self.endBackgroundTask = .invalid
            }
        }
    }

    /// Called when the user turns 歌词上岛 off.
    func disable() {
        endActivity()
    }

    /// Called from applicationWillTerminate / entering background while idle.
    public func endForAppShutdown() {
        endActivity()
    }

    /// #54: called from applicationWillTerminate ONLY (not from the
    /// background-idle path). Marks this session's exit clean; a crash,
    /// jetsam kill, or force-quit never reaches here, so the next launch
    /// reads the flag and can tell clean from unclean death.
    public func noteWillTerminate() {
        UserDefaults.standard.set(true, forKey: Self.lastExitCleanKey)
        endForAppShutdown()
    }

    /// Called from entering background: ends the activity only when nothing
    /// is playing. The playback check lives here — not in the caller — so
    /// targets outside KumoneCore never need to touch PlayerService.
    public func endForAppShutdownIfNotPlaying() {
        if !PlayerService.shared.isPlaying {
            endForAppShutdown()
        }
    }

    private static func staleDate() -> Date {
        // Eight seconds (#59: was 10s, Kugou's window): if the app dies
        // without ending the activity (a force-quit runs no end code —
        // applicationWillTerminate never fires), the island goes stale
        // and is removed within ~8s instead of lingering after the app
        // is gone. While the app is alive and playing this is never
        // reached: every update carries a fresh stale date, line changes
        // push one, and the heartbeat re-pushes after 6s of quiet — so a
        // long line or a dropped update can no longer freeze the island
        // on an old line. The 2s margin (heartbeat 6s < stale 8s) is the
        // same balance as before; a shorter window would risk the island
        // vanishing mid-song if the system ever throttles updates.
        Date().addingTimeInterval(8)
    }

    // MARK: - Lifecycle diagnostics (#50)

    /// #54: clean-exit flag for the app-death question (log-8 05:26:43,
    /// log-9 05:42:41 — activity ended, app relaunched 8s later, no
    /// pause/stall log). Set true only from applicationWillTerminate (via
    /// noteWillTerminate); a crash, jetsam kill, or force-quit never runs
    /// it, so the flag stays false and the next launch can tell a clean
    /// exit from an unclean death.
    private static let lastExitCleanKey = "kumone.lastExitClean"

    /// Called from the app delegate on launch. A dead app cannot log its
    /// own death (jetsam / crash), so the next launch is the only witness:
    /// a lingering system activity here proves the previous launch died
    /// without ending the island — the 102s silence in log-3 (last entry
    /// 03:38:53, black island reported 03:40:35, no heartbeat despite the
    /// 60s log throttle) is exactly this shape. The memory footprint is
    /// logged alongside it: this device has a jetsam / memory-pressure
    /// history, and a footprint near the limit at launch points at jetsam.
    public func noteAppLaunched() {
        // #54: did the previous session exit cleanly? Absent key = first
        // launch after installing this build (no previous record).
        if UserDefaults.standard.object(forKey: Self.lastExitCleanKey) == nil {
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "上次会话结束", detail: "首次启动（无上次记录）")
        } else if UserDefaults.standard.bool(forKey: Self.lastExitCleanKey) {
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "上次会话结束", detail: "正常退出")
        } else {
            DiagnosticLogStore.shared.append(level: .warning, category: "歌词",
                message: "上次会话结束", detail: "异常（崩溃/被系统杀掉/被强退），上次启动没跑结束代码")
        }
        UserDefaults.standard.set(false, forKey: Self.lastExitCleanKey)
        // #58: the "turn on 歌词上岛" nudge is once per install, so a user
        // who reinstalls (the toggle resets to off — log-12's fresh #57
        // install) and misses the single toast plays for hours with a
        // black island and no reminder. Reset it every launch: the first
        // song of each launch reminds again until the toggle is on.
        // Never auto-enables — the island only ever starts when the user
        // turns it on.
        SettingsManager.shared.lyricsIslandNudgeShown = false
        let leftovers = Activity<LyricsLiveActivityAttributes>.activities
        let footprint = memoryFootprintMB().map { "\($0) MB" } ?? "未知"
        if leftovers.isEmpty {
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "App 启动", detail: "无残留灵动岛活动，内存 \(footprint)")
        } else {
            DiagnosticLogStore.shared.append(level: .warning, category: "歌词",
                message: "App 启动：发现残留灵动岛活动",
                detail: "\(leftovers.count) 个，上次启动没跑结束代码（被系统杀掉或强退），内存 \(footprint)")
            // #57: a leftover's last state is what the pill showed while
            // the app was dead — log it, so the journal can say whether
            // a stale pill was showing a bare ♪ (pre-#56 leak) or an old
            // song's line. Without this line the next export cannot tell
            // a stale pill from a live one.
            for old in leftovers {
                DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                    message: "残留灵动岛活动状态",
                    detail: "\(old.content.state.title) | 当前行：\(old.content.state.currentLine ?? "无")")
            }
            // #57: end the leftovers NOW, whether playing or not. Before,
            // a leftover survived while playing until the next lyric tick
            // reached startActivity's own leftover handling — and until
            // then the island kept showing the dead session's state
            // (possibly a bare ♪). Ending it here blanks the island for
            // ~0.2s: the next lyric tick (updateLyricsCursor fires on
            // every time-observer tick) starts a fresh activity at once.
            // If the app launched in the background the fresh start still
            // defers to the foreground return, as before — the stale pill
            // is gone either way, instead of showing an old song's line.
            Task {
                for old in leftovers {
                    await old.end(ActivityContent(state: old.content.state, staleDate: nil), dismissalPolicy: .immediate)
                }
            }
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "已清理残留灵动岛活动",
                detail: PlayerService.shared.isPlaying ? "播放中：已结束旧活动，新活动由下一歌词 tick 启动" : "未在播放，岛不应滞留")
        }
    }

    /// Called from the app delegate on entering background. The footprint
    /// matters here too: jetsam kills suspended apps first, so a big
    /// background footprint is the best predictor of the next black island.
    public func noteAppBackgrounded() {
        backgroundedAt = Date()
        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
            message: "App 进入后台",
            detail: "播放中=\(PlayerService.shared.isPlaying)，岛活动=\(activity == nil ? "无" : "运行中")，位置保活=\(locationKeepAlive.isRunning ? "运行中" : "未运行")，内存 \(memoryFootprintMB().map { "\($0) MB" } ?? "未知")")
    }

    /// Called from the app delegate on entering foreground. The gap since
    /// backgrounding is the freeze window, retroactively proving how long
    /// the app was suspended — a Task.sleep heartbeat cannot log while
    /// frozen, so this is the only place the suspension becomes visible.
    /// Proactively re-publishes the island state: if the system ended the
    /// activity while we were away, refreshActivity heals it at once
    /// instead of waiting for the next lyric line.
    public func noteAppForegrounded() {
        let gap = backgroundedAt.map { Int(Date().timeIntervalSince($0)) }
        backgroundedAt = nil
        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
            message: "App 回到前台",
            detail: "距进入后台 \(gap.map { "\($0) 秒" } ?? "未知")，播放中=\(PlayerService.shared.isPlaying)，岛活动=\(activity == nil ? "无" : "运行中")，系统活动=\(Activity<LyricsLiveActivityAttributes>.activities.count) 个")
        if PlayerService.shared.isPlaying, lastState != nil {
            refreshActivity()
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "回到前台：重新发布岛状态", detail: lastState?.currentLine ?? lastState?.title)
        } else if PlayerService.shared.isPlaying, activity == nil, !islandDismissedByUser,
                  let pending = pendingStartState {
            // No fresh tick state (endActivity cleared lastState after the
            // last tick): rebuild from the pending start state instead of
            // waiting for the next lyric line.
            startActivity(state: pending, force: true)
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "回到前台：重建灵动岛活动", detail: pending.title)
        } else if PlayerService.shared.isPlaying {
            // #58: playing but nothing to rebuild from (endActivity cleared
            // lastState + pendingStartState) — the next lyric tick (0.2s)
            // repopulates the state and starts. Logged so the journal shows
            // the rebuild is waiting on a tick, not stuck.
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "回到前台：无岛状态可重建，等待下一歌词 tick", detail: PlayerService.shared.currentTrack?.name)
        }
    }

    /// Current memory footprint (phys_footprint) in MB, for the jetsam
    /// question. Nil when the Mach call fails; never crashes the log path.
    private func memoryFootprintMB() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.phys_footprint) / 1_048_576
    }

    // MARK: - Audio stall watch (#50)

    /// The player entered .waitingToPlayAtSpecifiedRate while playing: the
    /// stream stalled (dead LX URL, network drop) without failing the item,
    /// so nothing else in the player notices — isPlaying stays true, the
    /// time observer stops (player time frozen), and the island is left to
    /// go stale black. The stall background task is begun at once: the app
    /// gets ~30s of execution even if iOS would otherwise suspend it
    /// mid-stall, so the heartbeat keeps running through a short stall.
    func noteAudioStallBegan() {
        guard SettingsManager.shared.lyricsOnIsland, activity != nil else { return }
        guard stallBeganAt == nil else { return } // already watching
        stallBeganAt = Date()
        if stallBackgroundTask == .invalid {
            stallBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "KumoneIslandStall")
        }
        DiagnosticLogStore.shared.append(level: .warning, category: "歌词",
            message: "音频缓冲中", detail: PlayerService.shared.currentTrack?.name)
        stallTask?.cancel()
        stallTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, self.stallBeganAt != nil else { return }
            self.stallTask = nil
            self.handleStallPersists()
        }
    }

    /// The player recovered from the stall. Cancels the timers and the
    /// grace background task; the island never noticed a short stall.
    func noteAudioStallEnded() {
        guard let began = stallBeganAt else { return }
        let seconds = Int(Date().timeIntervalSince(began))
        cancelStallWatch()
        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
            message: "音频恢复", detail: "停滞 \(seconds) 秒")
    }

    /// Still stalled after 10s: the grace window is already held (begun at
    /// stall start); arm the final timer — 30s total, then end the activity
    /// cleanly instead of leaving a black island.
    private func handleStallPersists() {
        guard PlayerService.shared.isPlaying, activity != nil, stallBeganAt != nil else { return }
        DiagnosticLogStore.shared.append(level: .warning, category: "歌词",
            message: "音频停滞超过 10 秒", detail: "后台任务保活，30 秒仍未恢复将关闭灵动岛")
        stallEndTask?.cancel()
        stallEndTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
            guard let self else { return }
            self.stallEndTask = nil
            // Still stalled after 30s total: end the activity cleanly so
            // the island disappears instead of sitting black. The next
            // lyric change after audio recovers restarts it (the
            // activity == nil push path in lyricDidChange).
            guard self.stallBeganAt != nil, PlayerService.shared.isPlaying, self.activity != nil else { return }
            DiagnosticLogStore.shared.append(level: .warning, category: "歌词",
                message: "音频长时间停滞（30 秒），关闭灵动岛",
                detail: PlayerService.shared.currentTrack?.name)
            self.endActivity()
        }
    }

    private func cancelStallWatch() {
        stallTask?.cancel()
        stallTask = nil
        stallEndTask?.cancel()
        stallEndTask = nil
        stallBeganAt = nil
        if stallBackgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(stallBackgroundTask)
            stallBackgroundTask = .invalid
        }
    }
}

// MARK: - Location keep-alive (opt-in, default OFF)

/// Keeps the app process awake in the background while the lyrics Live Activity
/// runs, so lyric updates can keep being attempted. Opt-in only, default off,
/// coarse accuracy, started only while an activity is running, stopped the
/// moment the activity ends.
///
/// What it does NOT do (read before enabling):
/// - It does NOT lift Apple's Live Activity update budget: updates can still be
///   throttled or dropped when the budget is spent, and the 8-hour lifetime
///   still applies. A frozen island can therefore persist even with keep-alive.
/// - It costs battery (background location) and is a privacy-sensitive
///   capability. The purpose string is in Info.plist.
/// - App Store review risk: Apple may reject background location whose purpose
///   is only to keep an app / Live Activity alive (Guidelines 2.5.4 / 5.1.1 —
///   background location must serve a core feature, not act as a keep-alive).
///   Sideloaded / TestFlight builds are less exposed, but TestFlight review
///   can still flag it. If review risk is unacceptable, leave the toggle off:
///   the island, the 3-line view and refresh all work without it.
@MainActor
final class LyricsLocationKeepAlive: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var running = false
    /// Whether the keep-alive session is active (for the background log).
    var isRunning: Bool { running }
    /// The "not started: not authorized" line is logged once per launch —
    /// startIfEnabled runs on every activity start, and the skip would
    /// otherwise repeat once per track.
    private var authorizationSkipLogged = false
    /// First location error per keep-alive session (didFailWithError can
    /// repeat); reset when the session restarts.
    private var locationErrorLogged = false
    /// Last throttled "location update arrived" log, so the journal can
    /// prove the keep-alive is actually producing wakeups (a stationary
    /// user with a 500m distance filter may never see one — and then the
    /// keep-alive is not keeping anything alive).
    private var lastLocationLogAt: Date?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = 500
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true
    }

    /// Requests WhenInUse authorization only when the user enables the toggle.
    /// Never called implicitly; never requests Always.
    func requestAuthorizationIfNeeded() {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.requestWhenInUseAuthorization()
    }

    func startIfEnabled() {
        guard SettingsManager.shared.lyricsIslandLocationKeepAlive else { return }
        guard manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways else {
            // #50: the keep-alive silently never starting is a black-island
            // candidate the log could never see — the user had the toggle
            // on, but "Allow Once" authorization expires on backgrounding
            // and startIfEnabled then refuses every time.
            if !authorizationSkipLogged {
                authorizationSkipLogged = true
                DiagnosticLogStore.shared.append(level: .warning, category: "歌词",
                    message: "位置保活未启动：未授权定位",
                    detail: "授权状态=\(manager.authorizationStatus)，需在系统设置中允许 Kumone 使用位置")
            }
            return
        }
        guard !running else { return }
        running = true
        locationErrorLogged = false
        manager.startUpdatingLocation()
        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
            message: "位置保活已启动", detail: "授权状态=\(manager.authorizationStatus)")
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopUpdatingLocation()
        DiagnosticLogStore.shared.append(level: .info, category: "歌词",
            message: "位置保活已停止", detail: nil)
    }

    // Location values are never read or stored: the updates exist only to keep
    // the process awake. Arrival itself is logged (throttled) so the journal
    // can prove the keep-alive session is alive.
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = Date()
            guard self.lastLocationLogAt == nil || now.timeIntervalSince(self.lastLocationLogAt!) >= 300 else { return }
            self.lastLocationLogAt = now
            DiagnosticLogStore.shared.append(level: .info, category: "歌词",
                message: "位置保活：收到定位更新", detail: "保活会话存活")
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self, !self.locationErrorLogged else { return }
            self.locationErrorLogged = true
            DiagnosticLogStore.shared.append(level: .warning, category: "歌词",
                message: "位置保活定位失败", detail: error.localizedDescription)
        }
    }
}
#endif
