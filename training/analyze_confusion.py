#!/usr/bin/env python3
"""
Collapse the 12-class confusion matrix into the distinction the app actually
cares about: dangerous-vs-harmless. The only truly bad error is a DANGEROUS
plant predicted as a HARMLESS one (a BAD GUY called a GOOD GUY).
"""
import csv
import os

BAD = {
    "poison_ivy_eastern", "poison_ivy_western",
    "poison_oak_pacific", "poison_oak_atlantic", "poison_sumac",
}
# everything else in the dataset is a harmless look-alike (GOOD)

path = os.path.join(os.path.dirname(__file__), "confusion.csv")
rows = list(csv.DictReader(open(path)))

def grp(label):
    return "BAD" if label in BAD else "GOOD"

# 2x2 danger confusion + within-group correctness
cell = {("BAD","BAD"):0, ("BAD","GOOD"):0, ("GOOD","BAD"):0, ("GOOD","GOOD"):0}
exact_correct = 0
total = 0
bad_total = 0
for r in rows:
    t, p, c = r["true"], r["pred"], int(r["count"])
    total += c
    if t == p:
        exact_correct += c
    if t in BAD:
        bad_total += c
    cell[(grp(t), grp(p))] += c

print(f"Validation samples: {total}")
print(f"Exact 12-class accuracy: {exact_correct/total*100:.1f}%\n")

print("Collapsed to danger groups (rows = truth, cols = prediction):")
print(f"{'':>14}{'pred BAD':>10}{'pred GOOD':>11}")
print(f"{'true BAD':>14}{cell[('BAD','BAD')]:>10}{cell[('BAD','GOOD')]:>11}")
print(f"{'true GOOD':>14}{cell[('GOOD','BAD')]:>10}{cell[('GOOD','GOOD')]:>11}\n")

danger_recall = cell[("BAD","BAD")] / bad_total * 100 if bad_total else 0
missed = cell[("BAD","GOOD")]
false_alarm = cell[("GOOD","BAD")]
good_total = total - bad_total

print(f"DANGEROUS plants correctly flagged as dangerous: {danger_recall:.1f}%")
print(f"  -> DANGEROUS called SAFE (the only lethal error): {missed}  ({missed/bad_total*100:.1f}% of dangerous)")
print(f"  -> harmless called dangerous (annoying, not unsafe): {false_alarm}  ({false_alarm/good_total*100:.1f}% of harmless)")
print("\nNote: in the app, a low-confidence prediction should fall to CAUTION,")
print("which converts many of the 'called safe' misses into safe CAUTIONs.")
