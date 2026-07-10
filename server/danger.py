"""Server-side danger verdict — the same authority the app uses.

The one rule of this project: **a model never decides whether something is
dangerous.** The classifier (claude -p, or a fallback vision model) only
*names* the organism; the verdict comes from the curated danger list. That
list lives in the app's `DangerData.swift`, and this module reads it directly
so the server and the app can never drift apart.

Matching mirrors `DangerTable.swift`: whole-word, plural-tolerant, most
specific alias wins, severity breaks ties toward danger.
"""
import os
import re

_SWIFT = os.path.join(
    os.path.dirname(__file__), "..", "GoodGuyBadGuy", "LLM", "DangerData.swift"
)

CATEGORIES = {
    "snake", "spider", "scorpion", "insect", "plant", "mushroom", "mammal", "bird", "other",
}
# Categories where "no match" means CAUTION, not safety.
CAUTION_ON_MISS = {"snake", "spider", "scorpion", "plant", "mushroom", "other"}
SEVERITY = {"bad": 2, "caution": 1, "good": 0}


def _load_entries():
    """Extract the embedded JSON array from DangerData.swift."""
    import json

    src = open(_SWIFT, encoding="utf-8").read()
    m = re.search(r'static let json = """\n(.*?)\n        """', src, re.S)
    if not m:
        raise RuntimeError("could not find the danger JSON literal in DangerData.swift")
    # Swift strips the closing delimiter's indentation from every line.
    lines = [l[8:] if l.startswith(" " * 8) else l for l in m.group(1).split("\n")]
    return json.loads("\n".join(lines))


ENTRIES = _load_entries()


def _pattern(alias):
    """Word-bounded, plural-tolerant — mirrors DangerTable.contains."""
    stem = re.escape(alias)
    body = stem[:-1] + "(?:y|ies)" if alias.endswith("y") else stem + "(?:s|es)?"
    return r"\b" + body + r"\b"


def lookup(name):
    """The entry a name resolves to. Most specific alias wins; severity ties."""
    if not name:
        return None
    best = None  # (entry, specificity)
    for entry in ENTRIES:
        lengths = [len(n) for n in entry["names"] if re.search(_pattern(n), name, re.I)]
        if not lengths:
            continue
        longest = max(lengths)
        if best is None or longest > best[1] or (
            longest == best[1]
            and SEVERITY[entry["verdict"]] > SEVERITY[best[0]["verdict"]]
        ):
            best = (entry, longest)
    return best[0] if best else None


def resolve(name, category, model_verdict=None, model_note=None, hedged=False):
    """Decide the final (verdict, note, source).

    A curated table hit is authoritative and overrides the model. Otherwise we
    trust the naming model's own verdict (it is a frontier model, far more
    reliable on toxicology than the on-device 4B), with a few safety clamps.
    Returns (verdict, note, source) where source is "table" or "model".
    """
    category = category if category in CATEGORIES else "other"

    entry = lookup(name)
    if entry:
        verdict, note = entry["verdict"], entry["note"]
        # Wild mushrooms are never GOOD GUY, even on a match.
        if category == "mushroom" and verdict == "good":
            verdict = "caution"
            note = note + " Even so: never eat a wild mushroom on a photo ID."
        # A hedged identification downgrades a GOOD to CAUTION.
        if hedged and verdict == "good":
            verdict = "caution"
        return verdict, note, "table"

    # No table entry: trust the model's verdict, with clamps.
    verdict = model_verdict if model_verdict in SEVERITY else "caution"
    note = (model_note or "").strip() or (
        "I couldn't match this to my danger list. Treat it as unknown — keep "
        "your distance and don't touch or eat it."
    )
    if category == "mushroom" and verdict == "good":
        verdict = "caution"
        note = "Never eat a wild mushroom identified from a photo — deadly species have edible look-alikes. " + note
    elif verdict == "good" and (hedged or category in CAUTION_ON_MISS):
        # A confident model may still call an unknown snake/spider/etc "good";
        # without a curated confirmation we hold it at caution.
        if hedged:
            verdict = "caution"
    return verdict, note, "model"
