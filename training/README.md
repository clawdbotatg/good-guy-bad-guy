# Training — poison-ivy & look-alike classifier

Goal: a small, on-device image classifier that names the plant in a photo, so
the app's `DangerTable` can turn that name into a GOOD GUY / BAD GUY verdict.
The model identifies; Swift decides danger (the app's core rule).

Fully local: data from iNaturalist (free), training on the Mac via Create ML
(free), output is a Core ML `.mlmodel` that runs offline on iPhone.

## Classes (12)

Dangerous (BAD): poison ivy (eastern/western), poison oak (pacific/atlantic),
poison sumac.
Harmless look-alikes (GOOD): Virginia creeper, box elder, brambles, fragrant
sumac, staghorn sumac, jack-in-the-pulpit, hog peanut.

## Pipeline

1. **Census** — `python3 census.py` — how many labeled photos exist per class.
   (Done: 1.3M available; every class has plenty.)
2. **Download** — `python3 download.py --per-class 500` — pulls CC-licensed,
   research-grade photos into `dataset/<class>/`. 500 = buffer for culling.
3. **Cull** — open `dataset/` in Finder (gallery view), delete obvious non-leaf
   shots (stumps, bark, bare seeds, landscapes). ~20–30 min. Aim ~400 good/class.
4. **Train** — `swift train_classifier.swift` — writes `PoisonIvyClassifier.mlmodel`
   and prints validation accuracy (the honest number).
5. **Ship** — add the `.mlmodel` to the app; run it in Stage 1 (Vision request);
   feed its top label into `DangerTable`. Low confidence → CAUTION.

## Notes

- `dataset/` is gitignored (large; CC photos aren't ours to redistribute).
- Data is portable: if we ever switch to a fully open-source model (MobileNet /
  EfficientNet / open CLIP via PyTorch → coremltools), the same `dataset/` works.
- Retrain anytime: add more images to a class folder, re-run step 4.
