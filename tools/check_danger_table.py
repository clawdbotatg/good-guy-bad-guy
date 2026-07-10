#!/usr/bin/env python3
"""Regression test for the safety-critical danger table.

The verdict logic in DangerTable.swift is the one part of this app that must
never be wrong, and it is pure data + string matching — so it is testable
without a phone, a GPU, or a model. This script extracts the embedded JSON
from DangerData.swift, checks its invariants, and mirrors the Swift matching
rules over a table of cases that encode real bugs we have already hit.

    python3 tools/check_danger_table.py     # exit 0 = safe to ship

If you change the matcher in DangerTable.swift, change `_verdict` here to
match, and add the case that motivated the change.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "GoodGuyBadGuy" / "LLM" / "DangerData.swift"

# Categories where no match means CAUTION, not safety (mirrors DangerTable).
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


def _pattern(alias):
    """Word-bounded, plural-tolerant — mirrors DangerTable.contains."""
    stem = re.escape(alias)
    body = stem[:-1] + "(?:y|ies)" if alias.endswith("y") else stem + "(?:s|es)?"
    return r"\b" + body + r"\b"


def _best_match(entries, text):
    """Most specific alias wins; severity only breaks ties."""
    best = None  # (entry, specificity)
    for entry in entries:
        lengths = [len(n) for n in entry["names"] if re.search(_pattern(n), text, re.I)]
        if not lengths:
            continue
        longest = max(lengths)
        if best is None:
            best = (entry, longest)
            continue
        more_specific = longest > best[1]
        tie_by_severity = longest == best[1] and SEVERITY[entry["verdict"]] > SEVERITY[best[0]["verdict"]]
        if more_specific or tie_by_severity:
            best = (entry, longest)
    return best


def _verdict(entries, id_line, category, features=""):
    if category == "other" and re.search("not a plant or animal", id_line, re.I):
        return "NONE"
    uncertain = bool(re.search(r"uncertain|not sure|unknown", id_line, re.I))
    best = _best_match(entries, id_line) or _best_match(entries, f"{id_line} {features}")
    if best:
        entry = best[0]
        if uncertain and entry["verdict"] == "good":
            return "CAUTION"
        if category == "mushroom" and entry["verdict"] == "good":
            return "CAUTION"
        return entry["verdict"].upper()
    if uncertain or category in CAUTION_ON_MISS:
        return "CAUTION"
    return "GOOD"


# (identification text, category, expected verdict, why this case exists)
CASES = [
    ("Daylily (Hemerocallis)", "plant", "BAD", "the bug that started this: model called it safe for cats"),
    ("This is a daylily, Lilium (genus)", "plant", "BAD", "model's exact on-device wording"),
    ("Daylilies growing in a bed", "plant", "BAD", "plural must still match"),
    ("Easter lilies in a vase", "plant", "BAD", "plural of a multi-word alias"),
    ("Peace lily (Spathiphyllum)", "plant", "CAUTION", "not a true lily: specificity must beat severity"),
    ("Wolf spider (Lycosidae)", "spider", "GOOD", "must not match the 'wolf' mammal entry"),
    ("Milk snake, a coral snake mimic", "snake", "BAD", "equal specificity ties break toward danger"),
    ("An elephant standing near a plant", "mammal", "GOOD", "'ant' must not fire inside other words"),
    ("Death cap (Amanita phalloides)", "mushroom", "BAD", "deadliest mushroom on earth"),
    ("Some little brown mushroom", "mushroom", "CAUTION", "unmatched mushroom is never GOOD"),
    ("Chanterelle (Cantharellus)", "mushroom", "CAUTION", "wild mushrooms are never GOOD, even edibles"),
    ("Garter snake (Thamnophis sirtalis)", "snake", "GOOD", "common harmless snake"),
    ("Eastern coral snake (Micrurus fulvius)", "snake", "BAD", "neurotoxic"),
    ("Some snake I cannot place", "snake", "CAUTION", "unmatched snake is never GOOD"),
    ("Garter snake (uncertain)", "snake", "CAUTION", "a hedged GOOD is downgraded"),
    ("Black widow (Latrodectus mactans)", "spider", "BAD", "medically significant"),
    ("Brown recluse (Loxosceles reclusa)", "spider", "BAD", "necrotic bite"),
    ("Jumping spider (Salticidae)", "spider", "GOOD", "harmless"),
    ("Ticks on a dog", "insect", "BAD", "disease vector, plural"),
    ("Ladybug (Coccinellidae)", "insect", "GOOD", "harmless"),
    ("Honey bee (Apis mellifera)", "insect", "CAUTION", "sting risk if allergic"),
    ("Sago palm (Cycas revoluta)", "plant", "BAD", "liver failure in dogs"),
    ("Poison ivy (Toxicodendron radicans)", "plant", "BAD", "urushiol"),
    ("Oleander (Nerium oleander)", "plant", "BAD", "cardiac glycosides"),
    ("Water hemlock (Cicuta maculata)", "plant", "BAD", "most poisonous plant in N. America"),
    ("Dandelion (Taraxacum officinale)", "plant", "GOOD", "matched harmless plant"),
    ("Some weed I don't recognize", "plant", "CAUTION", "unmatched plant is never GOOD"),
    ("Fly agaric (Amanita muscaria)", "mushroom", "BAD", "dogs are drawn to them"),
    ("Cane toad (Rhinella marina)", "other", "BAD", "kills dogs that mouth it"),
    ("Gila monster (Heloderma suspectum)", "other", "BAD", "venomous lizard"),
    ("Box turtle (Terrapene)", "other", "GOOD", "matched harmless"),
    ("not a plant or animal", "other", "NONE", "no banner for a photo of a rock"),
    ("Grizzly bear (Ursus arctos)", "mammal", "BAD", "large predator"),
    ("Eastern gray squirrel", "mammal", "GOOD", "unmatched mammal defaults GOOD"),
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
    print(f"{len(aliases)} aliases, {problems} invariant problems")

    failures = 0
    for text, category, want, why in CASES:
        got = _verdict(entries, text, category)
        ok = got == want
        failures += not ok
        status = "ok  " if ok else "FAIL"
        print(f"  {status} [{category:8}] {text!r} -> {got}")
        if not ok:
            print(f"       wanted {want} ({why})")

    total = problems + failures
    print(f"\n{'ALL PASS' if not total else f'{total} PROBLEM(S)'}")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
