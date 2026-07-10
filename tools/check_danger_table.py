#!/usr/bin/env python3
"""Regression test for the safety-critical verdict logic.

`DangerTable.verdict(name:category:hedged:)` is the one part of this app that
must never be wrong, and it is pure data + string matching — so it is testable
without a phone, a GPU, or a model. This script extracts the embedded JSON from
DangerData.swift, checks its invariants, and mirrors the Swift matching rules
over cases that encode bugs we have actually shipped.

    python3 tools/check_danger_table.py     # exit 0 = safe to ship

The app takes a photo through two minimal model passes — "what is this?" then
(only if the name is unknown) "one word: what category?" — and everything
after that is the logic mirrored here. If you change DangerTable.swift, change
the mirror below to match, and add the case that motivated the change.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "GoodGuyBadGuy" / "LLM" / "DangerData.swift"

CATEGORIES = {"snake", "spider", "scorpion", "insect", "plant", "mushroom", "mammal", "bird", "other"}
# Categories where no match means CAUTION, not safety.
CAUTION_ON_MISS = {"snake", "spider", "scorpion", "plant", "mushroom", "other"}
SEVERITY = {"bad": 2, "caution": 1, "good": 0}


def load_entries():
    src = DATA.read_text()
    m = re.search(r'static let json = """\n(.*?)\n        """', src, re.S)
    if not m:
        sys.exit(f"could not find the JSON literal in {DATA}")
    # Swift strips the closing delimiter's indentation from every line.
    lines = [l[8:] if l.startswith(" " * 8) else l for l in m.group(1).split("\n")]
    return json.loads("\n".join(lines))


# --- mirror of DangerTable.swift ------------------------------------------


def sanitize_name(reply):
    """Mirrors sanitizeName + displayName: rejects placeholders and 'unknown'."""
    line = reply.strip().split("\n")[0].strip(" \t*-#•>\"'.,;:")
    if not line or len(line) > 60:
        return None
    if re.search(r"unknown", line, re.I):
        return None
    if "<" in line or ">" in line:
        return None
    if re.search(r"common name|scientific name", line, re.I):
        return None
    name = re.sub(r"\((?:uncertain|not sure|unknown)\)", "", line, flags=re.I).strip(" .,;")
    return name or None


def is_hedged(reply):
    return bool(re.search(r"uncertain|not sure|unknown|possibly|might be", reply, re.I))


def _pattern(alias):
    """Word-bounded, plural-tolerant — mirrors DangerTable.contains."""
    stem = re.escape(alias)
    body = stem[:-1] + "(?:y|ies)" if alias.endswith("y") else stem + "(?:s|es)?"
    return r"\b" + body + r"\b"


def lookup(entries, name):
    """Most specific alias wins; severity only breaks ties."""
    best = None  # (entry, specificity)
    for entry in entries:
        lengths = [len(n) for n in entry["names"] if re.search(_pattern(n), name, re.I)]
        if not lengths:
            continue
        longest = max(lengths)
        if best is None:
            best = (entry, longest)
            continue
        more_specific = longest > best[1]
        tie_by_severity = (
            longest == best[1] and SEVERITY[entry["verdict"]] > SEVERITY[best[0]["verdict"]]
        )
        if more_specific or tie_by_severity:
            best = (entry, longest)
    return best[0] if best else None


def all_matches(entries, name):
    return [e for e in entries if any(re.search(_pattern(n), name, re.I) for n in e["names"])]


_AMBIGUOUS_RE = re.compile(
    r"\bor\b|/|possibly|mimic|look[- ]?alike|either|\bvs\b|could be|not sure|uncertain|\?",
    re.I,
)


def verdict(entries, name, category=None, hedged=False):
    category = category if category in CATEGORIES else "other"
    if not name:
        return "CAUTION"
    # Dangerous look-alike: the ID names alternatives ("X or Y"), one dangerous
    # and one harmless. Not "wolf spider" (one species containing "wolf").
    if _AMBIGUOUS_RE.search(name):
        present = {m["verdict"] for m in all_matches(entries, name)}
        if "bad" in present and "good" in present:
            return "CAUTION"
    best = lookup(entries, name)
    if best:
        if hedged and best["verdict"] == "good":
            return "CAUTION"
        if (best["category"] == "mushroom" or category == "mushroom") and best["verdict"] == "good":
            return "CAUTION"
        return best["verdict"].upper()
    if category == "mushroom":
        return "CAUTION"
    if hedged or category in CAUTION_ON_MISS:
        return "CAUTION"
    return "GOOD"


def pipeline(entries, raw_name, category=None):
    """The whole post-model path: sanitize the naming pass, then judge."""
    if re.search("not a plant or animal", raw_name, re.I):
        return "NONE"
    return verdict(entries, sanitize_name(raw_name), category, is_hedged(raw_name))


# (raw naming-pass reply, category from pass 2 (or None), expected, why)
CASES = [
    ("Daylily", "plant", "BAD", "the bug that started this: model called it safe for cats"),
    ("Daylily (Hemerocallis)", "plant", "BAD", "scientific name in parens"),
    ("Daylilies", "plant", "BAD", "plural must still match"),
    ("Easter lilies", "plant", "BAD", "plural of a multi-word alias"),
    ("Peace lily", "plant", "CAUTION", "not a true lily: specificity must beat severity"),
    ("Wolf spider", "spider", "GOOD", "must not match the 'wolf' mammal entry"),
    # THE look-alike test: a real venomous coral snake photo made the model
    # say "coral snake or scarlet kingsnake" and the table called it GOOD GUY.
    # Naming a deadly species and its harmless mimic must be CAUTION, never GOOD.
    ("coral snake or scarlet kingsnake (Micrurus sp. or Lampropeltis elapsoides)", "snake",
     "CAUTION", "flagship: deadly species + harmless mimic -> caution, never good"),
    ("Milk snake, a coral snake mimic", "snake", "CAUTION",
     "look-alike: dangerous + harmless candidates -> caution, name the dangerous one"),
    ("Eastern coral snake (Micrurus fulvius)", "snake", "BAD",
     "an unambiguous coral snake is still BAD"),
    ("Scarlet kingsnake (Lampropeltis elapsoides)", "snake", "GOOD",
     "an unambiguous harmless mimic is GOOD"),
    ("Elephant near a plant", "mammal", "GOOD", "'ant' must not fire inside other words"),

    # Naming-pass hygiene (the model parroting or hedging).
    ("<common name>", "other", "CAUTION", "parroted placeholder is never a name"),
    ("unknown", "spider", "CAUTION", "model admits it can't tell"),
    ("Garter snake (uncertain)", "snake", "CAUTION", "a hedged GOOD is downgraded"),
    ("Fly agaric (uncertain)", "mushroom", "BAD", "hedging never rescues a dangerous species"),
    ("not a plant or animal", None, "NONE", "no banner for a photo of a rock"),

    # The two subjects from the device screenshots.
    ("Cellar spider", "spider", "GOOD", "harmless; was wrongly called a scorpion"),
    ("Leopard gecko", "other", "GOOD", "was showing the literal name 'This'"),

    # Category defaults when the name is unknown to the table.
    ("Some little brown mushroom", "mushroom", "CAUTION", "unmatched mushroom is never GOOD"),
    ("Chanterelle", "mushroom", "CAUTION", "wild mushrooms are never GOOD, even edibles"),
    ("Some snake I cannot place", "snake", "CAUTION", "unmatched snake is never GOOD"),
    ("A weed of some kind", "plant", "CAUTION", "unmatched plant is never GOOD"),
    ("Small brown bird", "bird", "GOOD", "unmatched bird defaults GOOD"),
    ("Eastern gray squirrel", "mammal", "GOOD", "unmatched mammal defaults GOOD"),
    ("Some little beetle", "insect", "GOOD", "unmatched insect defaults GOOD"),
    ("Weird sea creature", "other", "CAUTION", "unmatched 'other' is never GOOD"),

    # Known species (category comes from the table, so pass 2 never runs).
    ("Death cap", None, "BAD", "deadliest mushroom on earth"),
    ("Garter snake", None, "GOOD", "harmless snake"),
    ("Eastern coral snake", None, "BAD", "neurotoxic"),
    ("Black widow", None, "BAD", "medically significant"),
    ("Brown recluse", None, "BAD", "necrotic bite"),
    ("Jumping spider", None, "GOOD", "harmless"),
    ("Ticks", None, "BAD", "disease vector, plural"),
    ("Ladybug", None, "GOOD", "harmless"),
    ("Honey bee", None, "CAUTION", "sting risk if allergic"),
    ("Sago palm", None, "BAD", "liver failure in dogs"),
    ("Poison ivy", None, "BAD", "urushiol"),
    ("Oleander", None, "BAD", "cardiac glycosides"),
    ("Water hemlock", None, "BAD", "most poisonous plant in N. America"),
    ("Dandelion", None, "GOOD", "matched harmless plant"),
    ("Fly agaric", None, "BAD", "dogs are drawn to them"),
    ("Cane toad", None, "BAD", "kills dogs that mouth it"),
    ("Gila monster", None, "BAD", "venomous lizard"),
    ("Box turtle", None, "GOOD", "matched harmless"),
    ("Grizzly bear", None, "BAD", "large predator"),
    # A table entry whose category is mushroom must never be GOOD even if the
    # danger pass mislabels the category.
    ("Chanterelle", "plant", "CAUTION", "mushroom rule keys off the entry, not just the pass"),
]


def main():
    entries = load_entries()
    print(f"{len(entries)} entries decode OK")

    aliases, problems = {}, 0
    for entry in entries:
        if entry["verdict"] not in SEVERITY:
            print(f"  BAD VERDICT {entry['verdict']!r} in {entry['names'][0]}")
            problems += 1
        if not entry["note"].strip():
            print(f"  EMPTY NOTE in {entry['names'][0]}")
            problems += 1
        if entry["category"] not in CATEGORIES:
            print(f"  UNKNOWN CATEGORY {entry['category']!r} in {entry['names'][0]}")
            problems += 1
        for name in entry["names"]:
            if name != name.lower():
                print(f"  ALIAS NOT LOWERCASE: {name!r}")
                problems += 1
            if len(name) < 3:
                print(f"  ALIAS TOO SHORT (false-match risk): {name!r}")
                problems += 1
            if name in aliases:
                print(f"  DUPLICATE ALIAS {name!r}: {aliases[name]} vs {entry['names'][0]}")
                problems += 1
            aliases[name] = entry["names"][0]
    print(f"{len(aliases)} aliases, {problems} invariant problems\n")

    failures = 0
    for raw_name, category, want, why in CASES:
        got = pipeline(entries, raw_name, category)
        ok = got == want
        failures += not ok
        print(f"  {'ok  ' if ok else 'FAIL'} {got:8} {raw_name!r} [{category}]")
        if not ok:
            print(f"       wanted {want} ({why})")

    total = problems + failures
    print(f"\n{'ALL PASS' if not total else f'{total} PROBLEM(S)'}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
