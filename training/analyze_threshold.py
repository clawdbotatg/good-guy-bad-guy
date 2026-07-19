#!/usr/bin/env python3
"""
Sweep the confidence threshold for declaring GOOD GUY. The app's safety rule:

  - predicted a DANGEROUS class          -> flag it (BAD GUY / caution). Safe side.
  - predicted a HARMLESS class, conf>=T   -> GOOD GUY
  - predicted a HARMLESS class, conf< T    -> CAUTION ("not sure")

The only lethal error is a truly-dangerous plant that gets a confident GOOD GUY.
This shows how raising T trades that error away for more CAUTION answers.
"""
import csv
import os

BAD = {
    "poison_ivy_eastern", "poison_ivy_western",
    "poison_oak_pacific", "poison_oak_atlantic", "poison_sumac",
}

rows = list(csv.DictReader(open(os.path.join(os.path.dirname(__file__), "predictions.csv"))))
total = len(rows)
true_bad = sum(1 for r in rows if r["true"] in BAD)
true_good = total - true_bad

def grp(x):
    return "BAD" if x in BAD else "GOOD"

print(f"Held-out test images: {total}  (dangerous: {true_bad}, harmless: {true_good})\n")
print(f"{'GOOD-conf ≥':>11}{'dangerous→SAFE':>16}{'CAUTION rate':>14}{'said GOOD GUY':>15}")
print("-" * 56)
for T in [0.0, 0.50, 0.60, 0.70, 0.80, 0.90, 0.95, 0.99]:
    missed = 0      # true BAD, predicted GOOD group, confident enough -> lethal miss
    caution = 0     # predicted GOOD group but under threshold -> "not sure"
    said_good = 0   # confident GOOD GUY output
    for r in rows:
        pred_good = grp(r["pred"]) == "GOOD"
        conf = float(r["confidence"])
        if pred_good and conf >= T:
            said_good += 1
            if r["true"] in BAD:
                missed += 1
        elif pred_good and conf < T:
            caution += 1
    miss_rate = missed / true_bad * 100 if true_bad else 0
    caution_rate = caution / total * 100
    good_rate = said_good / total * 100
    print(f"{T:>11.2f}{missed:>6} ({miss_rate:4.1f}%){caution_rate:>13.1f}%{good_rate:>14.1f}%")

print("\nRead: raising the GOOD-GUY confidence bar drives the dangerous-miss rate")
print("toward 0, at the cost of more 'not sure / CAUTION' answers. Pick the T where")
print("dangerous→SAFE is acceptably low without burying the user in CAUTIONs.")
