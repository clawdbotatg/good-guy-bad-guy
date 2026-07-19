#!/usr/bin/env python3
"""Confidence distribution for truly-dangerous plants, to calibrate the
dangerous-flagging threshold in PlantRoute."""
import csv
import statistics as st

BAD = {
    "poison_ivy_eastern", "poison_ivy_western",
    "poison_oak_pacific", "poison_oak_atlantic", "poison_sumac",
}
rows = list(csv.DictReader(open("training/predictions.csv")))
bad = [r for r in rows if r["true"] in BAD]
right_family = [float(r["confidence"]) for r in bad if r["pred"] in BAD]
missed = [r for r in bad if r["pred"] not in BAD]

print(f"truly-dangerous test images: {len(bad)}")
print(f"  top prediction is SOME dangerous class: {len(right_family)} ({len(right_family)/len(bad)*100:.0f}%)")
print(f"    confidence: median={st.median(right_family):.2f} mean={st.mean(right_family):.2f}")
for t in [0.30, 0.40, 0.50, 0.55, 0.60]:
    n = sum(1 for c in right_family if c >= t)
    print(f"    conf >= {t:.2f}: would flag {n} ({n/len(bad)*100:.0f}% of all dangerous)")
print(f"  top prediction is a HARMLESS class (true miss): {len(missed)} ({len(missed)/len(bad)*100:.0f}%)")
if missed:
    mc = [float(r["confidence"]) for r in missed]
    print(f"    their confidence: median={st.median(mc):.2f}  (mostly low = catchable by a floor)")
