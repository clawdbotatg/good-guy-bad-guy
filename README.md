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

The prompt is deliberately paranoid: between a dangerous species and its
harmless look-alike it must say CAUTION (never guess GOOD GUY), it never
advises touching or moving anything, and it never declares a mushroom or
plant safe to eat. **It's a 4B model, not a herpetologist — treat verdicts as
a first opinion, not a medical instrument.**

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
    downloads/caches weights and returns a `ModelContainer`; a `ChatSession`
    on top streams tokens and dispatches tool calls.
  - **`MockEngine`** (simulator builds): MLX can't run in the simulator (no
    Metal GPU), so sim builds stream a canned verdict — the full UI stays
    testable in automated simulator runs.
- The system prompt (`MLXEngine.instructions`) forces the
  `VERDICT: GOOD GUY | BAD GUY | CAUTION` first line;
  `ChatMessage.verdict` / `.bodyText` parse it out and `MessageBubble`
  renders the banner (red wins ties — safety bias).
- Qwen's `<think>…</think>` reasoning blocks are stripped for display and
  shown as a "Thinking…" indicator instead.
- `MLX.GPU.set(cacheLimit:)` + the increased-memory-limit entitlement keep
  the model inside iOS's per-app memory budget.

## Roadmap ideas

- One-tap verdict history ("field journal" of everything you've scanned)
- Region pack in the prompt: seed the top dangerous species for your area
- Share sheet extension: verdict any photo from Photos
- Haptics + sound on BAD GUY
