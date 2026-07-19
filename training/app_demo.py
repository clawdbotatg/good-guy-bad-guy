#!/usr/bin/env python3
"""
Run the SHIPPED Core ML model on held-out test photos and reproduce exactly
what the app would show — the ID line + GOOD GUY / BAD GUY / CAUTION verdict,
using the same PlantRoute thresholds as ClassifierEngine.swift.
"""
import os, glob, shutil, sys
import coremltools as ct
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
OUTDIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "demo_shots")
os.makedirs(OUTDIR, exist_ok=True)

MODEL = os.path.join(HERE, "..", "GoodGuyBadGuy", "Resources", "PoisonIvyBioCLIP.mlpackage")
m = ct.models.MLModel(MODEL)
inp = m.get_spec().description.input[0].name

# slug -> (common name, dangerous?) — mirrors PlantClassifier.labelMap
MAP = {
    "poison_ivy_eastern": ("poison ivy", True), "poison_ivy_western": ("poison ivy", True),
    "poison_oak_pacific": ("poison oak", True), "poison_oak_atlantic": ("poison oak", True),
    "poison_sumac": ("poison sumac", True),
    "virginia_creeper": ("virginia creeper", False), "box_elder": ("box elder", False),
    "brambles": ("bramble", False), "fragrant_sumac": ("fragrant sumac", False),
    "staghorn_sumac": ("staghorn sumac", False), "jack_in_the_pulpit": ("jack-in-the-pulpit", False),
    "hog_peanut": ("hog peanut", False),
}
# thresholds from PlantRoute
DANGER_FLAG, GOOD, HEDGE = 0.40, 0.75, 0.50


def crop224(im):
    im = im.convert("RGB"); w, h = im.size; s = 224 / min(w, h)
    im = im.resize((round(w*s), round(h*s)), Image.BICUBIC)
    w, h = im.size; l, t = (w-224)//2, (h-224)//2
    return im.crop((l, t, l+224, t+224))


def verdict(slug, conf):
    name, bad = MAP[slug]
    if bad:
        return (f"BAD GUY", name) if conf >= DANGER_FLAG else ("CAUTION", f"possibly {name}")
    if conf >= GOOD:
        return ("GOOD GUY", name)
    if conf >= HEDGE:
        return ("CAUTION", f"{name} (unsure)")
    return ("CAUTION", "not sure")


# A spread across classes — dangerous + look-alikes, held-out, deterministic.
picks = []
for slug in ["poison_ivy_eastern", "poison_oak_pacific", "poison_sumac",
             "virginia_creeper", "box_elder", "brambles", "jack_in_the_pulpit",
             "staghorn_sumac"]:
    fs = sorted(glob.glob(os.path.join(HERE, "testset", slug, "*.jpg")))
    for f in (fs[0], fs[len(fs)//2]):   # two per class
        picks.append((slug, f))

print(f"{'PHOTO OF':<20}{'APP SAYS':<26}{'VERDICT':<10}{'conf':>6}  {'right?':>6}")
print("-" * 74)
for i, (slug, path) in enumerate(picks):
    out = m.predict({inp: crop224(Image.open(path))})
    probs = next(v for v in out.values() if isinstance(v, dict))
    top = max(probs, key=probs.get); conf = probs[top]
    v, idline = verdict(top, conf)
    truth_name, truth_bad = MAP[slug]
    # "right" = verdict matches whether the TRUE plant is dangerous
    ok = (v == "BAD GUY") == truth_bad or v == "CAUTION"
    dest = os.path.join(OUTDIR, f"{i:02d}_{slug}_{v.replace(' ','')}.jpg")
    shutil.copy(path, dest)
    print(f"{truth_name:<20}{('ID: '+idline):<26}{v:<10}{conf:>6.2f}  {'ok' if ok else 'MISS':>6}")
print(f"\nimages copied to {OUTDIR}")
