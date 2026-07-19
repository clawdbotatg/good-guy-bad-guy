#!/usr/bin/env python3
"""
Carve a clean, held-out test set the model will NEVER train on, so confidence
numbers are honest. Deterministically moves ~15% of each class from dataset/
into testset/. Reversible: run with --restore to move them back.
"""
import argparse
import os
import shutil

HERE = os.path.dirname(__file__)
TRAIN = os.path.join(HERE, "dataset")
TEST = os.path.join(HERE, "testset")
EVERY = 7  # move every 7th file ≈ 14%


def split():
    moved = 0
    for cls in sorted(os.listdir(TRAIN)):
        src = os.path.join(TRAIN, cls)
        if not os.path.isdir(src):
            continue
        dst = os.path.join(TEST, cls)
        os.makedirs(dst, exist_ok=True)
        files = sorted(f for f in os.listdir(src) if f.endswith(".jpg"))
        for i, f in enumerate(files):
            if i % EVERY == 0:
                shutil.move(os.path.join(src, f), os.path.join(dst, f))
                moved += 1
    print(f"Moved {moved} images into testset/ (held out from training).")


def restore():
    moved = 0
    for cls in sorted(os.listdir(TEST)):
        src = os.path.join(TEST, cls)
        if not os.path.isdir(src):
            continue
        dst = os.path.join(TRAIN, cls)
        for f in os.listdir(src):
            if f.endswith(".jpg"):
                shutil.move(os.path.join(src, f), os.path.join(dst, f))
                moved += 1
    print(f"Restored {moved} images back into dataset/.")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--restore", action="store_true")
    args = ap.parse_args()
    restore() if args.restore else split()
