#!/usr/bin/env python3
"""Compress the fp16 Core ML model with 6-bit palettization so it fits under
GitHub's 100MB limit (and ships smaller). Weights become 6-bit indices into a
learned lookup table — typically near-lossless for a classifier."""
import os
import coremltools as ct
from coremltools.optimize.coreml import (
    palettize_weights, OpPalettizerConfig, OptimizationConfig)

HERE = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(HERE, "PoisonIvyBioCLIP.mlpackage")
dst = os.path.join(HERE, "PoisonIvyBioCLIP6bit.mlpackage")

print("loading fp16 model…")
m = ct.models.MLModel(src)
cfg = OptimizationConfig(global_config=OpPalettizerConfig(nbits=6, mode="kmeans"))
print("palettizing to 6-bit (k-means)…")
comp = palettize_weights(m, cfg)
comp.save(dst)
sz = sum(os.path.getsize(os.path.join(dp, f))
         for dp, _, fs in os.walk(dst) for f in fs)
print(f"saved {dst}  ({sz/1e6:.0f} MB)")
