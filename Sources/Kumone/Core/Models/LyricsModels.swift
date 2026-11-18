import Foundation

/// One timed word (or short run) inside a lyric line: a share of the line's
/// time spread across its characters, see `LyricsParser.spreadWords` — the
/// karaoke wipe maps one opacity step to one character.
struct LyricWord: Hashable {
    let text: String
    let start: TimeInterval
    let duration: TimeInterval
    var end: TimeInterval { start + duration }

    func replacingText(_ text: String) -> LyricWord {
        LyricWord(text: text, start: start, duration: duration)
    }
}

struct LyricLine: Identifiable, Hashable {
    let id: Int
    let time: TimeInterval
    /// When the line's singing ends: the next line's start, capped at six
    /// seconds.
    let end: TimeInterval
    let text: String
    var translation: String?
    var romaji: String?
    /// Base text split so each reading sits over the kanji it belongs to.
    /// Nil when there is nothing to annotate.
    var furigana: [RubySegment]?
    /// Per-word timings for karaoke highlighting, spread across the
    /// characters — whose text joined is exactly `text`, so the wipe maps
    /// one opacity to one character. Nil when the line has nothing to sing
    /// (no letters).
    var words: [LyricWord]?
}

struct ParsedLyrics: Hashable {
    var lines: [LyricLine] = []
    var isInstrumental = false
    var contributor: String?
    var translationContributor: String?

    var isEmpty: Bool { lines.isEmpty }

    /// Whether a lyric line carries no sung words: empty, only note symbols
    /// (♪ ♫ ♩ ♬), or a whole-line instrumental / interlude marker
    /// ("纯音乐", "间奏", …). LRC files mark intros and interludes with a
    /// bare ♪; pushing that to the island shows a lone ♪ instead of a
    /// lyric line, which is the #47 bug.
    static func isMarkerLine(_ text: String) -> Bool {
        // Strip invisible/format characters FIRST — by Unicode property,
        // not by enumeration. #53 listed nine of them and still missed
        // variants: LRC files from QQ / NetEase carry other variation
        // selectors (U+FE00–U+FE0F are Mn, not Cf), invisible operators
        // (U+2061–U+2064, Cf) and combining marks, so "♪" + one of those
        // passed as singable and the pill showed a lone ♪ (06:15/06:18
        // screenshots). General category .format (Cf) covers ZWSP/ZWJ/
        // ZWNJ/BOM/soft hyphen/isolates/word joiner; the two variation
        // selector ranges are added explicitly because they are Mn.
        // They carry no visible content, so dropping them cannot change
        // a real lyric.
        let visible = String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            guard scalar.properties.generalCategory != .format else { return false }
            switch scalar.value {
            case 0xFE00...0xFE0F, 0xE0100...0xE01EF: return false
            default: return true
            }
        }))
        let trimmed = visible.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if trimmed.contains("纯音乐") { return true }
        // Whole-line interlude markers, with or without brackets:
        // (间奏) / 【前奏】 / "intro".
        let unbracketed = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "()（）[]【】<>《》"))
        let lower = unbracketed.lowercased()
        if ["间奏", "前奏", "尾奏", "过门", "伴奏", "纯音乐",
            "instrumental", "intro", "outro", "interlude"].contains(lower) {
            return true
        }
        // No more enumerating symbols: strip all punctuation (Unicode P)
        // and ask whether anything singable is left — a letter or number
        // (CharacterSet.alphanumerics covers CJK, kana, hangul and Latin).
        // A line of only notes/symbols/punctuation ("♪", "♪!", "(♪)",
        // "♫ ♫", "…") has none, so it is a marker; a real line keeps its
        // letters ("♪啦啦啦", "会不会太久? 久到这结果") and is not. This
        // covers every present and future marker variant, not just the
        // ones seen so far.
        let content = trimmed.unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        return !content.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Index of the first singable (non-marker) line at or after `start`.
    func firstSingableIndex(from start: Int) -> Int? {
        guard start < lines.count else { return nil }
        return lines[start...].firstIndex { !Self.isMarkerLine($0.text) }
    }

    /// Index of the last singable (non-marker) line at or before `end`.
    func lastSingableIndex(through end: Int) -> Int? {
        guard end >= 0, !lines.isEmpty else { return nil }
        return lines[...min(end, lines.count - 1)].lastIndex { !Self.isMarkerLine($0.text) }
    }

    /// Index of the active line for a playback position.
    func activeIndex(at time: TimeInterval) -> Int? {
        guard !lines.isEmpty else { return nil }
        var low = 0, high = lines.count - 1, result: Int? = nil
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].time <= time {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }
}

enum LyricsParser {
    /// Spreads a line's time across its characters for a song without word
    /// timing of its own, so the karaoke wipe still runs: each Chinese,
    /// Japanese or Korean character is a word of its own, anything else
    /// splits on whitespace (the gap rides on the word before it), and 85 %
    /// of the line — singing takes most of it, not the pause before the next
    /// line — is shared out by letter count. Nil when there is nothing to
    /// sing, or no time to sing it in.
    static func spreadWords(_ text: String, from start: TimeInterval, to end: TimeInterval) -> [LyricWord]? {
        var units: [String] = []
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            units.append(current)
            current = ""
        }
        for character in text {
            if character.isWhitespace {
                if current.isEmpty, let last = units.indices.last {
                    units[last].append(character)
                } else {
                    current.append(character)
                    if !current.allSatisfy(\.isWhitespace) { flush() }
                }
            } else if isCJK(character) {
                flush()
                units.append(String(character))
            } else {
                current.append(character)
            }
        }
        flush()

        let weights = units.map { $0.filter { $0.isLetter || $0.isNumber }.count }
        let total = weights.reduce(0, +)
        guard total > 0, end > start else { return nil }
        let span = (end - start) * 0.85
        var at = start
        var words: [LyricWord] = []
        for (unit, weight) in zip(units, weights) {
            let duration = span * Double(weight) / Double(total)
            words.append(LyricWord(text: unit, start: at, duration: duration))
            at += duration
        }
        return words
    }

    /// Chinese, Japanese and Korean characters are each sung as a word of
    /// their own.
    private static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        if Kana.isKanji(scalar) || Kana.isKana(scalar) { return true }
        switch scalar.value {
        case 0x1100...0x11FF,   // hangul jamo
             0x3130...0x318F,   // hangul compatibility jamo
             0xA960...0xA97F,   // hangul jamo extended-A
             0xAC00...0xD7AF,   // hangul syllables
             0xD7B0...0xD7FF:   // hangul jamo extended-B
            return true
        default:
            return false
        }
    }
}
