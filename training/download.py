#!/usr/bin/env python3
"""
Download CC-licensed, research-grade iNaturalist photos into per-class folders,
laid out exactly how Create ML wants them:

    dataset/
      poison_ivy_eastern/   *.jpg
      virginia_creeper/     *.jpg
      ...

Only pulls Creative-Commons-licensed photos (safe to train on). Downloads
medium-size (~500px) images, which is plenty for a Create ML image classifier.

Usage:
    python3 download.py --per-class 5      # smoke test
    python3 download.py --per-class 400    # full pull
"""
import argparse
import json
import os
import time
import urllib.parse
import urllib.request

API = "https://api.inaturalist.org/v1/observations"
OUT = os.path.join(os.path.dirname(__file__), "dataset")

# CC licenses we accept for training data (excludes All-Rights-Reserved).
CC = "cc0,cc-by,cc-by-nc,cc-by-sa,cc-by-nc-sa,cc-by-nd,cc-by-nc-nd"

# (folder slug, taxon_name)
CLASSES = [
    ("poison_ivy_eastern",  "Toxicodendron radicans"),
    ("poison_ivy_western",  "Toxicodendron rydbergii"),
    ("poison_oak_pacific",  "Toxicodendron diversilobum"),
    ("poison_oak_atlantic", "Toxicodendron pubescens"),
    ("poison_sumac",        "Toxicodendron vernix"),
    ("virginia_creeper",    "Parthenocissus quinquefolia"),
    ("box_elder",           "Acer negundo"),
    ("brambles",            "Rubus"),
    ("fragrant_sumac",      "Rhus aromatica"),
    ("staghorn_sumac",      "Rhus typhina"),
    ("jack_in_the_pulpit",  "Arisaema triphyllum"),
    ("hog_peanut",          "Amphicarpaea bracteata"),
]


def get_json(url, tries=4):
    """GET with retries — the iNaturalist API occasionally times out mid-pull."""
    for attempt in range(tries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "ggbg-dl/1.0"})
            with urllib.request.urlopen(req, timeout=45) as r:
                return json.load(r)
        except Exception as e:
            if attempt == tries - 1:
                raise
            print(f"    retry ({attempt+1}/{tries}) after: {e}")
            time.sleep(3 * (attempt + 1))


def fetch_photos(taxon_name, target):
    """Page through observations collecting up to `target` (photo_id, url) pairs.
    Keyed by photo id so re-runs are idempotent and never duplicate a photo."""
    out = []
    seen = set()
    page = 1
    while len(out) < target and page <= 45:
        params = urllib.parse.urlencode({
            "taxon_name": taxon_name,
            "quality_grade": "research",
            "photos": "true",
            "photo_license": CC,
            "order_by": "votes",   # community-favored photos = cleaner, well-framed
            "per_page": 50,
            "page": page,
        })
        results = get_json(f"{API}?{params}").get("results", [])
        if not results:
            break
        for obs in results:
            for p in obs.get("photos", []):
                pid, u = p.get("id"), p.get("url")
                if pid and u and pid not in seen:
                    seen.add(pid)
                    out.append((pid, u.replace("/square.", "/medium.")))
                    break  # one photo per observation → more diversity
        page += 1
        time.sleep(1.1)
    return out[:target]


def download(url, path):
    req = urllib.request.Request(url, headers={"User-Agent": "ggbg-dl/1.0"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read()
    with open(path, "wb") as f:
        f.write(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-class", type=int, default=5)
    args = ap.parse_args()

    for slug, taxon in CLASSES:
        d = os.path.join(OUT, slug)
        os.makedirs(d, exist_ok=True)
        have = len([f for f in os.listdir(d) if f.endswith(".jpg")])
        if have >= args.per_class:
            print(f"\n{slug} — already has {have} images, skipping.")
            continue
        print(f"\n{slug} ({taxon}) — have {have}, fetching {args.per_class} photos…")
        photos = fetch_photos(taxon, args.per_class)
        print(f"  got {len(photos)} photo ids, downloading new ones…")
        ok = 0
        for pid, u in photos:
            path = os.path.join(d, f"{slug}_{pid}.jpg")
            if os.path.exists(path):   # idempotent: already have this photo
                ok += 1
                continue
            try:
                download(u, path)
                ok += 1
            except Exception as e:
                print(f"    skip {u}: {e}")
            time.sleep(0.05)
        print(f"  saved {ok}/{len(photos)} → {d}")

    print(f"\nDone. Dataset at: {OUT}")


if __name__ == "__main__":
    main()
