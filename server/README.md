# Good Guy Bad Guy — cloud classifier

A tiny stdlib HTTP service the app calls to get a good-guy/bad-guy verdict from
a photo without downloading an on-device brain. Runs on a box that has a Claude
subscription logged in, so classification is **free**.

## What it does

`POST /classify` (image bytes + `X-Auth-Token`) →

```json
{ "id": "Daylily (Hemerocallis)", "category": "plant",
  "verdict": "bad", "note": "Deadly to cats. …",
  "verdict_source": "table", "source": "claude", "elapsed_ms": 8123 }
```

Identification is tiered:

1. **`claude -p`** on this box's subscription — free, frontier-quality. Reads
   the image, names the organism, proposes a verdict + note.
2. **Fallback** (Gemini Flash-Lite) — only if claude is unavailable and
   `GEMINI_API_KEY` is set.

**The verdict is never the model's call for known species.** `danger.resolve`
reads the app's `../GoodGuyBadGuy/LLM/DangerData.swift` (one source of truth,
no drift) and overrides the verdict for anything in the curated danger list —
that's what makes "daylily → BAD, deadly to cats" reliable. For the long tail
the table doesn't cover, the frontier model's verdict is trusted, with clamps
(wild mushrooms never GOOD; hedged IDs downgraded).

## Privacy

- `DEBUG_STORE=1` — keep **every image** plus **both** classifiers' raw output
  under `data/` (`data/images/`, `data/log.jsonl`). Debugging/tuning only.
- Unset / `0` (**intended production state**) — the image is deleted the moment
  the verdict is computed, and nothing is written to disk.

## Endpoints

- `GET /health` → `{ok, claude_alive, fallback_available, debug_store, danger_entries}`
- `POST /classify` → the verdict JSON above. `401` on bad token, `413` on a
  missing/oversized image, `502` if every classifier failed.

## Run

```sh
cp .env.example .env      # set GGBG_TOKEN (required); DEBUG_STORE=1 for now
./run.sh                  # foreground; loads .env
```

As a service (see `ggbg-classifier.service`):

```sh
sudo cp ggbg-classifier.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now ggbg-classifier
sudo systemctl status ggbg-classifier
journalctl -u ggbg-classifier -f
```

Deploy an update: `git pull` in the repo, then
`sudo systemctl restart ggbg-classifier`.

## Config (env / `.env`)

| var | default | meaning |
|---|---|---|
| `GGBG_TOKEN` | — (required) | shared secret; the app sends it in `X-Auth-Token` |
| `GGBG_PORT` | `41821` | listen port |
| `GGBG_MODEL` | `sonnet` | claude model alias for classification |
| `GGBG_CONCURRENCY` | `3` | max concurrent claude calls |
| `DEBUG_STORE` | off | `1` keeps images + both classifiers' output |
| `GEMINI_API_KEY` | — | enables the fallback classifier |

## Notes

- `claude -p` runs with `ANTHROPIC_API_KEY` / `CLAUDECODE` / `CLAUDE_CODE_*`
  scrubbed from its env, so it uses the **subscription**, not a metered key
  (the harness `SCRUB_ENV` rule).
- The token in the app binary is a soft gate (any shipped client secret is
  extractable). Rotate it by changing `.env` here + the constant in the app,
  and restart. Watch `journalctl` for abuse.
