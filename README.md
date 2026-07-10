# Good Guy Bad Guy — is that critter dangerous? Ask your phone. Offline.

You're camping. Something with too many legs is on your tent, or a snake is
sunning itself on the trail. You have zero bars. Take a photo, and a
**vision-language model running entirely on your iPhone** tells you:

> **VERDICT: BAD GUY** 🔴 — Black widow (*Latrodectus mactans*), high
> confidence: glossy black body, red hourglass. Keep your distance and shake
> out shoes that sat outside.

No API keys, no server, no signal needed. The app downloads
[`mlx-community/Qwen3-VL-4B-Instruct-4bit`](https://huggingface.co/mlx-community/Qwen3-VL-4B-Instruct-4bit)
(~2.7 GB) from Hugging Face once on first launch, then all inference happens
on the iPhone's GPU via [MLX Swift](https://github.com/ml-explore/mlx-swift-lm).
Airplane mode is the intended operating condition.

Every identification opens with a parseable verdict line the UI renders as a
colored banner:

- 🟢 **GOOD GUY** — harmless or beneficial
- 🔴 **BAD GUY** — venomous, toxic, or dangerous to people or pets
- 🟠 **CAUTION** — can't tell confidently (look-alikes), or painful but not
  dangerous

## The model never decides whether something is dangerous

This is the core design, and it came from a real failure: asked about a
daylily, the on-device model identified it perfectly and then said it was
**"safe for cats."** Lilies cause fatal kidney failure in cats. A 4-bit 4B
model has excellent eyes and a lossy memory — freestyle toxicology from *any*
LLM's weights is a bad idea, and from a quantized 4B it's dangerous.

So the app is two stages:

1. **The model is the eyes.** It sees the photo and returns only an
   identification — `CATEGORY / ID / FEATURES`. It is forbidden from saying
   anything is dangerous or safe.
2. **A curated danger table is the encyclopedia.** Bundled in the app (works
   at zero bars), it maps species → verdict → a hand-written, factual note
   that's printed verbatim. Venomous snakes, spiders and scorpions; the
   plants that kill pets; deadly mushrooms; disease-carrying insects.

The table's safety posture, in order:

- The **most specific** match wins ("wolf spider" doesn't trip the *wolf*
  entry), and ties break **toward danger** ("milk snake, a coral snake mimic"
  → BAD GUY).
- **No match** on a snake, spider, scorpion, plant, or mushroom → **CAUTION**.
  A small model failing to recognize something is *not* evidence it's safe.
- **Wild mushrooms are never GOOD GUY.** Deadly species have edible twins.
- A hedged `(uncertain)` identification downgrades GOOD GUY to CAUTION.
- If the table ever fails to load, *everything* falls through to CAUTION.

`python3 tools/check_danger_table.py` runs 34 safety cases against the table
with no phone or GPU required — including the daylily that started all this.

**Still: it's one photo and a small model. Treat a verdict as a first
opinion, never as permission to touch, handle, or eat anything.**

Also on board: on-device speech-to-text (mic button), and a `get_location`
tool the model can call so "brown snake" resolves differently in Texas vs.
Australia (location never leaves the phone).

## Stack

- **SwiftUI** (iOS 17+) — chat UI with streaming tokens + verdict banners
- **[mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm)** — model
  implementations + `ChatSession` (multi-turn history, streaming, tools)
- **swift-huggingface / swift-transformers** — weights download + tokenizer
- **XcodeGen** — `project.yml` is the source of truth; the `.xcodeproj` is
  generated (and committed for convenience)

Forked from [clawd-mobile-app](https://github.com/clawdbotatg/clawd-mobile-app)
(general on-device assistant with the full phone-tool belt).

## Build & run

1. **Install Xcode** (App Store; 16.3 or newer — the packages need Swift 6.1
   toolchain). Then make sure the full Xcode is active:
   ```sh
   sudo xcode-select -s /Applications/Xcode.app
   ```
2. **Generate the project** (only needed after editing `project.yml`; a
   generated `GoodGuyBadGuy.xcodeproj` is already committed):
   ```sh
   brew install xcodegen
   xcodegen generate
   ```
3. **Open `GoodGuyBadGuy.xcodeproj`**, select the *GoodGuyBadGuy* target →
   *Signing & Capabilities* → pick your team.
4. **Run on a real iPhone** (plugged in, or Wi-Fi debugging). MLX needs an
   Apple-silicon GPU — the simulator is not a useful target. iPhone 13 or
   newer recommended; first launch downloads the weights, so be on Wi-Fi.

> If signing complains about the *Increased Memory Limit* entitlement on your
> account, delete it in Signing & Capabilities (or from
> `GoodGuyBadGuy/GoodGuyBadGuy.entitlements`).

## Agent loop (build → run → see, no hands)

`tools/simloop.sh [out.png]` builds the app, boots an iPhone simulator,
installs + launches the app, and writes a screenshot — so an agent (or CI)
can verify changes visually without a human clicking Run. The simulator uses
`MockEngine` (canned verdict reply); real-model verification needs a physical
iPhone. `tools/pulllog.sh` pulls the on-device debug log off a paired phone
without a console attach.

## How it works

- `ChatStore` (`@Observable`) owns the message list and model lifecycle on
  top of an `LLMEngine` protocol with two implementations:
  - **`MLXEngine`** (device builds): `#huggingFaceLoadModelContainer`
    downloads/caches weights and returns a `ModelContainer`. A photo turn
    collects the identification in full, runs `DangerTable.verdict()`, and
    emits the composed verdict; text turns stream normally.
  - **`MockEngine`** (simulator builds): MLX can't run in the simulator (no
    Metal GPU), so the *vision* stage is faked — but its canned
    identification goes through the same `DangerTable`, making the simulator
    a real regression test for the verdict logic.
- `DangerTable` + `DangerData` are the safety authority; `MLXEngine` is
  forbidden from making safety claims. The app composes the
  `VERDICT: GOOD GUY | BAD GUY | CAUTION` line, so the model can't garble it.
- Qwen's `<think>…</think>` reasoning blocks are stripped before parsing.
- `MLX.GPU.set(cacheLimit:)` + the increased-memory-limit entitlement keep
  the model inside iOS's per-app memory budget.

## Roadmap ideas

Offline is the product; online is a bonus that may only **narrow or escalate**
a verdict, never downgrade one to GOOD without curated backing.

- Online second opinion: a frontier model refines the species ID when there's
  signal, still checked against the table
- Regional priors: use `get_location` to weight species by where you are
- One-tap verdict history ("field journal" of everything you've scanned)
- Share sheet extension: verdict any photo from Photos
- Haptics + sound on BAD GUY
