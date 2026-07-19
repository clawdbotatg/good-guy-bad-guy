#!/usr/bin/env python3
"""
Bake BioCLIP (image encoder) + the cleaned logistic-regression head into a
single Core ML classifier that takes a photo and outputs the 12 class labels
with probabilities — a drop-in replacement for the Create ML model, usable by
the same Vision code in PlantClassifier.swift.

Pipeline inside the model:  image → /255 → normalize(CLIP mean/std) →
BioCLIP.encode_image → L2-normalize → linear(head W,b) → softmax → labels.
"""
import os
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import open_clip
import coremltools as ct


class CleanMHA(nn.Module):
    """Drop-in for open_clip's nn.MultiheadAttention that traces to plain
    matmul/softmax ops coremltools can convert (the fused and decomposed torch
    paths both break the converter). Reuses the original projection weights, so
    no retraining — numerically identical."""

    def __init__(self, mha):
        super().__init__()
        self.embed_dim = mha.embed_dim
        self.num_heads = mha.num_heads
        self.in_proj_weight = mha.in_proj_weight
        self.in_proj_bias = mha.in_proj_bias
        self.out_proj = mha.out_proj

    def forward(self, q, k, v, need_weights=False, attn_mask=None):
        # open_clip's MHA is batch_first=True: input is (N, L, E). Static dims
        # only (H, D from config), so the tracer emits no dynamic int ops.
        H = self.num_heads
        D = self.embed_dim // self.num_heads
        scale = D ** -0.5
        qkv = F.linear(q, self.in_proj_weight, self.in_proj_bias)  # (N,L,3E)
        qq, kk, vv = qkv.chunk(3, dim=-1)

        def heads(t):  # (N,L,E) → (N,H,L,D)
            return t.unflatten(-1, (H, D)).permute(0, 2, 1, 3)

        qq, kk, vv = heads(qq), heads(kk), heads(vv)
        attn = (qq @ kk.transpose(-2, -1)) * scale
        attn = attn.softmax(dim=-1)
        out = (attn @ vv).permute(0, 2, 1, 3).flatten(-2)  # (N,L,E)
        return self.out_proj(out), None
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import cross_val_predict

HERE = os.path.dirname(os.path.abspath(__file__))

# open_clip's ViT uses nn.MultiheadAttention, which traces to the fused
# `_native_multi_head_attention` op that coremltools can't convert. Disabling
# the fast path forces the decomposed (convertible) attention math.
torch.backends.mha.set_fastpath_enabled(False)

print("loading BioCLIP…")
model, _, preprocess = open_clip.create_model_and_transforms("hf-hub:imageomics/bioclip")
model = model.eval()

# Swap every attention block in the VISION tower for the converter-friendly one.
patched = 0
for block in model.visual.transformer.resblocks:
    block.attn = CleanMHA(block.attn)
    patched += 1
print(f"patched {patched} attention blocks")

# Pull the exact CLIP normalization out of the preprocess transform.
mean = std = None
for t in preprocess.transforms:
    if t.__class__.__name__ == "Normalize":
        mean, std = list(t.mean), list(t.std)
print("normalize mean", mean, "std", std)

# --- cleaned logistic head (the 87.5% model) ---
z = np.load(os.path.join(HERE, "embeddings_bioclip.npz"), allow_pickle=True)
Xtr, ytr = z["Xtr"], z["ytr"]
print("finding + dropping noisy train labels…")
oof = cross_val_predict(LogisticRegression(max_iter=2000), Xtr, ytr, cv=5, method="predict_proba")
classes = sorted(set(ytr))
cidx = {c: i for i, c in enumerate(classes)}
pred = np.array([classes[j] for j in oof.argmax(1)])
noisy = (pred != ytr) & (oof.max(1) >= 0.60)
head = LogisticRegression(max_iter=2000)
head.fit(Xtr[~noisy], ytr[~noisy])
LABELS = list(head.classes_)
W = torch.tensor(head.coef_, dtype=torch.float32)        # (12, 512)
b = torch.tensor(head.intercept_, dtype=torch.float32)   # (12,)
print(f"head fit on {(~noisy).sum()} imgs, {len(LABELS)} classes")


class PoisonIvyNet(nn.Module):
    def __init__(self):
        super().__init__()
        self.visual = model
        self.register_buffer("mean", torch.tensor(mean).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(std).view(1, 3, 1, 1))
        self.register_buffer("W", W)
        self.register_buffer("b", b)

    def forward(self, x):  # x in [0,1], (1,3,224,224)
        x = (x - self.mean) / self.std
        emb = self.visual.encode_image(x)
        emb = emb / emb.norm(dim=-1, keepdim=True)
        logits = emb @ self.W.t() + self.b
        return logits.softmax(dim=-1)


net = PoisonIvyNet().eval()
example = torch.rand(1, 3, 224, 224)
with torch.no_grad():
    traced = torch.jit.trace(net, example)
print("traced OK")

mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=(1, 3, 224, 224), scale=1 / 255.0, bias=[0, 0, 0])],
    classifier_config=ct.ClassifierConfig(class_labels=LABELS),
    minimum_deployment_target=ct.target.iOS16,
    compute_precision=ct.precision.FLOAT16,
)
mlmodel.short_description = "BioCLIP poison-ivy / look-alike classifier"
out = os.path.join(HERE, "PoisonIvyBioCLIP.mlpackage")
mlmodel.save(out)
sz = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(out) for f in fs)
print(f"saved {out}  ({sz/1e6:.0f} MB)")
