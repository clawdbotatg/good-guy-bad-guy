# Good Guy Bad Guy — orientation for Claude

iOS app that answers one question from a photo: **is this plant poison ivy (or
oak/sumac) — or a harmless look-alike?** SwiftUI, **fully on-device and
offline**, a small **Core ML image classifier**. No cloud, no model download,
no LLM. (It was forked from ClawdChat and once used an on-device Qwen VLM; that
was ripped out — see history below.) `README.md` has the pitch; this file is
the working state.

## The one architectural rule: the model never decides danger

**The model is the eyes; `DangerTable` is the encyclopedia.** The classifier
only *names* the plant; a curated Swift table decides the verdict. This survived
the VLM removal unchanged and is still the core rule.

- **Stage 1 (`PlantClassifier` → `ClassifierEngine.identify`)**: a Core ML model
  (`PoisonIvyBioCLIP.mlpackage`, BioCLIP + a linear head) returns a class label
  + confidence. Nothing about danger.
- **Stage 2 (`DangerTable.verdict`)**: pure Swift + curated data decides the
  verdict and prints its `note` verbatim. Rules: most **specific** alias wins
  (so "wolf spider" doesn't hit the `wolf` entry) with severity breaking ties
  toward danger; no match on snake/spider/scorpion/plant/mushroom/other →
  CAUTION; wild mushrooms are never GOOD GUY; a hedged GOOD is downgraded to
  CAUTION; a JSON decode failure empties the table and everything falls to
  CAUTION.
- **Routing (`ClassifierEngine` + `PlantRoute`)** turns label+confidence into a
  verdict, calibrated on held-out data (`training/analyze_*.py`): dangerous
  class ≥0.40 → BAD GUY (below → CAUTION that still names it); harmless ≥0.75 →
  GOOD GUY; 0.50–0.75 → hedged CAUTION; weaker → "not sure" CAUTION. Lowering
  the dangerous bar only adds warnings, never removes them.

**Never route a safety claim through the model.** Richer verdicts come from
adding entries to `DangerData.swift`, never from trusting the model more.

`python3 tools/check_danger_table.py` is the table regression test (43 cases,
no phone/GPU — mirrors the Swift matcher over the embedded JSON: daylily,
"lilies", peace-lily-vs-lily, wolf-spider-vs-wolf, "ant" in "plant", and the 12
plant classes). **Run it before shipping any table/matcher change**, add the
case that motivated the change.

## The model & how to retrain it

BioCLIP (a vision transformer trained on the tree of life) + a linear head fit
on ~10k CC-licensed iNaturalist photos, 6-bit palettized to **~65 MB**. Held-out
(1,716 unseen photos): **87% exact, 95% of dangerous plants flagged, 0% called
safe.** The old Create ML model was ~70% and plateaued; BioCLIP gave the +17
points. **12 classes**: poison ivy (E/W), poison oak (pacific/atlantic), poison
sumac → BAD; Virginia creeper, box elder, brambles, fragrant/staghorn sumac,
jack-in-the-pulpit, hog peanut → GOOD.

The full reproducible pipeline (download → BioCLIP probe → clean → convert →
palettize → verify → ship) and the improvement ideas live in
**[`training/README.md`](training/README.md)**. Work happens in a py3.12 venv
(`training/.venv`; py3.14 is too new for torch). `dataset/`, `testset/`,
embeddings, and uncompressed `.mlpackage`s under `training/` are gitignored.

## Testing the app's REAL responses (the App-Review-rejection guard)

The submission was rejected for "weird, incomplete responses" — the *old VLM*
streaming text that got cut off. To confirm a build is clean you must see the
actual on-screen response to a photo, and **Core ML does not run in the iOS
Simulator on this Mac** (the "Failed to create espresso context" error). But
**macOS runs Core ML natively**, so:

```
tools/app_probe.sh <image.jpg> [more images...]
```

compiles the app's **real** Swift (`ClassifierEngine`/`PlantClassifier`/
`DangerTable`/`DangerData`/`DebugLog`) with the **real** bundled model and
prints the **exact string the app renders**, auto-flagging incomplete/garbled
output (mid-sentence cutoff, missing `VERDICT:` line, stray `< >` markers, empty
note). **Run it before every submission.** It uses the `GGBG_MODEL_PATH` seam in
`PlantClassifier` (never set in the shipped app). `training/app_demo.py` is the
Python equivalent over many held-out photos.

The old bug is *structurally* gone — with no VLM, every response is a fixed
Swift template with no free-generated text — but this proves it per-image and
guards regressions.

## App shape (post-VLM)

- **`ClassifierEngine`** is the whole brain: `identify(CIImage) -> Answer`
  (`ID:` line + composed `VERDICT:` text). No streaming, no async model load,
  no download. Runs the instant the app opens.
- **`ChatStore`** holds the message list and calls the engine; **`ChatView`** is
  photo-in / verdict-out (empty state → camera/library → banner → "scan
  another"). No brain picker, no loading screen, no chat composer.
- **Verdict UI**: `ChatMessage.verdict`/`.bodyText` parse the leading
  `VERDICT:`/`ID:` lines; `MessageBubble` renders the green/red/orange banner +
  standing disclaimer. Verdict-format changes must update BOTH `ClassifierEngine`
  (composes it) and the `ChatMessage` parser.
- **Image-first**: a captured/picked photo auto-sends. `GGBG_DEMO=1` auto-sends
  the bundled `DemoPhoto` for screenshots.
- Names: target `GoodGuyBadGuy`, bundle `com.clawd.goodguybadguy`, display name
  "Good Guy?", debug log `Documents/goodguybadguy.log`.

Keep the fork lean: if a change isn't about photo→plant→verdict, reconsider it.

## Fully on-device — no cloud, ever

100% on-device and offline is the product. A brief cloud brain was removed in
2026-07; the VLM in 2026-07-19. **Do not reintroduce any network path** for
identification or verdicts, and **do not re-add an LLM/VLM** — the pure
classifier is faster, tiny, and can't emit the incomplete output that got the
app rejected. Anything that could downgrade a BAD/CAUTION to GOOD must have
curated backing shipped in the app.

## Build / deploy loop (all CLI, no Xcode GUI)

- Prefix Xcode commands with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (xcode-select
  points at CommandLineTools; that's fine).
- **`project.yml` (XcodeGen) is the source of truth** — `xcodegen generate`
  after editing and **commit the regenerated `.xcodeproj` with it** (a stale
  project file silently drops new source files). There are **no third-party
  Swift packages anymore** (Vision + Core ML are system frameworks).
- **Compile check / UI screenshot**: `tools/simloop.sh out.png` builds + runs in
  the simulator and screenshots. The UI renders there, but **the classifier
  won't run in the sim** (Core ML espresso limitation) — it falls to CAUTION.
  For real model behavior use `tools/app_probe.sh` (above) or a device.
- **Device build**: `xcodebuild -project GoodGuyBadGuy.xcodeproj -scheme
  GoodGuyBadGuy -destination 'generic/platform=iOS' -derivedDataPath build
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates
  DEVELOPMENT_TEAM=XX7QP5899Z build` (the -skip flags are harmless leftovers,
  fine to keep).
- **Install + launch**: `xcrun devicectl device install app --device
  8B053FBC-B638-548F-B045-F5DDE25D3BDD <path>.app`, then `… device process
  launch --terminate-existing [--environment-variables '{"GGBG_DEMO":"1"}']
  --device <udid> com.clawd.goodguybadguy`. **Both fail while the phone is
  locked** — ask the user to unlock, retry. `tools/pulllog.sh` pulls the debug
  log (shows the classifier's prediction + verdict). Core ML *does* run on
  device (the espresso error is simulator-only).
- The 65 MB model is committed under `GoodGuyBadGuy/Resources/` (under GitHub's
  100 MB file limit thanks to palettization).

## Gotchas (current)

- **Core ML in the simulator fails** ("Failed to create espresso context") — a
  simulator limitation, not a bug. `PlantClassifier` forces `.cpuOnly` in the
  sim anyway. Test the model on macOS (`app_probe.sh`) or on device.
- **BioCLIP → Core ML conversion** (`training/convert_to_coreml.py`): open_clip's
  attention must be rewritten to trace (no fused/`_native_multi_head_attention`,
  no dynamic-shape int ops), and its MHA is **`batch_first=True`** — the
  hand-written attention must use (N,L,E) axes or the converted model predicts
  one class for everything. Both fixed; don't regress.
- Do not add an API/network fallback; on-device-offline is the entire point.
