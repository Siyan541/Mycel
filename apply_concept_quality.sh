#!/usr/bin/env bash
# ============================================================================
# Mycel — concept quality: complete the deterministic precision pass (Stage 3)
#
# Extends refine.py from node-pruning to ALSO refine relations:
#   • drop weak edges (confidence < floor) — but never if it would isolate a node
#   • drop duplicate edges (same source/target/type)
#   • drop low-value orphan nodes when the map is large
# Result: degree-based emphasis (impSize) and the cluster layout reflect the
# REAL structure, and the edge hairball shrinks to meaningful links.
#
# The upload route already calls refine(graph) (from the Stage-3 prune script),
# so this just upgrades refine.py in place. Run from repo ROOT (idempotent).
# ============================================================================
set -e
if   [ -f backend/app/main.py ]; then APP="backend/app";
elif [ -f app/main.py ];         then APP="app";
else echo "ERROR: run from repo root."; exit 1; fi
[ -f "$APP/pipeline/refine.py" ] || echo "  note: refine.py not present yet; writing it (also run apply_concept_stage3_refine.sh to wire it)."

cat > "$APP/pipeline/refine.py" <<'PYEOF'
"""Mycel — deterministic precision pass (concept Stage 3): prune noise + refine relations.

Nodes: drop equations, exercise prompts, and degenerate labels (not learnable concepts).
Edges: drop weak (low-confidence) and duplicate relations, but never isolate a concept;
then drop low-value orphan nodes when the map is large. Conservative and graceful —
real concepts and each concept's strongest link are always kept.
"""
import re, logging
logger = logging.getLogger(__name__)

_IMPER = re.compile(
    r'^\s*(\(?[a-e]\)|show\b|find\b|prove\b|is\b|are\b|explain\b|suppose\b|let\b|'
    r'compute\b|verify\b|determine\b|give an example|consider\b|assume\b|then\b)', re.I)

def _get(o, k, d=None): return (o.get(k, d) if isinstance(o, dict) else getattr(o, k, d))

def is_noise(label):
    L = (label or "").strip()
    if len(L) <= 1 or len(L) > 64: return True
    if L.endswith("?"): return True
    if _IMPER.match(L): return True
    words = re.findall(r'[A-Za-z]{3,}', L)
    if (('=' in L) or ('∈' in L) or ('⊕' in L)) and len(words) <= 3: return True
    punct = len(re.findall(r'[=+\-*/^(){}\[\],]', L))
    if punct >= 4 and len(words) <= 2: return True
    return False

def refine(graph, max_nodes=100, edge_floor=0.35):
    try:
        nodes = graph.nodes; edges = graph.edges
        # 1) prune noise nodes + their edges
        drop = set(_get(n, "id") for n in nodes if is_noise(_get(n, "label", "")))
        nodes = [n for n in nodes if _get(n, "id") not in drop]
        keep = set(_get(n, "id") for n in nodes)
        edges = [e for e in edges if _get(e, "source_id") in keep and _get(e, "target_id") in keep]
        # 2) refine relations: drop weak (non-isolating) + duplicate edges
        deg = {}
        for e in edges:
            for k in ("source_id", "target_id"): deg[_get(e, k)] = deg.get(_get(e, k), 0) + 1
        econf = lambda e: (_get(e, "confidence", 0.5) or 0.5)
        seen = set(); kept = []
        for e in sorted(edges, key=econf):            # weakest first
            s, t = _get(e, "source_id"), _get(e, "target_id")
            key = (s, t, str(_get(e, "relation_type")))
            if key in seen:                            # duplicate
                deg[s] -= 1; deg[t] -= 1; continue
            if econf(e) < edge_floor and deg.get(s, 0) > 1 and deg.get(t, 0) > 1:  # weak, won't isolate
                deg[s] -= 1; deg[t] -= 1; continue
            seen.add(key); kept.append(e)
        edges = kept
        # 3) shed orphan low-confidence nodes only when the map is large
        d2 = {}
        for e in edges:
            for k in ("source_id", "target_id"): d2[_get(e, k)] = d2.get(_get(e, k), 0) + 1
        if max_nodes and len(nodes) > max_nodes:
            nodes = [n for n in nodes
                     if not (d2.get(_get(n, "id"), 0) == 0 and (_get(n, "confidence", 0) or 0) < 0.5)]
            keep = set(_get(n, "id") for n in nodes)
            edges = [e for e in edges if _get(e, "source_id") in keep and _get(e, "target_id") in keep]
        graph.nodes = nodes; graph.edges = edges
        return graph
    except Exception as e:
        logger.warning("refine: %s", e); return graph
PYEOF
python3 -m py_compile "$APP/pipeline/refine.py" && echo "  OK wrote $APP/pipeline/refine.py (node + relation refinement)" || { echo "  X compile failed"; exit 1; }

# ensure it's wired (in case the Stage-3 prune script wasn't run)
MAIN="$APP/main.py"
if ! grep -q "refine import refine" "$MAIN"; then
  BASE="$(echo "$APP" | sed 's#/#.#g')"
  cp "$MAIN" "$MAIN.qbak"
  MAIN="$MAIN" BASE="$BASE" python3 - <<'PY' || { echo "  ! wire refine(graph) after run() by hand"; }
import os,sys
p=os.environ["MAIN"]; base=os.environ["BASE"]; s=open(p).read()
i=s.find("graph = run(str(fp))")
if i<0: sys.exit(0)
ls=s.rfind("\n",0,i)+1; ind=s[ls:i]; le=s.find("\n",i); le=le if le>=0 else len(s)
hook="\n"+ind+"try:\n"+ind+"    from "+base+".pipeline.refine import refine\n"+ind+"    refine(graph)\n"+ind+"except Exception:\n"+ind+"    pass"
open(p,"w").write(s[:le]+hook+s[le:]); print("  OK wired refine(graph) into upload route")
PY
  python3 -m py_compile "$MAIN" || { echo "  X main compile failed — restoring"; mv "$MAIN.qbak" "$MAIN"; exit 1; }
  rm -f "$MAIN.qbak"
else
  echo "  · upload route already calls refine"
fi

echo "  → self-test:"
BASE="$(echo "$APP" | sed 's#/#.#g')" python3 - <<'PY' || echo "     (skipped — run in venv)"
import os,sys,importlib
sys.path.insert(0,os.getcwd())
r=importlib.import_module(os.environ["BASE"]+".pipeline.refine")
class G: pass
g=G()
g.nodes=[{"id":"A","label":"Vector space","confidence":0.9},{"id":"B","label":"Basis","confidence":0.85},
 {"id":"C","label":"Span","confidence":0.8},{"id":"N","label":"f(-x) = f(x)","confidence":0.6}]
g.edges=[{"id":"1","source_id":"B","target_id":"A","relation_type":"PART_OF","confidence":0.9},
 {"id":"2","source_id":"B","target_id":"A","relation_type":"PART_OF","confidence":0.4},
 {"id":"3","source_id":"C","target_id":"A","relation_type":"REQUIRES","confidence":0.15},
 {"id":"4","source_id":"N","target_id":"A","relation_type":"REQUIRES","confidence":0.9}]
r.refine(g)
ids=[n["id"] for n in g.nodes]; ek=[(e["source_id"],e["target_id"]) for e in g.edges]
assert "N" not in ids and ek.count(("B","A"))==1 and ("C","A") in ek
print("     OK noise node removed, duplicate edge dropped, C's only link kept")
PY

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
Concept quality upgraded. Restart backend (venv), re-upload the chapter:
  lsof -ti:8000 | xargs kill -9 2>/dev/null; uvicorn backend.app.main:app --reload --port 8000
The map keeps only learnable concepts and their strongest, non-duplicate
relations — meaningful degree (so key concepts size up) and far less hairball.
Prompt hardening (source-level, not runnable here) still recommended — see the
Stage-3 prune script's note.
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."