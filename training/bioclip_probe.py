#!/usr/bin/env python3
"""
Test whether BioCLIP — a vision model trained on the tree of life — identifies
our poison-ivy classes better than Create ML's general feature extractor.

Method (a "linear probe", the standard way to evaluate a frozen backbone):
  1. Embed every train/test image with frozen BioCLIP (no backbone training).
  2. Fit a logistic-regression head on the train embeddings.
  3. Score on the SAME held-out testset/ Create ML was measured on.

Outputs predictions in the predictions.csv format so eval.py compares apples
to apples. Embeddings are cached so re-runs are instant.
"""
import os
import glob
import numpy as np
import torch
import open_clip
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"
CACHE = os.path.join(HERE, "embeddings_bioclip.npz")

print(f"device: {DEVICE}")
print("loading BioCLIP (downloads ~350MB first run)…")
model, _, preprocess = open_clip.create_model_and_transforms("hf-hub:imageomics/bioclip")
model = model.to(DEVICE).eval()


def images_in(root):
    items = []
    for cls in sorted(os.listdir(root)):
        d = os.path.join(root, cls)
        if not os.path.isdir(d):
            continue
        for f in sorted(glob.glob(os.path.join(d, "*.jpg"))):
            items.append((f, cls))
    return items


@torch.no_grad()
def embed(items, label):
    feats, labels = [], []
    batch, batch_lbl = [], []

    def flush():
        if not batch:
            return
        x = torch.stack(batch).to(DEVICE)
        e = model.encode_image(x)
        e = e / e.norm(dim=-1, keepdim=True)
        feats.append(e.cpu().numpy())
        labels.extend(batch_lbl)
        batch.clear()
        batch_lbl.clear()

    for i, (path, cls) in enumerate(items):
        try:
            img = Image.open(path).convert("RGB")
        except Exception:
            continue
        batch.append(preprocess(img))
        batch_lbl.append(cls)
        if len(batch) == 64:
            flush()
            if i % 1280 == 0:
                print(f"  {label}: {i}/{len(items)}")
    flush()
    return np.concatenate(feats), np.array(labels)


if os.path.exists(CACHE):
    print("loading cached embeddings…")
    z = np.load(CACHE, allow_pickle=True)
    Xtr, ytr, Xte, yte = z["Xtr"], z["ytr"], z["Xte"], z["yte"]
else:
    print("embedding train set…")
    Xtr, ytr = embed(images_in(os.path.join(HERE, "dataset")), "train")
    print("embedding test set…")
    Xte, yte = embed(images_in(os.path.join(HERE, "testset")), "test")
    np.savez(CACHE, Xtr=Xtr, ytr=ytr, Xte=Xte, yte=yte)
    print(f"cached → {CACHE}")

print(f"train {Xtr.shape}  test {Xte.shape}")

from sklearn.linear_model import LogisticRegression

print("fitting logistic-regression head…")
clf = LogisticRegression(max_iter=2000, C=1.0)
clf.fit(Xtr, ytr)

proba = clf.predict_proba(Xte)
classes = clf.classes_
pred_idx = proba.argmax(1)
pred = classes[pred_idx]
conf = proba.max(1)

out = os.path.join(HERE, "predictions_bioclip.csv")
with open(out, "w") as f:
    f.write("true,pred,confidence\n")
    for t, p, c in zip(yte, pred, conf):
        f.write(f"{t},{p},{c}\n")
print(f"wrote {out}")
print(f"raw test accuracy: {(pred == yte).mean()*100:.1f}%")
