#!/bin/bash
set -e
echo "🍄 Mycel — localhost setup (Ollama + fastembed, zero API cost)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f backend/app/main.py ]; then
  echo "  ✗ Run from repo root (backend/app/main.py not found)."; exit 1
fi
APP="backend/app"
MODEL="${LLM_MODEL:-qwen2.5:7b}"   # override: LLM_MODEL=qwen2.5:3b ./setup_local.sh

# ── 1) local .env pinned to Ollama (created only if missing) ────
ENV="backend/.env"
if [ ! -f "$ENV" ]; then
  cat > "$ENV" << ENVEOF
# Local dev — everything runs on your machine, no paid APIs.
LLM_PROVIDER=ollama
LLM_MODEL=$MODEL
# EMBED_MODEL=BAAI/bge-small-en-v1.5   # fastembed default (384-dim); uncomment to change
# TOGETHER_API_KEY=                    # only needed if LLM_PROVIDER=together
ENVEOF
  echo "  ✓ wrote $ENV  (LLM_PROVIDER=ollama, LLM_MODEL=$MODEL)"
else
  echo "  • $ENV already exists — leaving it untouched. For local, ensure it has:"
  echo "        LLM_PROVIDER=ollama"
  echo "        LLM_MODEL=$MODEL"
fi

# ── 2) harden llm.py: schema → json → plain fallback for Ollama ─
cp "$APP/services/llm.py" "$APP/services/llm.py.bak" 2>/dev/null || true
cat > "$APP/services/llm.py" << 'PYEOF'
import os, json, logging, httpx
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.config import LLM_PROVIDER, LLM_MODEL, TOGETHER_API_KEY, TOGETHER_MODEL

logger = logging.getLogger(__name__)

def chat(messages, json_schema=None, temperature=0.1, max_tokens=1500):
    if LLM_PROVIDER == "together":
        return _together(messages, json_schema, temperature, max_tokens)
    return _ollama(messages, json_schema, temperature, max_tokens)

def _ollama(messages, schema, temp, max_tok):
    """Local, free. Tries structured outputs (Ollama >= 0.5); falls back to
    format='json', then plain — so older Ollama versions still work."""
    import ollama as ol
    opts = {"temperature": temp, "num_ctx": 4096, "num_predict": max_tok}
    if schema:
        try:
            return ol.chat(model=LLM_MODEL, messages=messages,
                           format=schema, options=opts).message.content
        except Exception as e:
            logger.warning("ollama schema format failed (%s); retrying format=json", e)
            try:
                return ol.chat(model=LLM_MODEL, messages=messages,
                               format="json", options=opts).message.content
            except Exception as e2:
                logger.warning("ollama json format failed (%s); plain call", e2)
    return ol.chat(model=LLM_MODEL, messages=messages, options=opts).message.content

def _together(messages, schema, temp, max_tok):
    body = {"model": TOGETHER_MODEL, "messages": messages,
            "temperature": temp, "max_tokens": max_tok}
    if schema:
        body["response_format"] = {"type": "json_schema",
            "json_schema": {"name": "extraction", "schema": schema}}
    with httpx.Client(timeout=120) as c:
        r = c.post("https://api.together.xyz/v1/chat/completions",
            headers={"Authorization": f"Bearer {TOGETHER_API_KEY}",
                     "Content-Type": "application/json"},
            json=body)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
PYEOF
if command -v python3 >/dev/null 2>&1; then
  python3 -m py_compile "$APP/services/llm.py" \
    && echo "  ✓ hardened $APP/services/llm.py (schema→json→plain fallback)" \
    || { echo "  ✗ compile failed — restoring"; mv "$APP/services/llm.py.bak" "$APP/services/llm.py"; exit 1; }
fi
rm -f "$APP/services/llm.py.bak"

# ── 3) python deps (use a venv! see checklist) ──────────────────
REQ="requirements.txt"; [ -f "$REQ" ] || REQ="backend/requirements.txt"
echo "  → installing python deps..."
python3 -m pip install --quiet --upgrade \
  fastapi "uvicorn[standard]" httpx python-dotenv pydantic rapidfuzz \
  ollama fastembed numpy PyMuPDF pdfplumber 2>&1 | tail -1 || \
  echo "  ⚠ pip install had issues — check your venv/python; retry manually."
[ -f "$REQ" ] && python3 -m pip install --quiet -r "$REQ" 2>/dev/null || true
echo "  ✓ deps installed"

# ── 4) Ollama presence + model ──────────────────────────────────
echo "  → checking Ollama..."
if ! command -v ollama >/dev/null 2>&1; then
  echo "  ⚠ Ollama not found. Install from https://ollama.com/download, then:"
  echo "        ollama serve   &   ollama pull $MODEL"
else
  if ! ollama list 2>/dev/null | grep -q "$(echo "$MODEL" | cut -d: -f1)"; then
    echo "  ⚠ model '$MODEL' not pulled yet. Run:  ollama pull $MODEL"
  else
    echo "  ✓ Ollama present and '$MODEL' available"
  fi
fi

cat <<'NOTE'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
LOCAL RUN (two terminals):

  # terminal 1 — backend (free, Ollama)
  ollama serve                         # if not already running
  uvicorn backend.app.main:app --reload --port 8000

  # terminal 2 — frontend (Vite defaults to :5173, auto-targets :8000)
  cd frontend && npm install && npm run dev

Then open http://localhost:5173 and upload a PDF.

NOTES
  • First upload: fastembed downloads BAAI/bge-small-en-v1.5 (~50MB, once,
    needs internet that one time) and Ollama loads the model — so the first
    extraction is slow; later ones are fast.
  • 7B on CPU is slow. For speed set LLM_MODEL=qwen2.5:3b in backend/.env
    (lower quality); a GPU makes 7B comfortable.
  • Local data is separate from prod: SQLite + uploads live under ./data and
    ./uploads in the repo. Nothing touches Railway.
  • To go back to the paid hosted model, set LLM_PROVIDER=together in .env.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOTE
echo "✓ done."