import Foundation

/// The app's safety authority.
///
/// **The model never decides whether something is dangerous.** A 4-bit 4B VLM
/// is good at *seeing* ("that's a daylily") and bad at *recalling* long-tail
/// facts ("daylilies cause fatal kidney failure in cats" — it confidently got
/// this backwards on device, 2026-07-09). So the model only produces an
/// identification, and the verdict is looked up here, in curated data that
/// ships inside the app and works with zero bars.
///
/// Safety posture, in order:
/// 1. A table hit decides the verdict. Most severe match wins (a photo whose
///    text mentions both "king snake" and "coral snake" errs toward danger).
/// 2. No hit + snake/spider/scorpion/plant/mushroom → CAUTION. A small model
///    failing to recognize something is NOT evidence that it is safe.
/// 3. Wild mushrooms are never GOOD GUY. Deadly species have edible twins.
/// 4. If decoding this table ever fails, `entries` is empty and *everything*
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
    /// Full display text, including the leading `VERDICT:` line when present.
    let text: String
}

enum DangerTable {

    /// Categories where failing to match means CAUTION, not safety. `other`
    /// is in here because it catches venomous things that aren't neatly
    /// classified (sea life, amphibians, lizards). Only `insect`, `mammal`,
    /// and `bird` — where the dangerous species are well covered above and
    /// the overwhelming majority are harmless — default to GOOD GUY.
    private static let cautionOnMiss: Set<String> = [
        "snake", "spider", "scorpion", "plant", "mushroom", "other",
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

    // MARK: verdict

    /// Turn the identify stage's raw text into a verdict the app can stand behind.
    static func verdict(modelText: String) -> VerdictResult {
        let parsed = parse(modelText)
        let category = parsed.category ?? "other"
        let idLine = parsed.id ?? modelText

        // Nothing living in frame: answer plainly, no banner.
        if category == "other",
            idLine.range(of: "not a plant or animal", options: .caseInsensitive) != nil
        {
            return VerdictResult(
                verdict: nil,
                text:
                    "That doesn't look like a plant or animal. Point the camera at the creature, plant, or mushroom you want checked."
            )
        }

        // Prefer the ID line; fall back to the whole reply, since the name
        // sometimes lands in FEATURES instead.
        let haystack = [parsed.id, parsed.features, modelText]
            .compactMap { $0 }.joined(separator: " ")
        let best = bestMatch(in: idLine)?.entry ?? bestMatch(in: haystack)?.entry

        let name = displayName(parsed.id) ?? "This"
        let uncertain =
            idLine.range(of: "uncertain", options: .caseInsensitive) != nil
            || idLine.range(of: "not sure", options: .caseInsensitive) != nil
            || idLine.range(of: "unknown", options: .caseInsensitive) != nil

        if let best {
            // A confirmed dangerous match still stands when the model hedged;
            // but a hedged GOOD GUY is downgraded — we may be looking at the
            // wrong species entirely.
            if uncertain, best.verdict == "good" {
                return compose(
                    .caution, name,
                    "I can't identify this confidently. It resembles \(best.names[0]), which is harmless, but I'm not sure enough to say so — keep your distance and don't touch it."
                )
            }
            // Wild mushrooms are never GOOD GUY, even on a match.
            if category == "mushroom", best.verdict == "good" {
                return compose(
                    .caution, name,
                    "\(best.note) Even so: never eat a wild mushroom on a photo ID — deadly species have edible look-alikes."
                )
            }
            return compose(uiVerdict(best.verdict), name, best.note)
        }

        // No match. Silence from a small model is not safety.
        if uncertain || cautionOnMiss.contains(category) {
            return compose(
                .caution, name,
                "I couldn't match this to my danger list, so I can't confirm it's safe. Treat it as unknown: keep your distance, and don't touch or eat it."
            )
        }
        return compose(
            .goodGuy, name,
            "No match in my danger list, and nothing about this category is typically harmful. I can't be certain, so still don't handle it."
        )
    }

    /// The **most specific** alias wins, and severity only breaks ties.
    ///
    /// Severity-first would be wrong in both directions: "wolf spider" would
    /// hit the `wolf` entry and warn about a large predator, and "peace lily"
    /// would hit the `lily` entry and claim a kidney-failure risk it doesn't
    /// have. Specificity-first keeps the safety bias where it belongs: an ID
    /// naming two species of equal specificity ("milk snake, a coral snake
    /// mimic") still resolves to the dangerous one.
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

    private static func compose(
        _ verdict: ChatMessage.Verdict, _ name: String, _ note: String
    ) -> VerdictResult {
        let label =
            switch verdict {
            case .goodGuy: "GOOD GUY"
            case .badGuy: "BAD GUY"
            case .caution: "CAUTION"
            }
        return VerdictResult(
            verdict: verdict, text: "VERDICT: \(label)\n\n\(name). \(note)")
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

    // MARK: parsing the identify stage

    /// The identify prompt asks for `CATEGORY:` / `ID:` / `FEATURES:` lines,
    /// but a 4B model drifts, so every field is optional and the whole reply
    /// is searched as a fallback.
    static func parse(_ text: String) -> (category: String?, id: String?, features: String?) {
        var category: String?
        var id: String?
        var features: String?
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = value(of: "CATEGORY", in: trimmed) {
                category = value.lowercased().trimmingCharacters(
                    in: CharacterSet.letters.inverted)
            } else if let value = value(of: "ID", in: trimmed) {
                id = value
            } else if let value = value(of: "FEATURES", in: trimmed) {
                features = value
            }
        }
        return (category, id, features)
    }

    private static func value(of key: String, in line: String) -> String? {
        guard line.lowercased().hasPrefix(key.lowercased() + ":") else { return nil }
        return String(line.dropFirst(key.count + 1))
            .trimmingCharacters(in: .whitespaces)
    }

    /// "Daylily (Hemerocallis) (uncertain)" → "Daylily (Hemerocallis)"
    private static func displayName(_ id: String?) -> String? {
        guard var name = id?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            return nil
        }
        for hedge in ["(uncertain)", "(not sure)", "(unknown)"] {
            name = name.replacingOccurrences(
                of: hedge, with: "", options: .caseInsensitive)
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " .,;"))
        return name.isEmpty ? nil : name
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
}
