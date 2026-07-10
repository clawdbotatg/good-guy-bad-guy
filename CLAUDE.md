# Good Guy Bad Guy — orientation for Claude

iOS app that answers one question from a photo: **is this critter dangerous?**
A fork of [clawd-mobile-app](https://github.com/clawdbotatg/clawd-mobile-app)
(ClawdChat) — same SwiftUI + [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
3.x on-device stack, downloads `mlx-community/Qwen3-VL-4B-Instruct-4bit`
(~2.7 GB) on first launch, then runs fully offline. `README.md` has the
architecture; this file is the working state.

## The one architectural rule: the model never decides danger

**The model is the eyes; `DangerTable` is the encyclopedia.** A 4-bit 4B VLM
sees well and recalls long-tail facts badly — on device it identified a
daylily correctly and then declared it "safe for cats," which is lethally
wrong (lilies cause fatal feline kidney failure). So:

- **Stage 1 (`MLXEngine.identifyInstructions`)**: the model gets the photo and
  returns ONLY `CATEGORY: / ID: / FEATURES:`. It is explicitly forbidden from
  saying anything is dangerous or safe.
- **Stage 2 (`DangerTable.verdict`)**: pure Swift + curated data decides the
  verdict and prints its `note` verbatim. Rules: most **specific** alias wins
  (so "wolf spider" doesn't hit the `wolf` entry) with severity breaking ties
  toward danger; no match on snake/spider/scorpion/plant/mushroom/other →
  CAUTION (a small model's silence is not evidence of safety); wild mushrooms
  are never GOOD GUY; a hedged `(uncertain)` GOOD is downgraded to CAUTION;
  a JSON decode failure empties the table and everything falls to CAUTION.
- Text follow-ups use `followupInstructions` and are told the printed verdict
  is authoritative and not to invent new toxicity claims.

**Never route a safety claim through the model.** If you want richer verdicts,
add entries to `DangerData.swift`, don't loosen the prompt.

`python3 tools/check_danger_table.py` is the regression test (34 cases, no
phone/GPU needed — it mirrors the Swift matcher over the embedded JSON). It
encodes bugs already hit: daylily, plural "lilies", peace lily vs true lily,
wolf spider vs wolf, "ant" inside "plant". **Run it before shipping any table
or matcher change**, and add the case that motivated your change.

## What else differs from the ClawdChat parent

- **Verdict UI**: `ChatMessage.verdict`/`.bodyText` parse the leading
  `VERDICT:` line (BAD checked first so muddled lines err red);
  `MessageBubble` renders a green/red/orange banner plus a standing
  disclaimer. Since the app composes that line, the model can no longer
  garble it.
- **Image-first**: a photo auto-sends on capture/pick — the picture is the
  question. The composer stays hidden until the first verdict, then appears
  for follow-ups (`ChatView`).
- **Tools pruned to offline-only**: `get_location` (region → species priors,
  in `MoreTools`) + `get_device_status` (date → season, in `PhoneTools`).
  WebTools, contacts, calendar, reminders, steps, clipboard, weather are
  deleted — the app must work with zero bars, and a 4B model tool-disciplines
  better with 2 tools than 10.
- Names: target `GoodGuyBadGuy`, bundle `com.clawd.goodguybadguy`, display
  name "Good Guy?", debug log `Documents/goodguybadguy.log`.

Keep the fork lean: if a change isn't about photo→verdict, it probably
belongs in the parent repo instead.

## Roadmap: online as a bonus, never a dependency

Offline is the product. The clean seam for online work is
`DangerTable.verdict` — an online enhancer would run *after* it (richer
species ID, regional priors from `get_location`, a frontier-model second
opinion) and may only **narrow or escalate** a verdict, never downgrade a
BAD/CAUTION to GOOD without curated backing.

## Build / deploy loop (all CLI, no Xcode GUI)

Identical to the parent — same device, same team, same flags:

- Prefix everything with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
  (xcode-select still points at CommandLineTools; that's fine).
- **Simulator**: `tools/simloop.sh out.png` — build, boot, install, launch,
  screenshot (MockEngine in the sim; MLX needs a real GPU). Read the
  screenshot to verify UI. The mock streams a canned BAD GUY verdict when an
  image is attached, so the banner is testable in the sim.
- **Device build**: `xcodebuild -project GoodGuyBadGuy.xcodeproj -scheme
  GoodGuyBadGuy -destination 'generic/platform=iOS' -derivedDataPath build
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates
  DEVELOPMENT_TEAM=XX7QP5899Z build`
  (the two -skip flags are required headless: mlx-swift's CudaBuild plugin and
  the `#huggingFaceLoadModelContainer` macro can't show their trust prompts).
- **Install + launch**: `xcrun devicectl device install app --device
  8B053FBC-B638-548F-B045-F5DDE25D3BDD <path>.app` then
  `… device process launch --terminate-existing --device <udid>
  com.clawd.goodguybadguy`. **Both fail while the phone is locked** — ask the
  user to unlock, retry in a loop. `tools/pulllog.sh` pulls the debug log.
- This app has its own container: first launch re-downloads the weights even
  if ClawdChat is installed (HF cache is per-app). Reinstalling over the top
  preserves them.

## Conventions / gotchas (inherited — still true)

- `project.yml` (XcodeGen) is the source of truth; `xcodegen generate` after
  editing and **commit the regenerated `.xcodeproj` together with it** — a
  stale project file silently drops new source files.
- Model swaps: `MLXEngine.model`. 4B-4bit is the practical phone model — the
  8B loads on a 12 GB phone but jetsam kills it at first generation
  (verified 2026-07-07 in the parent).
- Fresh `ChatSession` per turn + replayed `history`: KV-cache reuse across
  turns is broken for Qwen3-VL in mlx-swift-lm 3.31.4 (hangs/corruption).
  Don't "optimize" it back.
- Download progress: the HF snapshot is one giant safetensors file, so the
  real byte fraction stalls near 1% — the loading screen shows a time-based
  sweep instead. Don't "fix" it back to raw fraction.
- Do not add an API-based fallback; on-device-offline is the entire point.
- Verdict format changes must update BOTH `MLXEngine.instructions` and the
  `ChatMessage` parser (and `MockEngine`'s canned reply).
