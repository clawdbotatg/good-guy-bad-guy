# Training & testing — poison-ivy / look-alike classifier

The app answers one question from a photo: **is this plant a rash-causer or a
harmless look-alike?** A small on-device Core ML model *names* the plant; the
Swift `DangerTable` turns that name into a GOOD GUY / BAD GUY / CAUTION verdict.
**The model never decides danger** — it only identifies. Everything here runs on
the Mac; the shipped model runs fully offline on the phone.

## The model (current: BioCLIP, 87%)

The shipped model is **BioCLIP** — a vision transformer trained on the tree of
life — with a linear classifier head fit on our photos, 6-bit palettized to
**~65 MB** (`GoodGuyBadGuy/Resources/PoisonIvyBioCLIP.mlpackage`).

Held-out accuracy (1,716 photos the model never trained on):

| metric | Create ML (old) | **BioCLIP (shipped)** |
|---|---|---|
| exact 12-class | 70% | **87%** |
| dangerous plants correctly flagged | 83% | **95%** |
| dangerous plant called "safe" | — | **0 of 715** |
| median confidence | 0.61 | **0.75** |

Create ML plateaued (~70%, more iterations gave nothing — the general feature
extractor was the ceiling). BioCLIP's species-trained features gave the +17
points the deep research predicted.

## Classes (12)

Dangerous → BAD GUY: poison ivy (eastern/western), poison oak (pacific/atlantic),
poison sumac.
Harmless look-alikes → GOOD GUY: Virginia creeper, box elder, brambles, fragrant
sumac, staghorn sumac, jack-in-the-pulpit, hog peanut.

## Environment

Python 3.14 on this Mac is too new for PyTorch, so the pipeline uses an isolated
3.12 venv (created with `uv`):

```
uv venv --python 3.12 training/.venv
uv pip install --python training/.venv/bin/python \
  torch torchvision open_clip_torch pillow numpy scikit-learn coremltools
```

Run pipeline scripts with `training/.venv/bin/python …`. The `.venv/`, image
folders, embeddings, and `*.mlpackage` under `training/` are gitignored.

## Pipeline (data → shipped model)

1. **Census** — `python3 census.py` — how many labeled photos exist per class
   on iNaturalist (no venv needed; stdlib). 1.3M available.
2. **Download** — `python3 download.py --per-class 1000` — pulls CC-licensed,
   research-grade photos into `dataset/<class>/`, keyed by photo id so re-runs
   are idempotent (skip-if-present) and never duplicate.
3. **Split** — `python3 make_test_split.py` — moves ~15% into `testset/` as a
   clean held-out set (never trained on). `--restore` puts them back.
4. **Embed + probe** — `.venv/bin/python bioclip_probe.py` — embeds every image
   with frozen BioCLIP (cached to `embeddings_bioclip.npz`), fits a
   logistic-regression head, writes `predictions_bioclip.csv`.
5. **Clean** — `.venv/bin/python clean_and_reprobe.py` — cross-validation flags
   confidently-mislabeled / junk training images (~2%), drops them, refits.
6. **Convert** — `.venv/bin/python convert_to_coreml.py` — bakes BioCLIP + the
   cleaned head into one Core ML classifier (`PoisonIvyBioCLIP.mlpackage`).
   *(Two ViT→Core ML gotchas are solved in here: open_clip's attention is
   rewritten to trace cleanly, and its MHA is `batch_first=True` — the axes must
   be (N,L,E) or the model predicts one class for everything.)*
7. **Palettize** — `.venv/bin/python palettize.py` — 6-bit compression to
   ~65 MB (fits GitHub's 100 MB limit; near-lossless).
8. **Verify** — `.venv/bin/python verify_coreml.py` — runs the converted model
   on the held-out set to confirm accuracy survived (it did: 87.0% vs 87.5%).
9. **Ship** — copy the palettized `.mlpackage` into
   `GoodGuyBadGuy/Resources/PoisonIvyBioCLIP.mlpackage`; `PlantClassifier`
   loads it, `ClassifierEngine` routes it through `DangerTable`.

Scoring: `python3 eval.py <predictions.csv> [label]` prints the held-out
scorecard for any stage. `analyze_threshold.py` / `analyze_dangerous.py`
calibrate the verdict thresholds (`PlantRoute` in `PlantClassifier.swift`).

## Testing the app's REAL on-screen responses

**The concern this answers:** the App Store rejection was "weird, incomplete
responses" — the old VLM streaming text that got cut off. To confirm a build
doesn't do that, you need to see the *actual* response to a photo. The iOS
Simulator can't help — **Core ML doesn't run in the simulator on this Mac**
(the "espresso context" error). But **macOS runs Core ML natively.**

```
tools/app_probe.sh <image.jpg> [more images...]
```

This compiles the app's **real** Swift code (`ClassifierEngine` →
`PlantClassifier` → `DangerTable`, plus `DangerData`/`DebugLog`) with the
**real** bundled model and prints the **exact string the app renders on
screen** for each image — then auto-flags the rejection signatures:

- note cut off mid-sentence (the "incomplete output" bug)
- missing / garbled `VERDICT:` line
- stray `< >` template markers (the old placeholder-echo bug)
- empty note

Example (held-out photos + a random-noise "garbage" input):

```
════════ poison_ivy.jpg ════════
ID: Poison ivy
VERDICT: BAD GUY
Its oil (urushiol) causes a blistering rash on contact … never burn it.
✅ well-formed response (no incomplete/weird output)

════════ weird_noise.jpg ════════
ID: Not sure — treat with caution
VERDICT: CAUTION
I couldn't identify what's in the photo … don't touch or eat it.
✅ well-formed response
```

**Run it before every App Store submission.** All ✅ = the incomplete-output
class of bug is not present. (It can't be, structurally — with the VLM gone
every response is a fixed Swift template with no free-generated text — but this
proves it per-image and guards against regressions.) `app_probe.sh` uses the
`GGBG_MODEL_PATH` seam in `PlantClassifier` (a `.mlpackage` is compiled on the
fly); that env var is never set in the shipped app.

`app_demo.py` is a Python view of the same idea over many held-out photos at
once (true species vs. what the app says vs. verdict).

## Improving the model

- **More/cleaner data** — re-run download at a higher `--per-class`, or tighten
  the cleaning threshold in `clean_and_reprobe.py`; re-embed only new images.
- **Push past 87%** — a full BioCLIP fine-tune (unfreeze the backbone) instead
  of the linear probe; or add a **"not a target plant" negative class** so
  non-plant photos resolve to CAUTION by the model, not just by low confidence.
- After any model change, re-run **verify_coreml.py** (accuracy) and
  **app_probe.sh** (response well-formedness) before shipping.

## Notes

- Data is CC-licensed iNaturalist photos. `dataset/`/`testset/` are gitignored —
  not ours to redistribute. Shipping the trained *weights* is a separate,
  lower-risk question (the model isn't the photos), but worth a beat before an
  App Store push.
- The whole loop is reproducible from the committed scripts; only the large
  binaries (images, embeddings, uncompressed `.mlpackage`) are gitignored.
