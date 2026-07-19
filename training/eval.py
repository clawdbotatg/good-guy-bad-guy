#!/usr/bin/env python3
"""One-line held-out scorecard from predictions.csv, so experiments compare
cleanly. Reports the numbers that matter for "identify bad guys":
  - exact 12-class accuracy
  - dangerous plants correctly flagged as SOME dangerous class (right family)
  - median confidence on those (are we correct AND confident?)
  - dangerous-called-safe rate at the 0.90 GOOD gate (the lethal error)
"""
import csv
import statistics as st
import sys

BAD = {
    "poison_ivy_eastern", "poison_ivy_western",
    "poison_oak_pacific", "poison_oak_atlantic", "poison_sumac",
}
path = sys.argv[1] if len(sys.argv) > 1 else "training/predictions.csv"
rows = list(csv.DictReader(open(path)))
n = len(rows)
exact = sum(1 for r in rows if r["true"] == r["pred"]) / n * 100

bad = [r for r in rows if r["true"] in BAD]
right_family = [float(r["confidence"]) for r in bad if r["pred"] in BAD]
fam_rate = len(right_family) / len(bad) * 100
med_conf = st.median(right_family) if right_family else 0
# dangerous-called-safe at 0.90 GOOD gate: true BAD, predicted harmless, conf>=0.90
missed = sum(
    1 for r in bad
    if r["pred"] not in BAD and float(r["confidence"]) >= 0.90)
miss_rate = missed / len(bad) * 100

label = sys.argv[2] if len(sys.argv) > 2 else ""
print(
    f"{label:<18} 12-class={exact:5.1f}%  dangerous-family={fam_rate:5.1f}%  "
    f"med-conf={med_conf:.2f}  danger→safe@0.90={miss_rate:.1f}%  (n={n})")
