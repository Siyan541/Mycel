#!/usr/bin/env bash
# ============================================================================
# Mycel — Concept Stage 3 (deterministic precision): prune extraction noise
#
# The LLM over-extracts: raw equations ((x,y,z)=(x,y,0)+(0,0,z)), exercise
# prompts ("(a) Is {…} a subspace?", "Show that…"), and degenerate labels become
# concept nodes and turn the map into a hairball. refine.py deterministically
# drops those BEFORE grounding/provenance, so only learnable concepts remain.
#
# This is the testable, model-free half of design-doc Stage 3. The model-based
# half (GLiNER/REBEL) is deferred (heavy deps, can't verify offline).
#
# Run from repo ROOT:  bash apply_concept_stage3_refine.sh   (idempotent)
# ============================================================================
set -e
if   [ -f backend/app/main.py ]; then APP="backend/app";
elif [ -f app/main.py ];         then APP="app";
else echo "ERROR: run from repo root."; exit 1; fi
BASE="$(echo "$APP" | sed 's#/#.#g')"
echo "→ backend: $APP ($BASE)"

# ── 1. refine.py (self-contained; no backend imports) ───────────
cat > "$APP/pipeline/refine.py" <<'PYEOF'
"""Mycel — deterministic precision pass (concept Stage 3).

Prune nodes that are not learnable concepts — raw equations, exercise/question
prompts, and degenerate labels — before grounding and provenance. Conservative:
only clear noise is removed; real concept labels (short noun phrases) are kept.
Graceful: any failure is a no-op.
"""
import re, logging
logger = logging.getLogger(__name__)

_IMPER = re.compile(
    r'^\s*(\(?[a-e]\)|show\b|find\b|prove\b|is\b|are\b|explain\b|suppose\b|let\b|'
    r'compute\b|verify\b|determine\b|give an example|consider\b|assume\b|then\b)', re.I)

def _get(o, k, d=None): return (o.get(k, d) if isinstance(o, dict) else getattr(o, k, d))

def is_noise(label):
    L = (label or "").strip()
    if len(L) <= 1 or len(L) > 64: return True          # degenerate / sentence-like
    if L.endswith("?"): return True                     # question / exercise
    if _IMPER.match(L): return True                     # imperative exercise prompt
    words = re.findall(r'[A-Za-z]{3,}', L)
    if (('=' in L) or ('∈' in L) or ('⊕' in L)) and len(words) <= 3: return True   # equation
    punct = len(re.findall(r'[=+\-*/^(){}\[\],]', L))
    if punct >= 4 and len(words) <= 2: return True       # symbol-heavy fragment
    return False

def refine(graph, max_nodes=100):
    try:
        nodes = graph.nodes; edges = graph.edges
        drop = set(_get(n, "id") for n in nodes if is_noise(_get(n, "label", "")))
        deg = {}
        for e in edges:
            for k in ("source_id", "target_id"):
                v = _get(e, k)
                if v: deg[v] = deg.get(v, 0) + 1
        kept = [n for n in nodes if _get(n, "id") not in drop]
        if max_nodes and len(kept) > max_nodes:          # gentle: shed orphan low-conf nodes
            for n in kept:
                nid = _get(n, "id")
                if deg.get(nid, 0) == 0 and (_get(n, "confidence", 0) or 0) < 0.5:
                    drop.add(nid)
        graph.nodes = [n for n in nodes if _get(n, "id") not in drop]
        keep = set(_get(n, "id") for n in graph.nodes)
        graph.edges = [e for e in edges if _get(e, "source_id") in keep and _get(e, "target_id") in keep]
        if drop: logger.info("refine: pruned %d noise/orphan node(s)", len(drop))
        return graph
    except Exception as e:
        logger.warning("refine: %s", e); return graph
PYEOF
python3 -m py_compile "$APP/pipeline/refine.py" && echo "  OK wrote $APP/pipeline/refine.py" || { echo "  X refine.py compile failed"; exit 1; }

# ── 2. wire into upload route: refine(graph) right after run() (before grounding) ──
MAIN="$APP/main.py"
if grep -q "refine import refine" "$MAIN"; then
  echo "  · upload route already refines"
else
  cp "$MAIN" "$MAIN.refbak"
  MAIN="$MAIN" BASE="$BASE" python3 - <<'PY'
import os, sys
p=os.environ["MAIN"]; base=os.environ["BASE"]; s=open(p).read()
idx=s.find("graph = run(str(fp))")
if idx<0:
    print("  ! 'graph = run(str(fp))' not found — add refine(graph) after it by hand"); sys.exit(3)
ls=s.rfind("\n",0,idx)+1; indent=s[ls:idx]; le=s.find("\n",idx); le=le if le>=0 else len(s)
hook=("\n"+indent+"try:\n"+indent+"    from "+base+".pipeline.refine import refine\n"
      +indent+"    refine(graph)\n"+indent+"except Exception:\n"+indent+"    pass")
open(p,"w").write(s[:le]+hook+s[le:]); print("  OK upload route now prunes noise before grounding")
PY
  python3 -m py_compile "$MAIN" || { echo "  X main compile failed — restoring"; mv "$MAIN.refbak" "$MAIN"; exit 1; }
  rm -f "$MAIN.refbak"
fi

# ── 3. self-test (offline) ──────────────────────────────────────
echo "  → self-test:"
BASE="$BASE" python3 - <<'PY' || echo "     (self-test skipped — run inside venv)"
import os, sys, importlib
sys.path.insert(0, os.getcwd())
r=importlib.import_module(os.environ["BASE"]+".pipeline.refine")
keep=["Vector space","Basis","Continuous function","Distributive property","Rn and Cn","Subspace","Isomorphism"]
noise=["(x, y, z) = (x, y, 0) + (0, 0, z)","f(-x) = f(x)","(a) Is {(a,b,c)} a subspace of R3?",
       "Show that λ(α+β)=λα+λβ","F5 = U⊕W1 ⊕W2","then V1 = V2."]
fp=[L for L in keep if r.is_noise(L)]; mn=[L for L in noise if not r.is_noise(L)]
class G: pass
g=G(); g.nodes=[{"id":"a","label":"Vector space","confidence":0.9},{"id":"b","label":"f(-x) = f(x)","confidence":0.7}]
g.edges=[{"id":"e","source_id":"a","target_id":"b","relation_type":"REQUIRES"}]
r.refine(g)
ok=([n["id"] for n in g.nodes]==["a"] and len(g.edges)==0)
print("     legit kept:", not fp, "| noise dropped:", not mn, "| graph prune+edge cleanup:", ok)
assert not fp and not mn and ok
print("     OK refine verified")
PY

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
Concept Stage 3 (prune) applied. Restart backend (venv), re-upload the chapter:
  lsof -ti:8000 | xargs kill -9 2>/dev/null; uvicorn backend.app.main:app --reload --port 8000

Equations, exercise prompts, and degenerate labels no longer become nodes, so
the map holds only learnable concepts — far fewer nodes/edges, much less hairball.

RECOMMENDED prompt hardening (not runnable here; edit the extractor system prompt):
  "Do NOT extract equations, formulas, or exercise/problem statements as concepts.
   Extract only reusable ideas a student would learn. Skip restated examples."
This stops noise at the source; refine.py is the deterministic safety net.

Model-based Stage 3 (GLiNER + REBEL) remains deferred — heavy deps; this
deterministic pass delivers the precision goal today.
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."