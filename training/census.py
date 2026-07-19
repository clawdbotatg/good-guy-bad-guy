#!/usr/bin/env python3
"""
Census how many research-grade, photo-bearing observations exist on iNaturalist
for each class we'd train a poison-ivy look-alike classifier on.

No API key needed (public GET). Just tells us if the data foundation is real
before we build a downloader. Total counts only — downloads nothing.
"""
import json
import time
import urllib.parse
import urllib.request

API = "https://api.inaturalist.org/v1/observations"

# (label, verdict-hint, {query params}). Some classes are a single species
# (taxon_name), a couple are a whole genus (taxon_id would be more exact, but
# taxon_name resolves fine for a census).
CLASSES = [
    # --- the dangerous ones (BAD GUY) ---
    ("poison ivy (eastern)",  "BAD", "Toxicodendron radicans"),
    ("poison ivy (western)",  "BAD", "Toxicodendron rydbergii"),
    ("poison oak (pacific)",  "BAD", "Toxicodendron diversilobum"),
    ("poison oak (atlantic)", "BAD", "Toxicodendron pubescens"),
    ("poison sumac",          "BAD", "Toxicodendron vernix"),
    # --- the harmless look-alikes (GOOD GUY) ---
    ("Virginia creeper",      "GOOD", "Parthenocissus quinquefolia"),
    ("box elder",             "GOOD", "Acer negundo"),
    ("brambles (Rubus)",      "GOOD", "Rubus"),
    ("fragrant sumac",        "GOOD", "Rhus aromatica"),
    ("staghorn sumac",        "GOOD", "Rhus typhina"),
    ("jack-in-the-pulpit",    "GOOD", "Arisaema triphyllum"),
    ("hog peanut",            "GOOD", "Amphicarpaea bracteata"),
]


def count(taxon_name):
    params = urllib.parse.urlencode({
        "taxon_name": taxon_name,
        "quality_grade": "research",
        "photos": "true",
        "per_page": 0,
    })
    req = urllib.request.Request(f"{API}?{params}", headers={"User-Agent": "ggbg-census/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r).get("total_results", 0)


def main():
    print(f"{'CLASS':<24}{'VERDICT':<8}{'RESEARCH-GRADE PHOTOS':>22}")
    print("-" * 54)
    total = 0
    for label, verdict, taxon in CLASSES:
        try:
            n = count(taxon)
        except Exception as e:
            print(f"{label:<24}{verdict:<8}{'ERR: ' + str(e):>22}")
            continue
        total += n
        print(f"{label:<24}{verdict:<8}{n:>22,}")
        time.sleep(1.1)  # be polite to the API
    print("-" * 54)
    print(f"{'TOTAL':<32}{total:>22,}")
    print("\nWe only need ~300-500 per class to train. Anything above that is plenty.")


if __name__ == "__main__":
    main()
