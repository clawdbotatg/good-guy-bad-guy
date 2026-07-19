#!/usr/bin/env python3
"""Where did the image input get disconnected? Compare Core ML vs torch on two
very different images."""
import os, glob
import numpy as np, torch, torch.nn as nn, torch.nn.functional as F
import open_clip, coremltools as ct
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))

# two clearly different held-out images
ivy = glob.glob(os.path.join(HERE, "testset/poison_ivy_eastern/*.jpg"))[0]
jack = glob.glob(os.path.join(HERE, "testset/jack_in_the_pulpit/*.jpg"))[0]

def crop224(p):
    im = Image.open(p).convert("RGB")
    w, h = im.size; s = 224 / min(w, h)
    im = im.resize((round(w*s), round(h*s)), Image.BICUBIC)
    w, h = im.size; l, t = (w-224)//2, (h-224)//2
    return im.crop((l, t, l+224, t+224))

# ---- Core ML ----
m = ct.models.MLModel(os.path.join(HERE, "PoisonIvyBioCLIP.mlpackage"))
name = m.get_spec().description.input[0].name
for tag, p in [("ivy", ivy), ("jack", jack)]:
    out = m.predict({name: crop224(p)})
    probs = next(v for v in out.values() if isinstance(v, dict))
    top = max(probs, key=probs.get)
    print(f"CoreML  {tag:5} -> {top} ({probs[top]:.3f})")

# ---- torch original BioCLIP + fresh head (sanity that data path works) ----
model, _, preprocess = open_clip.create_model_and_transforms("hf-hub:imageomics/bioclip")
model = model.eval()
def emb(p):
    x = preprocess(Image.open(p).convert("RGB")).unsqueeze(0)
    with torch.no_grad():
        e = model.encode_image(x)
    return (e / e.norm(dim=-1, keepdim=True)).numpy()
print("torch embedding norms differ:",
      not np.allclose(emb(ivy), emb(jack)))
