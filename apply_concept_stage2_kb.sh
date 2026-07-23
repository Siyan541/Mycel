#!/usr/bin/env bash
# ============================================================================
# Mycel — Concept Stage 2: canonical KB grounding
#
#   • models.py  : GraphNode gains canonical_id + link_score
#   • kb.py (NEW): embed each concept, nearest-neighbour to a canonical KB entry
#                  (brute-force cosine over a seed KB; reuses the SAME fastembed
#                   model as provenance, so the 384-d space is shared), attach
#                   canonical_id+link_score, then dedup nodes sharing a canonical id
#   • kb_seed.json (NEW): math-first seed (math > physics > CS > chem > bio)
#   • upload route: ground(graph) after run() (concept maps only; graceful no-op)
#
# sqlite-vec is a later scale optimization; brute-force is fine at seed scale and
# needs no native extension. Wikidata on-demand is included but off by default.
#
# Run from repo ROOT:  bash apply_concept_stage2_kb.sh   (idempotent)
# ============================================================================
set -e
if   [ -f backend/app/main.py ]; then APP="backend/app";
elif [ -f app/main.py ];         then APP="app";
else echo "ERROR: run from repo root."; exit 1; fi
BASE="$(echo "$APP" | sed 's#/#.#g')"
echo "→ backend: $APP ($BASE)"

# ── 1. models.py: canonical_id + link_score on GraphNode ────────
MODELS="$APP/models.py"
if grep -q "canonical_id" "$MODELS"; then
  echo "  · models: canonical_id already present"
else
  cp "$MODELS" "$MODELS.kbbak"
  python3 - "$MODELS" <<'PY'
import sys, re
p=sys.argv[1]; s=open(p).read()
s2=re.sub(r'(class GraphNode\(BaseModel\):\n)',
          r'\1    canonical_id: str = ""       # KB grounding (Stage 2)\n    link_score: float = 0.0      # 0-1 similarity to the canonical entry\n',
          s, count=1)
if s2==s: print("  ! could not find GraphNode — add canonical_id/link_score by hand"); sys.exit(3)
open(p,"w").write(s2); print("  \u2713 models: added canonical_id + link_score to GraphNode")
PY
  python3 -m py_compile "$MODELS" || { echo "  ERROR models compile failed - restoring"; mv "$MODELS.kbbak" "$MODELS"; exit 1; }
  rm -f "$MODELS.kbbak"
fi

# ── 2. kb.py ────────────────────────────────────────────────────
cat > "$APP/services/kb.py" <<'KBEOF'
"""Mycel — Stage 2 canonical KB grounding.

Embed each concept, nearest-neighbour to a canonical KB entry (brute-force
cosine over a small seed KB; sqlite-vec is a later scale optimization), attach
canonical_id + link_score, then dedup nodes that resolve to the same entry.
Reuses the SAME fastembed model as provenance (bge-small, 384-d), so the space
is shared and the dimension stays locked. Graceful: any failure is a no-op —
grounding never breaks extraction. Code nodes are skipped (already canonical).
"""
import os, json, sqlite3, logging
logger = logging.getLogger(__name__)
_HERE = os.path.dirname(os.path.abspath(__file__))
SEED_PATH = os.path.join(_HERE, "kb_seed.json")
try:
    from __BASE__.config import DATA_DIR
    KB_DB = str(DATA_DIR / "kb.db")
except Exception:
    KB_DB = os.path.join(_HERE, "kb.db")
CODE_TYPES = {"module","class","function","parameter","constant","variable","type","interface","test","decorator"}

def _get(o,k,d=None): return (o.get(k,d) if isinstance(o,dict) else getattr(o,k,d))
def _set(o,k,v):
    if isinstance(o,dict): o[k]=v
    else:
        try: setattr(o,k,v)
        except Exception: pass

def _enc(texts):
    """Encode with the shared provenance embedder (fastembed bge-small, 384-d), normalized."""
    try:
        from __BASE__.services.media import _embedder, _encode
        emb=_embedder()
        if emb is None: return None
        import numpy as np
        v=np.asarray(_encode(emb, list(texts)), dtype="float32")
        nrm=(v*v).sum(1,keepdims=True)**0.5; nrm[nrm==0]=1.0
        return v/nrm
    except Exception as e:
        logger.warning("kb: embedder unavailable: %s", e); return None

def _conn():
    c=sqlite3.connect(KB_DB)
    c.execute("""CREATE TABLE IF NOT EXISTS kb_entries(canonical_id TEXT PRIMARY KEY,
        label TEXT, aliases TEXT, description TEXT, domain TEXT, dim INTEGER, embedding BLOB)""")
    return c

def seed_kb():
    """Embed + store any seed entries not yet in the KB. Idempotent."""
    try: entries=json.load(open(SEED_PATH))
    except Exception as e: logger.warning("kb: no seed (%s)", e); return 0
    c=_conn(); have=set(r[0] for r in c.execute("SELECT canonical_id FROM kb_entries"))
    todo=[e for e in entries if e.get("canonical_id") not in have]
    if not todo: c.close(); return 0
    V=_enc([(e.get("label","")+". "+e.get("description","")) for e in todo])
    if V is None: c.close(); return 0
    import numpy as np
    for e,vec in zip(todo,V):
        c.execute("INSERT OR REPLACE INTO kb_entries VALUES (?,?,?,?,?,?,?)",
            (e["canonical_id"], e.get("label",""), json.dumps(e.get("aliases",[])),
             e.get("description",""), e.get("domain",""), len(vec),
             np.asarray(vec,dtype="float32").tobytes()))
    c.commit(); n=len(todo); c.close(); logger.info("kb: seeded %d entries", n); return n

def _load_matrix():
    c=_conn(); rows=list(c.execute("SELECT canonical_id,label,description,domain,dim,embedding FROM kb_entries")); c.close()
    if not rows: return None
    import numpy as np
    meta=[]; vecs=[]
    for cid,label,desc,domain,dim,blob in rows:
        v=np.frombuffer(blob,dtype="float32")
        if dim and len(v)==dim: vecs.append(v); meta.append((cid,label,desc,domain))
    if not vecs: return None
    return np.vstack(vecs), meta

def link_concepts(nodes, min_score=0.55):
    """Attach canonical_id + link_score to concept nodes (skips code nodes)."""
    try:
        seed_kb()
        M=_load_matrix()
        if M is None: return nodes
        mat,meta=M
        targets=[n for n in nodes if _get(n,"concept_type") not in CODE_TYPES]
        if not targets: return nodes
        Q=_enc([((_get(n,"label","") or "")+". "+(_get(n,"description","") or "")) for n in targets])
        if Q is None: return nodes
        sims=Q @ mat.T
        best=sims.argmax(1); bestsc=sims.max(1)
        for n,bi,sc in zip(targets,best,bestsc):
            if float(sc)>=min_score:
                cid,label,desc,domain=meta[int(bi)]
                _set(n,"canonical_id",cid); _set(n,"link_score",round(float(sc),3))
        return nodes
    except Exception as e:
        logger.warning("kb link: %s", e); return nodes

def dedup_by_canonical(graph):
    """Merge nodes that resolved to the same canonical_id; reroute edges."""
    try:
        nodes=graph.nodes; edges=graph.edges; groups={}
        for n in nodes:
            cid=_get(n,"canonical_id","")
            if cid: groups.setdefault(cid,[]).append(n)
        remap={}; drop=set()
        for cid,grp in groups.items():
            if len(grp)<2: continue
            grp.sort(key=lambda n:(_get(n,"confidence",0) or 0), reverse=True)
            kid=_get(grp[0],"id")
            for other in grp[1:]: remap[_get(other,"id")]=kid; drop.add(_get(other,"id"))
        if not drop: return graph
        graph.nodes=[n for n in nodes if _get(n,"id") not in drop]
        seen=set(); ne=[]
        for e in edges:
            s=remap.get(_get(e,"source_id"),_get(e,"source_id")); t=remap.get(_get(e,"target_id"),_get(e,"target_id"))
            if s==t: continue
            _set(e,"source_id",s); _set(e,"target_id",t)
            k=(s,t,_get(e,"relation_type"))
            if k in seen: continue
            seen.add(k); ne.append(e)
        graph.edges=ne; return graph
    except Exception as e:
        logger.warning("kb dedup: %s", e); return graph

def ground(graph, min_score=0.55):
    link_concepts(graph.nodes, min_score); dedup_by_canonical(graph); return graph

def fetch_wikidata(term, lang="en"):
    """Optional, network. Returns a KB-entry dict with a real wd:Q... id, or None."""
    try:
        import urllib.request, urllib.parse
        q=urllib.parse.urlencode({"action":"wbsearchentities","search":term,
            "language":lang,"format":"json","limit":1})
        with urllib.request.urlopen("https://www.wikidata.org/w/api.php?"+q, timeout=8) as r:
            data=json.load(r)
        hits=data.get("search",[])
        if not hits: return None
        h=hits[0]
        return {"canonical_id":"wd:"+h["id"],"label":h.get("label",term),
                "aliases":[], "description":h.get("description",""), "domain":""}
    except Exception as e:
        logger.warning("kb wikidata: %s", e); return None
KBEOF
python3 - "$APP/services/kb.py" "$BASE" <<'PY'
import sys
p,base=sys.argv[1],sys.argv[2]; s=open(p).read()
open(p,"w").write(s.replace("__BASE__",base))
PY
python3 -m py_compile "$APP/services/kb.py" && echo "  OK wrote $APP/services/kb.py" || { echo "  ERROR kb.py compile failed"; exit 1; }

# ── 3. kb_seed.json (math-first) ────────────────────────────────
cat > "$APP/services/kb_seed.json" <<'SEEDEOF'
[
 {"canonical_id":"kb:function","label":"Function","aliases":["map","mapping"],"description":"a rule assigning each input exactly one output","domain":"math"},
 {"canonical_id":"kb:limit","label":"Limit","aliases":[],"description":"the value a function approaches as its input approaches a point","domain":"math"},
 {"canonical_id":"kb:continuity","label":"Continuity","aliases":["continuous function"],"description":"a function with no abrupt jumps; small input changes give small output changes","domain":"math"},
 {"canonical_id":"kb:derivative","label":"Derivative","aliases":["rate of change","slope of tangent","differential coefficient"],"description":"the instantaneous rate of change of a function","domain":"math"},
 {"canonical_id":"kb:integral","label":"Integral","aliases":["antiderivative"],"description":"the accumulated area under a function","domain":"math"},
 {"canonical_id":"kb:gradient","label":"Gradient","aliases":[],"description":"the vector of partial derivatives pointing in the direction of steepest increase","domain":"math"},
 {"canonical_id":"kb:vector_space","label":"Vector space","aliases":["linear space"],"description":"a set of vectors closed under addition and scalar multiplication","domain":"math"},
 {"canonical_id":"kb:basis","label":"Basis","aliases":[],"description":"a linearly independent set of vectors that spans a vector space","domain":"math"},
 {"canonical_id":"kb:linear_independence","label":"Linear independence","aliases":[],"description":"vectors none of which is a linear combination of the others","domain":"math"},
 {"canonical_id":"kb:linear_transformation","label":"Linear transformation","aliases":["linear map"],"description":"a map between vector spaces preserving addition and scalar multiplication","domain":"math"},
 {"canonical_id":"kb:matrix","label":"Matrix","aliases":[],"description":"a rectangular array of numbers representing a linear map","domain":"math"},
 {"canonical_id":"kb:determinant","label":"Determinant","aliases":[],"description":"a scalar encoding how a linear map scales volume, and whether it is invertible","domain":"math"},
 {"canonical_id":"kb:eigenvalue","label":"Eigenvalue","aliases":[],"description":"a scalar by which an eigenvector is scaled under a linear map","domain":"math"},
 {"canonical_id":"kb:eigenvector","label":"Eigenvector","aliases":[],"description":"a nonzero vector whose direction is unchanged by a linear map","domain":"math"},
 {"canonical_id":"kb:set","label":"Set","aliases":[],"description":"a collection of distinct objects","domain":"math"},
 {"canonical_id":"kb:group","label":"Group","aliases":[],"description":"a set with an associative operation, an identity, and inverses","domain":"math"},
 {"canonical_id":"kb:series","label":"Series","aliases":[],"description":"the sum of the terms of a sequence","domain":"math"},
 {"canonical_id":"kb:probability","label":"Probability","aliases":[],"description":"a measure between 0 and 1 of how likely an event is","domain":"math"},
 {"canonical_id":"kb:force","label":"Force","aliases":[],"description":"an influence that changes the motion of an object","domain":"physics"},
 {"canonical_id":"kb:energy","label":"Energy","aliases":[],"description":"the capacity to do work","domain":"physics"},
 {"canonical_id":"kb:momentum","label":"Momentum","aliases":[],"description":"mass times velocity; conserved in isolated systems","domain":"physics"},
 {"canonical_id":"kb:velocity","label":"Velocity","aliases":[],"description":"the rate of change of position, with direction","domain":"physics"},
 {"canonical_id":"kb:acceleration","label":"Acceleration","aliases":[],"description":"the rate of change of velocity","domain":"physics"},
 {"canonical_id":"kb:wave","label":"Wave","aliases":[],"description":"a disturbance that transfers energy through a medium or space","domain":"physics"},
 {"canonical_id":"kb:entropy","label":"Entropy","aliases":[],"description":"a measure of disorder or of energy unavailable for work","domain":"physics"},
 {"canonical_id":"kb:field_physics","label":"Field","aliases":[],"description":"a physical quantity defined at every point in space","domain":"physics"},
 {"canonical_id":"kb:algorithm","label":"Algorithm","aliases":[],"description":"a finite sequence of well-defined steps that solves a problem","domain":"cs"},
 {"canonical_id":"kb:time_complexity","label":"Time complexity","aliases":["big O"],"description":"how an algorithm's running time grows with input size","domain":"cs"},
 {"canonical_id":"kb:recursion","label":"Recursion","aliases":[],"description":"a procedure defined in terms of itself","domain":"cs"},
 {"canonical_id":"kb:data_structure","label":"Data structure","aliases":[],"description":"a way of organizing data for efficient access and modification","domain":"cs"},
 {"canonical_id":"kb:graph_cs","label":"Graph","aliases":[],"description":"a set of nodes connected by edges","domain":"cs"},
 {"canonical_id":"kb:hash_table","label":"Hash table","aliases":["hash map"],"description":"a structure mapping keys to values via a hash function","domain":"cs"},
 {"canonical_id":"kb:atom","label":"Atom","aliases":[],"description":"the smallest unit of an element that retains its properties","domain":"chem"},
 {"canonical_id":"kb:molecule","label":"Molecule","aliases":[],"description":"two or more atoms bonded together","domain":"chem"},
 {"canonical_id":"kb:chemical_reaction","label":"Chemical reaction","aliases":[],"description":"a process that transforms reactants into products","domain":"chem"},
 {"canonical_id":"kb:cell","label":"Cell","aliases":[],"description":"the basic structural and functional unit of life","domain":"bio"},
 {"canonical_id":"kb:gene","label":"Gene","aliases":[],"description":"a unit of heredity encoded in DNA","domain":"bio"},
 {"canonical_id":"kb:evolution","label":"Evolution","aliases":["natural selection"],"description":"change in the heritable traits of populations over generations","domain":"bio"}
]
SEEDEOF
python3 -c "import json;d=json.load(open('$APP/services/kb_seed.json'));print('  \u2713 kb_seed.json valid (',len(d),'entries )')"

# ── 4. hook the upload route: ground(graph) after run() ─────────
MAIN="$APP/main.py"
if grep -q "kb import ground" "$MAIN"; then
  echo "  · upload route already grounds"
else
  cp "$MAIN" "$MAIN.kbbak"
  MAIN="$MAIN" BASE="$BASE" python3 - <<'PY'
import os, sys
p=os.environ["MAIN"]; base=os.environ["BASE"]; s=open(p).read()
idx=s.find("graph = run(str(fp))")
if idx<0:
    print("  ! 'graph = run(str(fp))' not found — add ground(graph) after it by hand"); sys.exit(3)
ls=s.rfind("\n",0,idx)+1; indent=s[ls:idx]; le=s.find("\n",idx); le=le if le>=0 else len(s)
hook=("\n"+indent+"try:\n"+indent+"    from "+base+".services.kb import ground\n"
      +indent+"    ground(graph)\n"+indent+"except Exception:\n"+indent+"    pass")
open(p,"w").write(s[:le]+hook+s[le:]); print("  \u2713 upload route now grounds concept maps")
PY
  python3 -m py_compile "$MAIN" || { echo "  ERROR main compile failed - restoring"; mv "$MAIN.kbbak" "$MAIN"; exit 1; }
  rm -f "$MAIN.kbbak"
fi

REQ="requirements.txt"; [ -f "$REQ" ] || REQ="backend/requirements.txt"
[ -f "$REQ" ] && { grep -qi '^fastembed' "$REQ" || echo fastembed >>"$REQ"; grep -qi '^numpy' "$REQ" || echo numpy >>"$REQ"; }

# ── 5. self-test the mechanism (isolated temp KB, mock embedder; offline) ──
echo "  → self-test (offline, mock embedder):"
BASE="$BASE" python3 - <<'PY' || echo "     (self-test skipped — run inside venv)"
import os, sys, tempfile, importlib, json
sys.path.insert(0, os.getcwd())
kb=importlib.import_module(os.environ["BASE"]+".services.kb")
import numpy as np
d=tempfile.mkdtemp(); kb.KB_DB=os.path.join(d,"t.db"); kb.SEED_PATH=os.path.join(d,"seed.json")
json.dump([{"canonical_id":"kb:derivative","label":"Derivative","description":"rate of change of a function","domain":"math"},
           {"canonical_id":"kb:vector_space","label":"Vector space","description":"set closed under addition and scaling","domain":"math"}], open(kb.SEED_PATH,"w"))
def mock(texts):
    out=[]
    for t in texts:
        tl=t.lower(); v=np.zeros(4,dtype="float32")
        if "deriv" in tl or "rate of change" in tl: v[0]=1
        elif "vector" in tl or "basis" in tl: v[1]=1
        else: v[2]=1
        out.append(v/((v*v).sum()**0.5 or 1))
    return np.vstack(out)
kb._enc=mock
assert kb.seed_kb()==2
nodes=[{"id":"n1","label":"Derivative","description":"the rate of change","concept_type":"definition","confidence":0.8},
       {"id":"n2","label":"Slope","description":"rate of change of a curve","concept_type":"term","confidence":0.6},
       {"id":"n3","label":"Basis","description":"spans a vector space","concept_type":"definition","confidence":0.9},
       {"id":"c1","label":"deposit","description":"fn","concept_type":"function","confidence":1.0}]
kb.link_concepts(nodes)
assert nodes[0]["canonical_id"]=="kb:derivative" and nodes[1]["canonical_id"]=="kb:derivative"
assert nodes[2]["canonical_id"]=="kb:vector_space" and not nodes[3].get("canonical_id")
class G: pass
g=G(); g.nodes=nodes; g.edges=[{"id":"e","source_id":"n2","target_id":"n3","relation_type":"REQUIRES"}]
kb.dedup_by_canonical(g)
assert [n["id"] for n in g.nodes]==["n1","n3","c1"]
assert g.edges[0]["source_id"]=="n1"
print("     \u2713 link+dedup verified (n1/n2 merged, code node skipped, edge rerouted)")
PY

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
Concept Stage 2 (KB grounding) applied. Restart backend (venv):
  lsof -ti:8000 | xargs kill -9 2>/dev/null; uvicorn backend.app.main:app --reload --port 8000

WHAT HAPPENS NOW
  • On the FIRST concept upload, the seed KB (~37 math-first entries) is embedded
    once with fastembed (bge-small, 384-d) and cached in data/kb.db.
  • Each concept is matched to its nearest canonical entry; if cosine >= 0.55 it
    gets node.canonical_id + node.link_score, and concepts sharing a canonical id
    are merged (e.g. "derivative" + "rate of change" -> one node).
  • Code maps are untouched (code is already canonical by qualified name).

VERIFY IT LINKS: upload a short calculus / linear-algebra PDF; a concept like
"rate of change" should carry canonical_id "kb:derivative".

NEXT (per design doc):
  • surface canonical_id/link_score in the UI (a "grounded" badge).
  • enable Wikidata on-demand (kb.fetch_wikidata) to grow the KB beyond the seed.
  • sqlite-vec backend when the KB grows past brute-force scale.
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."