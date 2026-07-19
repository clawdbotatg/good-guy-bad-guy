#!/usr/bin/env python3
"""
Confirm the converted Core ML model still identifies as well as the Python
BioCLIP pipeline — quantization + tracing can drift. Runs the .mlpackage on the
held-out testset the same way the app will (center-crop to 224) and writes a
predictions CSV so eval.py scores it identically to the other models.
"""
import os
import glob
import coremltools as ct
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
model = ct.models.MLModel(os.path.join(HERE, "PoisonIvyBioCLIP.mlpackage"))
# Name of the image input.
spec_in = model.get_spec().description.input[0].name


def center_crop_224(img):
    img = img.convert("RGB")
    w, h = img.size
    s = 224 / min(w, h)
    img = img.resize((round(w * s), round(h * s)), Image.BICUBIC)
    w, h = img.size
    l, t = (w - 224) // 2, (h - 224) // 2
    return img.crop((l, t, l + 224, t + 224))


rows = []
test_root = os.path.join(HERE, "testset")
files = []
for cls in sorted(os.listdir(test_root)):
    d = os.path.join(test_root, cls)
    if os.path.isdir(d):
        for f in sorted(glob.glob(os.path.join(d, "*.jpg"))):
            files.append((f, cls))

print(f"scoring {len(files)} held-out images through Core ML…")
for i, (path, cls) in enumerate(files):
    try:
        img = center_crop_224(Image.open(path))
    except Exception:
        continue
    out = model.predict({spec_in: img})
    # classifier output: a label string + a dict of probabilities
    label = out.get("classLabel") or out.get("target")
    probs = next((v for v in out.values() if isinstance(v, dict)), {})
    conf = probs.get(label, 0.0)
    rows.append((cls, label, conf))
    if i % 400 == 0:
        print(f"  {i}/{len(files)}")

out_csv = os.path.join(HERE, "predictions_coreml.csv")
with open(out_csv, "w") as f:
    f.write("true,pred,confidence\n")
    for t, p, c in rows:
        f.write(f"{t},{p},{c}\n")
acc = sum(1 for t, p, _ in rows) and sum(1 for t, p, _ in rows if t == p) / len(rows) * 100
print(f"wrote {out_csv}")
print(f"Core ML raw accuracy: {acc:.1f}%")
