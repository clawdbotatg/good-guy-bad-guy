# Good Guy Bad Guy — orientation for Claude

iOS app that answers one question from a photo: **is this critter dangerous?**
A fork of [clawd-mobile-app](https://github.com/clawdbotatg/clawd-mobile-app)
(ClawdChat) — same SwiftUI + [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)
3.x on-device stack, downloads `mlx-community/Qwen3-VL-4B-Instruct-4bit`
(~2.7 GB) on first launch, then runs fully offline. `README.md` has the
architecture; this file is the working state.

## What's different from the ClawdChat parent

- **Persona**: `MLXEngine.instructions` forces every identification to open
  with `VERDICT: GOOD GUY | BAD GUY | CAUTION`, with safety-first rules
  (look-alike → CAUTION never GOOD GUY; never advise touching; never call
  anything safe to eat; bitten → seek medical help).
- **Verdict UI**: `ChatMessage.verdict`/`.bodyText` parse the first line
  (BAD checked first so muddled lines err red); `MessageBubble` renders a
  green/red/orange banner. `ChatView` empty state is camera-first; an
  image-only send defaults the prompt to "Good guy or bad guy?".
- **Tools pruned to offline-only**: `get_location` (region → species priors,
  in `MoreTools`) + `get_device_status` (date → season, in `PhoneTools`).
  WebTools, contacts, calendar, reminders, steps, clipboard, weather are
  deleted — the app must work with zero bars, and a 4B model tool-disciplines
  better with 2 tools than 10.
- Names: target `GoodGuyBadGuy`, bundle `com.clawd.goodguybadguy`, display
  name "Good Guy?", debug log `Documents/goodguybadguy.log`.

Keep the fork lean: if a change isn't about photo→verdict, it probably
belongs in the parent repo instead.

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
