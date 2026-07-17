import Foundation

/// The app's safety authority.
///
/// **The model never decides whether something is dangerous.** A 4-bit 4B VLM
/// is good at *seeing* ("that's a daylily") and bad at *recalling* long-tail
/// facts ("daylilies cause fatal kidney failure in cats" — it confidently got
/// this backwards on device, 2026-07-09). So the model only names what it
/// sees, and the verdict is looked up here, in curated data that ships inside
/// the app and works with zero bars.
///
/// Safety posture, in order:
/// 1. A table hit decides the verdict. The most **specific** alias wins (so
///    "wolf spider" doesn't hit the `wolf` entry), and severity breaks ties
///    toward danger ("milk snake, a coral snake mimic" → BAD GUY).
/// 2. No hit + snake/spider/scorpion/plant/mushroom/other → CAUTION. A small
///    model failing to recognize something is NOT evidence that it is safe.
/// 3. Wild mushrooms are never GOOD GUY. Deadly species have edible twins.
/// 4. A hedged identification downgrades GOOD GUY to CAUTION.
/// 5. If decoding this table ever fails, `entries` is empty and *everything*
///    falls through to the category defaults — i.e. it fails toward CAUTION.
///
/// Adding an entry: put every name the model might say in `names` (common
/// name, genus, species, regional names). Matching is word-boundary and
/// case-insensitive, so short/ambiguous aliases like "ant" are unsafe — use
/// "fire ant". Keep `note` to one or two factual sentences: it is printed
/// verbatim to the user as the authoritative answer.
struct DangerEntry: Decodable {
    let names: [String]
    let category: String
    let verdict: String  // "bad" | "caution" | "good"
    let note: String
}

struct VerdictResult {
    /// `nil` renders no banner (e.g. the photo isn't a plant or animal).
    let verdict: ChatMessage.Verdict?
    /// The `VERDICT:` line plus the authoritative note. The identification is
    /// streamed to the UI separately, before this, by the engine.
    let text: String
}

enum DangerTable {

    /// Categories where failing to match means CAUTION, not safety. `other`
    /// is in here because it catches venomous things that aren't neatly
    /// classified (sea life, amphibians, lizards). Only `insect`, `mammal`,
    /// and `bird` — where the dangerous species are well covered and the
    /// overwhelming majority are harmless — default to GOOD GUY.
    private static let cautionOnMiss: Set<String> = [
        "snake", "spider", "scorpion", "plant", "mushroom", "other",
    ]

    /// The only categories the danger pass may emit; anything else is `other`.
    static let categories: Set<String> = [
        "snake", "spider", "scorpion", "insect", "plant", "mushroom", "mammal", "bird", "other",
    ]

    static let entries: [DangerEntry] = {
        do {
            return try JSONDecoder().decode([DangerEntry].self, from: Data(json.utf8))
        } catch {
            // Fails safe: an empty table sends every category to its default,
            // which is CAUTION for everything that can hurt you.
            DebugLog.log("DangerTable decode FAILED: \(error) — falling back to caution")
            return []
        }
    }()

    // MARK: reading the naming pass

    /// True when the model says the photo has no living thing in it.
    static func isNotAnOrganism(_ reply: String) -> Bool {
        reply.range(of: "not a plant or animal", options: .caseInsensitive) != nil
    }

    /// Pull a usable name out of the naming pass's reply, or nil.
    ///
    /// Rejects the placeholders a 4B model parrots back from a prompt: on
    /// device it once printed "<common name>" as an animal's name, and the
    /// echoed instruction text got matched against the danger table, turning
    /// a harmless cellar spider into a scorpion warning (2026-07-09).
    static func sanitizeName(_ reply: String) -> String? {
        guard let line = firstMeaningfulLine(reply), line.count <= 60 else { return nil }
        if line.range(of: "unknown", options: .caseInsensitive) != nil { return nil }
        return displayName(line)
    }

    /// The reply as danger-table matching input: echoed template lines
    /// dropped, everything else kept.
    ///
    /// The naming pass asks for "the name only", but a 4-bit 4B model often
    /// captions instead: "This is a close-up photograph of a **spitting
    /// cobra** (likely *Naja* species…". Rejecting that reply for not being a
    /// clean name is how all three of App Review's scans (cobra, snake,
    /// jumping spider — iPad, 2026-07-16) came back "couldn't identify" while
    /// the species sat right there in the text. Matching is word-boundary
    /// over the whole reply, so the caption is perfectly good input.
    static func matchText(_ reply: String) -> String? {
        let text = stripEchoedTemplate(reply)
        return text.isEmpty ? nil : text
    }

    /// Display name when the reply wasn't a clean short answer: the alias the
    /// caption's best table match fired on. Never model prose — always one of
    /// our own curated names.
    static func matchedName(in reply: String) -> String? {
        guard let text = matchText(reply), let best = bestMatch(in: text) else { return nil }
        let alias =
            best.entry.names
            .filter { contains(text, word: $0) }
            .max(by: { $0.count < $1.count }) ?? best.entry.names[0]
        return alias.prefix(1).uppercased() + alias.dropFirst()
    }

    /// True when the model hedged its identification.
    static func isHedged(_ reply: String) -> Bool {
        ["uncertain", "not sure", "unknown", "possibly", "might be"].contains {
            reply.range(of: $0, options: .caseInsensitive) != nil
        }
    }

    /// The table entry a name resolves to, if any. Used by the engine to skip
    /// the category pass when the species is already known.
    static func lookup(name: String) -> DangerEntry? {
        bestMatch(in: name)?.entry
    }

    // MARK: verdict

    /// Decide the verdict for an identified organism. `category` only matters
    /// when the name isn't in the table — it selects the safe default.
    static func verdict(name: String?, category: String?, hedged: Bool = false) -> VerdictResult {
        let category = categories.contains(category ?? "") ? category! : "other"

        // Without a name we have nothing to look up, and we will not guess.
        guard let name else {
            return compose(
                .caution,
                "I couldn't identify what's in the photo, so I can't tell you whether it's safe. Try again with better light, and the creature filling more of the frame. Until then treat it as unknown: keep your distance, and don't touch or eat it."
            )
        }

        // Dangerous look-alike: the ID names BOTH a dangerous species and a
        // harmless one (e.g. "coral snake or scarlet kingsnake" — a real
        // venomous coral snake was called GOOD until this rule existed). A
        // photo can't resolve it, so the safe answer is CAUTION naming the
        // dangerous candidate. Never let the harmless mimic win on specificity.
        let matches = allMatches(in: name)
        if isAmbiguous(name),
            matches.contains(where: { $0.verdict == "bad" }),
            matches.contains(where: { $0.verdict == "good" }),
            let bad = matches.first(where: { $0.verdict == "bad" })
        {
            let dangerName = bad.names
                .filter { contains(name, word: $0) }
                .max(by: { $0.count < $1.count }) ?? bad.names[0]
            return compose(
                .caution,
                "Could be a \(dangerName) (dangerous) or a harmless look-alike — a photo can't tell them apart. Keep your distance and don't touch it."
            )
        }

        if let best = lookup(name: name) {
            // A confirmed dangerous match still stands when the model hedged;
            // but a hedged GOOD GUY is downgraded — we may be looking at the
            // wrong species entirely.
            if hedged, best.verdict == "good" {
                return compose(
                    .caution,
                    "The model isn't confident. This resembles \(best.names[0]), which is harmless, but that's not certain enough to call it safe — keep your distance and don't touch it."
                )
            }
            // Wild mushrooms are never GOOD GUY, even on a match.
            if best.category == "mushroom" || category == "mushroom", best.verdict == "good" {
                return compose(
                    .caution,
                    "\(best.note) Even so: never eat a wild mushroom on a photo ID — deadly species have edible look-alikes."
                )
            }
            return compose(uiVerdict(best.verdict), best.note)
        }

        // No match. Silence from a small model is not safety.
        if category == "mushroom" {
            return compose(
                .caution,
                "I can't match this to a species I know. Never eat a wild mushroom identified from a photo — the deadly ones have edible look-alikes, and the difference can be invisible."
            )
        }
        if hedged || cautionOnMiss.contains(category) {
            return compose(
                .caution,
                "I couldn't match this to my danger list, so I can't confirm it's safe. Treat it as unknown: keep your distance, and don't touch or eat it."
            )
        }
        return compose(
            .goodGuy,
            "No match in my danger list, and nothing in this category is typically harmful. I can't be certain, so still don't handle it."
        )
    }

    private static func compose(_ verdict: ChatMessage.Verdict, _ note: String) -> VerdictResult {
        let label =
            switch verdict {
            case .goodGuy: "GOOD GUY"
            case .badGuy: "BAD GUY"
            case .caution: "CAUTION"
            }
        return VerdictResult(verdict: verdict, text: "VERDICT: \(label)\n\n\(note)")
    }

    private static func uiVerdict(_ raw: String) -> ChatMessage.Verdict {
        switch raw {
        case "bad": .badGuy
        case "good": .goodGuy
        default: .caution
        }
    }

    private static func severity(_ verdict: String) -> Int {
        switch verdict {
        case "bad": 2
        case "caution": 1
        default: 0
        }
    }

    // MARK: matching

    /// The **most specific** alias wins, and severity only breaks ties.
    ///
    /// Severity-first would be wrong in both directions: "wolf spider" would
    /// hit the `wolf` entry and warn about a large predator, and "peace lily"
    /// would hit the `lily` entry and claim a kidney-failure risk it doesn't
    /// have. Specificity-first keeps the safety bias where it belongs: a name
    /// citing two species of equal specificity ("milk snake, a coral snake
    /// mimic") still resolves to the dangerous one.
    /// Every entry whose alias appears in the text (used for look-alike
    /// conflict detection).
    private static func allMatches(in text: String) -> [DangerEntry] {
        entries.filter { entry in entry.names.contains { contains(text, word: $0) } }
    }

    /// Whether the text names alternatives ("coral snake OR scarlet kingsnake")
    /// rather than one species that merely contains a shared word ("wolf
    /// spider"). Only then is a bad+good match a genuine look-alike.
    private static func isAmbiguous(_ text: String) -> Bool {
        let lower = text.lowercased()
        // Whole-word markers.
        let words = ["or", "possibly", "mimic", "either", "vs", "uncertain"]
        if words.contains(where: {
            lower.range(of: "\\b\($0)\\b", options: .regularExpression) != nil
        }) { return true }
        // Substring markers (phrases / punctuation).
        let phrases = ["look-alike", "lookalike", "could be", "not sure", "/", "?"]
        return phrases.contains { lower.contains($0) }
    }

    private static func bestMatch(in text: String) -> (entry: DangerEntry, specificity: Int)? {
        var best: (entry: DangerEntry, specificity: Int)?
        for entry in entries {
            let longest = entry.names
                .filter { contains(text, word: $0) }
                .map(\.count).max()
            guard let longest else { continue }
            guard let current = best else {
                best = (entry, longest)
                continue
            }
            let moreSpecific = longest > current.specificity
            let tieBrokenBySeverity =
                longest == current.specificity
                && severity(entry.verdict) > severity(current.entry.verdict)
            if moreSpecific || tieBrokenBySeverity { best = (entry, longest) }
        }
        return best
    }

    /// Whole-word, case-insensitive containment, tolerant of plurals.
    ///
    /// Substring matching would let "ant" fire on "plant" and "elephant", so
    /// the match is word-bounded. But a bare `\blily\b` misses "lilies" and
    /// "daylilies" — and a missed lily is a dead cat — so each alias also
    /// matches its regular plural forms.
    private static func contains(_ haystack: String, word: String) -> Bool {
        let stem = NSRegularExpression.escapedPattern(for: word)
        // lily → lil(y|ies); bush → bush(es); tick → tick(s)
        let body =
            word.hasSuffix("y")
            ? String(stem.dropLast()) + "(?:y|ies)"
            : stem + "(?:s|es)?"
        guard
            let regex = try? NSRegularExpression(
                pattern: "\\b" + body + "\\b", options: [.caseInsensitive])
        else { return false }
        let range = NSRange(haystack.startIndex..., in: haystack)
        return regex.firstMatch(in: haystack, range: range) != nil
    }

    // MARK: text hygiene

    /// First non-empty line, stripped of the quotes, bullets, labels, and
    /// trailing punctuation a small model wraps a bare answer in.
    static func firstMeaningfulLine(_ text: String) -> String? {
        for line in stripEchoedTemplate(text).split(separator: "\n") {
            var trimmed = line.trimmingCharacters(
                in: CharacterSet(charactersIn: " \t*-#•>\"'.,;:"))
            // "Answer: Leopard gecko" / "ID: Leopard gecko" → "Leopard gecko"
            for label in ["answer", "id", "name", "it is", "this is a", "this is"] {
                if trimmed.lowercased().hasPrefix(label + ":")
                    || trimmed.lowercased().hasPrefix(label + " ")
                {
                    trimmed = String(trimmed.dropFirst(label.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t:*"))
                }
            }
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Drop any line that is a prompt template rather than an answer:
    /// placeholders carry angle brackets, and list instructions read "one of:".
    private static func stripEchoedTemplate(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                !line.contains("<") && !line.contains(">")
                    && line.range(of: "one of:", options: .caseInsensitive) == nil
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips the hedge and rejects a parroted placeholder, which must never
    /// be shown to the user as an identification or fed to the matcher.
    private static func displayName(_ id: String?) -> String? {
        guard var name = id?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return nil
        }
        let isPlaceholder =
            name.contains("<") || name.contains(">")
            || name.range(of: "common name", options: .caseInsensitive) != nil
            || name.range(of: "scientific name", options: .caseInsensitive) != nil
        guard !isPlaceholder else { return nil }

        for hedge in ["(uncertain)", "(not sure)", "(unknown)"] {
            name = name.replacingOccurrences(
                of: hedge, with: "", options: .caseInsensitive)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
        return name.isEmpty ? nil : name
    }
}
