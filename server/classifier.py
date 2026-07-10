#!/usr/bin/env python3
"""Good Guy Bad Guy — cloud classifier service.

The app POSTs a photo here (with a shared token). We identify what's in it and
return the same good-guy/bad-guy verdict the on-device model would, so the app
renders it identically.

Identification is tiered:
  1. **claude -p** on this box's Claude subscription — free, frontier-quality.
     It names the organism AND proposes a verdict/explanation.
  2. **Fallback** cloud vision model via the **BANKR LLM gateway** (a different
     provider than the box's Claude, so a Claude-side outage doesn't take the
     whole service down), only if claude is unavailable and a key is configured.

The **verdict** is never left to the model: `danger.resolve` overrides it with
the curated danger list for any known species (this is what makes "daylily →
BAD GUY, deadly to cats" reliable). The model's verdict is only used for the
long tail the table doesn't cover.

**Privacy.** With `DEBUG_STORE=1` we keep every image plus BOTH classifiers'
raw output under `data/`, for tuning. That is a debugging mode. With it off
(the intended production state) the image is deleted the moment the verdict is
computed and nothing is written to disk.

Pure stdlib. Config via env (see .env.example):
  GGBG_TOKEN   shared secret the app must send in X-Auth-Token   (required)
  GGBG_PORT    listen port (default 41821)
  GGBG_MODEL   claude model alias (default "sonnet")
  DEBUG_STORE  "1" to save images + both classifiers' output
  BANKR_API_KEY   enables the BANKR fallback classifier (key starts with "bk_")
  BANKR_MODEL     BANKR vision model for the fallback (default gemini-3.1-flash-lite)
  BANKR_BASE_URL  BANKR gateway base (default https://llm.bankr.bot)
"""
import hmac
import json
import os
import re
import subprocess
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import danger

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(HERE, "data")
IMAGES_DIR = os.path.join(DATA_DIR, "images")
LOG_PATH = os.path.join(DATA_DIR, "log.jsonl")

TOKEN = os.environ.get("GGBG_TOKEN", "")
PORT = int(os.environ.get("GGBG_PORT", "41821"))
CLAUDE_MODEL = os.environ.get("GGBG_MODEL", "sonnet")
DEBUG_STORE = os.environ.get("DEBUG_STORE", "") == "1"
BANKR_KEY = os.environ.get("BANKR_API_KEY", "")
BANKR_MODEL = os.environ.get("BANKR_MODEL", "gemini-3.1-flash-lite")
BANKR_BASE_URL = os.environ.get("BANKR_BASE_URL", "https://llm.bankr.bot")
MAX_IMAGE_BYTES = 12 * 1024 * 1024

# Protect the subscription: cap concurrent claude calls.
_claude_slots = threading.Semaphore(int(os.environ.get("GGBG_CONCURRENCY", "3")))

# Rate limits (the token is a soft gate; a leaked one shouldn't drain the
# subscription). Fixed 60s windows, per client IP and global.
RATE_PER_IP = int(os.environ.get("GGBG_RATE_PER_IP", "20"))
RATE_GLOBAL = int(os.environ.get("GGBG_RATE_GLOBAL", "120"))
_rate_lock = threading.Lock()
_rate_hits = {}  # key -> (window_start, count)


def _rate_ok(key, limit):
    now = time.time()
    with _rate_lock:
        start, count = _rate_hits.get(key, (now, 0))
        if now - start >= 60:
            start, count = now, 0
        count += 1
        _rate_hits[key] = (start, count)
        # Opportunistic cleanup so the dict can't grow unbounded.
        if len(_rate_hits) > 10000:
            for k, (s, _c) in list(_rate_hits.items()):
                if now - s >= 60:
                    _rate_hits.pop(k, None)
        return count <= limit

# Cached claude-health flag, refreshed lazily.
_health = {"claude_alive": None, "checked_at": 0.0}
_health_lock = threading.Lock()

CLASSIFY_PROMPT = """You are the classifier for a wildlife-safety app called Good Guy Bad Guy.
Read the image file at {path}. Identify the single most likely animal, plant, insect, spider, snake, scorpion, or mushroom in it, then judge whether it is dangerous to people or pets.

Respond with ONLY a JSON object on one line — no markdown, no prose:
{{"id":"<common name> (<scientific name if known>)","category":"<snake|spider|scorpion|insect|plant|mushroom|mammal|bird|other>","verdict":"<good|bad|caution>","note":"<one to three short sentences: what it is, why the verdict, what to do>"}}

verdict: good = harmless or beneficial; bad = venomous, toxic, or dangerous to people or pets; caution = you cannot identify it confidently, a dangerous look-alike is possible, or it is painful but not dangerous.

Safety rules (these override everything):
- Between a dangerous species and a harmless look-alike you cannot rule out, use "caution" and name both candidates.
- Never advise touching, handling, moving, or eating anything.
- Lilies, including daylily (Hemerocallis), cause fatal kidney failure in cats — verdict "bad".
- Wild mushrooms are never "good" unless positively harmless; deadly species have edible twins — prefer "caution".
- If the person may have been bitten or stung, the note must say to seek medical help.
- If the image contains no living organism, reply {{"id":"not a plant or animal","category":"other","verdict":"caution","note":"That doesn't look like a plant or animal."}}
Keep the note under three sentences. Output the JSON only."""


# --------------------------------------------------------------------------- #
# classifiers
# --------------------------------------------------------------------------- #

def _clean_env():
    """Scrub vars that would flip claude into embedded/metered mode (per the
    harness SCRUB_ENV rule) — we want the subscription, not the API."""
    env = dict(os.environ)
    for key in list(env):
        if key == "ANTHROPIC_API_KEY" or key == "CLAUDECODE" or key.startswith("CLAUDE_CODE"):
            env.pop(key, None)
    return env


def _extract_json(text):
    """Pull the first JSON object out of a model reply."""
    if not text:
        return None
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?|\n?```$", "", text).strip()
    start = text.find("{")
    if start < 0:
        return None
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                try:
                    return json.loads(text[start:i + 1])
                except ValueError:
                    return None
    return None


def classify_with_claude(image_path, timeout=90):
    """Primary path: claude -p reads the image and returns id/category/verdict/note."""
    prompt = CLASSIFY_PROMPT.format(path=image_path)
    try:
        proc = subprocess.run(
            ["claude", "-p", prompt, "--allowedTools", "Read",
             "--model", CLAUDE_MODEL, "--output-format", "json"],
            capture_output=True, text=True, timeout=timeout, env=_clean_env(),
        )
    except subprocess.TimeoutExpired:
        return {"error": "claude timed out"}
    except FileNotFoundError:
        return {"error": "claude CLI not found"}
    if proc.returncode != 0:
        return {"error": f"claude exited {proc.returncode}: {proc.stderr[:200]}"}
    try:
        envelope = json.loads(proc.stdout)
    except ValueError:
        return {"error": "claude output not JSON"}
    if envelope.get("is_error"):
        return {"error": f"claude error: {envelope.get('result', '')[:200]}"}
    parsed = _extract_json(envelope.get("result", ""))
    if not parsed or "id" not in parsed:
        return {"error": "could not parse a classification from claude"}
    return parsed


def classify_with_bankr(image_path, mime, timeout=45, model=None):
    """A vision model via the BANKR LLM gateway (OpenAI-compatible).

    Used two ways: as the automatic fallback when claude -p is down (default
    model `BANKR_MODEL`, a Gemini flash-lite — a *different* provider than the
    box's Claude, so it survives a Claude outage), and as the primary path when
    the app explicitly asks for a BANKR model via the `X-Model` header (the
    Gemini brains in the picker). Needs a configured key.
    """
    if not BANKR_KEY:
        return {"error": "no fallback key configured"}
    import base64

    with open(image_path, "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    data_uri = f"data:{mime};base64,{b64}"
    body = {
        "model": model or BANKR_MODEL,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": CLASSIFY_PROMPT.format(path="(the attached image)")},
                {"type": "image_url", "image_url": {"url": data_uri}},
            ],
        }],
        "temperature": 0.2,
        # Generous cap: reasoning models (e.g. gemini-3.1-pro) spend most of
        # their tokens *thinking* before emitting the JSON — a 300 cap truncates
        # them mid-object (finish_reason "length"). Non-reasoning models stop
        # early on their own, so you only pay for what's actually generated.
        "max_tokens": 2000,
    }
    req = urllib.request.Request(
        BANKR_BASE_URL.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "X-API-Key": BANKR_KEY},
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read())
    except Exception as exc:  # noqa: BLE001 - report any failure as a soft error
        return {"error": f"bankr request failed: {exc}"}
    try:
        text = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        return {"error": "bankr returned no text"}
    parsed = _extract_json(text)
    if not parsed or "id" not in parsed:
        return {"error": "could not parse a classification from bankr"}
    return parsed


# --------------------------------------------------------------------------- #
# verdict assembly
# --------------------------------------------------------------------------- #

def finalize(raw):
    """Turn a classifier's {id,category,verdict,note} into the app's response,
    with the danger table overriding the verdict for known species."""
    name = (raw.get("id") or "").strip()
    category = (raw.get("category") or "other").strip().lower()
    if re.search("not a plant or animal", name, re.I):
        return {
            "id": name, "category": "other", "verdict": None,
            "note": "That doesn't look like a plant or animal. Point the camera at the "
                    "creature, plant, or mushroom you want checked.",
            "verdict_source": "none",
        }
    hedged = bool(re.search(r"uncertain|not sure|unknown|possibly|might be", name, re.I))
    verdict, note, source = danger.resolve(
        name, category, raw.get("verdict"), raw.get("note"), hedged
    )
    return {
        "id": name, "category": category, "verdict": verdict,
        "note": note, "verdict_source": source,
    }


# --------------------------------------------------------------------------- #
# health
# --------------------------------------------------------------------------- #

def claude_alive(force=False):
    with _health_lock:
        fresh = time.time() - _health["checked_at"] < 300
        if _health["claude_alive"] is not None and fresh and not force:
            return _health["claude_alive"]
    alive = False
    try:
        proc = subprocess.run(
            ["claude", "-p", "reply with OK", "--output-format", "json"],
            capture_output=True, text=True, timeout=60, env=_clean_env(),
        )
        env = json.loads(proc.stdout or "{}")
        alive = proc.returncode == 0 and not env.get("is_error", True)
    except Exception:  # noqa: BLE001
        alive = False
    with _health_lock:
        _health.update(claude_alive=alive, checked_at=time.time())
    return alive


# --------------------------------------------------------------------------- #
# http
# --------------------------------------------------------------------------- #

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):  # quieter logs
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorized(self):
        sent = self.headers.get("X-Auth-Token", "")
        return TOKEN and hmac.compare_digest(sent, TOKEN)

    def do_GET(self):
        if self.path.split("?")[0] == "/health":
            self._json(200, {
                "ok": True,
                "claude_alive": claude_alive(),
                "fallback_available": bool(BANKR_KEY),
                "fallback_model": BANKR_MODEL if BANKR_KEY else None,
                "debug_store": DEBUG_STORE,
                "danger_entries": len(danger.ENTRIES),
            })
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/classify":
            self._json(404, {"error": "not found"})
            return
        if not self._authorized():
            self._json(401, {"error": "bad or missing token"})
            return
        client = (self.headers.get("X-Forwarded-For", "") or
                  self.client_address[0]).split(",")[0].strip()
        if not _rate_ok("global", RATE_GLOBAL) or not _rate_ok(client, RATE_PER_IP):
            self._json(429, {"error": "rate limited, slow down"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0 or length > MAX_IMAGE_BYTES:
            self._json(413, {"error": "missing or oversized image"})
            return
        image = self.rfile.read(length)
        ctype = self.headers.get("Content-Type", "image/jpeg")
        ext = "png" if "png" in ctype else "jpg"

        # Which brain the app picked. "claude"/"fable"/absent → the box's free
        # subscription; anything else → that BANKR vision model (the Gemini
        # brains). The verdict is danger.resolve's either way.
        req_model = (self.headers.get("X-Model") or "claude").strip()
        want_claude = req_model.lower() in ("", "claude", "fable", "auto")

        started = time.time()
        # Always write to a temp file (claude reads by path); keep it only if
        # DEBUG_STORE, otherwise delete in finally.
        os.makedirs(IMAGES_DIR, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{int(time.time() * 1000) % 1000:03d}"
        image_path = os.path.join(IMAGES_DIR, f"{stamp}.{ext}")
        with open(image_path, "wb") as f:
            f.write(image)

        try:
            def run_claude():
                with _claude_slots:
                    return classify_with_claude(image_path)

            def run_bankr():
                return classify_with_bankr(
                    image_path, ctype, model=None if want_claude else req_model)

            # Primary is whichever brain the app asked for; the other engine is
            # the automatic fallback (and, in debug mode, always run so we can
            # compare the two on every photo).
            if want_claude:
                primary_name, primary = "claude", run_claude()
                other_name, other_fn = "bankr:" + BANKR_MODEL, run_bankr
            else:
                primary_name, primary = "bankr:" + req_model, run_bankr()
                other_name, other_fn = "claude", run_claude

            other = None
            if DEBUG_STORE or "error" in primary:
                other = other_fn()

            chosen = primary if "error" not in primary else other
            chosen_name = primary_name if chosen is primary else other_name
            if not chosen or "error" in (chosen or {"error": 1}):
                self._json(502, {
                    "error": "classification unavailable",
                    "primary": {primary_name: primary},
                    "fallback": {other_name: other},
                })
                return

            result = finalize(chosen)
            result["source"] = chosen_name
            result["elapsed_ms"] = int((time.time() - started) * 1000)

            if DEBUG_STORE:
                self._debug_log(image_path, primary_name, primary,
                                other_name, other, result)
            self._json(200, result)
        finally:
            if not DEBUG_STORE:
                try:
                    os.remove(image_path)
                except OSError:
                    pass

    def _debug_log(self, image_path, primary_name, primary, other_name, other, result):
        record = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "image": os.path.relpath(image_path, HERE),
            "chosen": result.get("source"),
            "primary": {"engine": primary_name, "out": primary},
            "fallback": {"engine": other_name, "out": other},
            "result": result,
        }
        with open(LOG_PATH, "a") as f:
            f.write(json.dumps(record) + "\n")


def main():
    if not TOKEN:
        raise SystemExit("GGBG_TOKEN is required (set it in the environment / .env)")
    os.makedirs(DATA_DIR, exist_ok=True)
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"ggbg-classifier on :{PORT}  model={CLAUDE_MODEL}  "
          f"debug_store={DEBUG_STORE}  "
          f"fallback={BANKR_MODEL if BANKR_KEY else 'off'}  "
          f"danger_entries={len(danger.ENTRIES)}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
