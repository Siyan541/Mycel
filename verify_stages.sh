#!/bin/bash
# Mycel — verify Stage 0 + Stage 1 implementation against design-doc v2 criteria.
# Read-only: inspects your code + runs offline smoke tests. Run from repo root.
set -e
echo "🍄 Mycel — stage implementation check (design doc v2)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f backend/app/main.py ]; then
  echo "  ✗ Run from repo root (backend/app/main.py not found)."; exit 1
fi
export APP="backend/app"
export MEDIA="$APP/services/media.py"
for sub in services routes; do [ -f "$APP/$sub/media.py" ] && export MEDIA="$APP/$sub/media.py"; done
export REQ="requirements.txt"; [ -f "$REQ" ] || export REQ="backend/requirements.txt"
[ -f "$REQ" ] || export REQ=""

python3 - << 'PY'
import os, re, sys, importlib.util
APP=os.environ["APP"]; MEDIA=os.environ["MEDIA"]; REQ=os.environ.get("REQ","")

def read(p):
    try: return open(p, encoding="utf-8").read()
    except Exception: return ""
models=read(f"{APP}/models.py"); extractor=read(f"{APP}/pipeline/extractor.py")
chunker=read(f"{APP}/pipeline/chunker.py"); validator=read(f"{APP}/pipeline/validator.py")
media=read(MEDIA); req=read(REQ) if REQ else ""

def cls(src,name):
    m=re.search(rf"^class {name}\b.*?(?=^class |\Z)", src, re.S|re.M)
    return m.group(0) if m else ""

R=[]  # (stage,id,desc,ok(True/False/None=skip),detail)
def ck(stage,cid,desc,ok,detail=""): R.append((stage,cid,desc,ok,detail))

# ── Stage 0 — extraction quality (0–1 confidence, constrained JSON) ──
c=cls(models,"Concept")
ck("0","S0.1","Concept.confidence is 0–1 float (not int 1–10)",
   ("confidence: float" in c and "ge=0" in c and "confidence: int" not in c))
ck("0","S0.2","Concept has in_text flag", "in_text" in c)
r=cls(models,"Relation")
ck("0","S0.3","Relation repaired (label keys, one confidence, no 'relates_to')",
   ("source_label" in r and 'relation_type: str = "relates_to"' not in r and r.count("confidence")==1))
ck("0","S0.4","extractor calls chat with json_schema", "json_schema=JOINT_SCHEMA" in extractor)
ck("0","S0.5","schema confidence is number 0–1",
   ('"type": "number"' in extractor and '"maximum": 1' in extractor))
ck("0","S0.6","few-shot example in prompt", "WORKED EXAMPLE" in extractor)
ck("0","S0.7","fuzzy relation-endpoint resolve (>=85)", ("_resolve(" in extractor and ">= 85" in extractor))
ck("0","S0.8","confidence normalizer _conf present", "def _conf" in extractor)
ck("0","S0.9","chunker one-paragraph overlap", "current[-1]" in chunker)
ck("0","S0.10","validator has NO /10 rescale", ("/10.0" not in validator and "/ 10" not in validator and validator!=""))
ck("0","S0.11","validator filters at 0.45", "0.45" in validator)

# ── Stage 1 — explainable PDF splitter (embedding provenance) ──
e=cls(models,"GraphEdge")
ck("1","S1.1","GraphEdge has page + evidence", ("page" in e and "evidence" in e))
n=cls(models,"GraphNode")
ck("1","S1.2","GraphNode has source_score + mentions", ("source_score" in n and "mentions" in n))
ck("1","S1.3","media has embedder w/ fallback", ("_embedder" in media and "fastembed" in media))
ck("1","S1.4","provenance sets source_score + mentions", ("source_score" in media and "mentions" in media))
ck("1","S1.5","relation provenance writes evidence",
   ("attach_relation_provenance" in media and re.search(r'_set\(e,\s*["\']evidence', media) is not None))
ck("1","S1.6","requirements include fastembed", ("fastembed" in req) if req else None)

# ── functional smoke tests (offline; SKIP if deps missing) ──
sys.path.insert(0, os.getcwd())
try:
    from backend.app.models import Concept, Relation, RelationType, ConceptType
    from backend.app.pipeline.validator import validate
    hi =Concept(label="Basis",description="A spanning independent set.",concept_type=ConceptType.definition,abstraction_level=1,confidence=0.9,source_quote="A basis",in_text=True)
    hi2=Concept(label="Vector space",description="Set closed under addition.",concept_type=ConceptType.definition,abstraction_level=0,confidence=0.95,in_text=True)
    lo =Concept(label="Trivia",description="please drop me now ok",concept_type=ConceptType.term,abstraction_level=3,confidence=0.30,in_text=False)
    rel=Relation(source_label="Basis",target_label="Vector space",relation_type=RelationType.PART_OF,justification="x",evidence="basis spans the space",confidence=0.85)
    g=validate([hi,hi2,lo],[rel],"doc")
    ok=(abs(g.edges[0].confidence-0.85)<1e-6 and all(x.label!="Trivia" for x in g.nodes) and bool(g.edges[0].evidence))
    ck("0","F0","validate: 0–1 conf kept, <0.45 dropped, edge evidence carried", ok, f"edge_conf={g.edges[0].confidence}")
except Exception as ex:
    ck("0","F0","functional: validate() smoke test", None, f"skipped: {type(ex).__name__}: {ex}")

try:
    spec=importlib.util.spec_from_file_location("mycel_media", MEDIA)
    M=importlib.util.module_from_spec(spec); spec.loader.exec_module(M)
    M._page_texts=lambda p:["A vector space is a set closed under addition. The basis spans the vector space."]
    M._embedder=lambda:None   # force token-overlap fallback (offline, fast)
    nodes=[{"id":"n1","label":"Vector space","description":"a set closed under addition"},
           {"id":"n2","label":"Basis","description":"a spanning set"}]
    M.attach_provenance(nodes,"x.pdf")
    ok_p=bool(nodes[0].get("source_page") and nodes[0].get("source_quote") and nodes[0].get("source_score") is not None and nodes[0].get("mentions"))
    edges=[{"id":"e1","source_id":"n1","target_id":"n2"}]
    M.attach_relation_provenance(edges,nodes,"x.pdf")
    ok_r=bool(edges[0].get("evidence"))
    ck("1","F1","provenance sets page/quote/score/mentions + edge evidence", ok_p and ok_r, f"score={nodes[0].get('source_score')}")
except Exception as ex:
    ck("1","F1","functional: provenance smoke test", None, f"skipped: {type(ex).__name__}: {ex}")

# ── report ──
cur=None; p=f=s=0
print()
for stage,cid,desc,ok,detail in R:
    if stage!=cur: print(f"  ── Stage {stage} ──"); cur=stage
    if ok is True: tag="\033[32m[PASS]\033[0m"; p+=1
    elif ok is False: tag="\033[31m[FAIL]\033[0m"; f+=1
    else: tag="\033[33m[SKIP]\033[0m"; s+=1
    line=f"  {tag} {cid:6s} {desc}"
    if detail and ok is not True: line+=f"\n           → {detail}"
    print(line)
print(f"\n  {p} passed · {f} failed · {s} skipped")
if f: print("  ✗ Some criteria not met — see [FAIL] lines above.")
else: print("  ✓ Stage 0 + Stage 1 criteria met (skips are env-only, not failures).")
sys.exit(1 if f else 0)
PY

cat <<'NOTE'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOT AUTO-CHECKED — verify these by hand / plan next:

STAGE 1 frontend follow-up (backend already sends the data):
  [ ] PDFViewer shows node.source_score as a match-strength badge
  [ ] "ref k/N" stepper is driven by node.mentions (all sentences, not just best)
  [ ] in_text=false concepts render as "assumed / not defined here"
  live check: upload a PDF where a concept is paraphrased in the text →
             the highlight lands on the real definition sentence.

STAGE 2 — canonical KB grounding (target criteria):
  [ ] sqlite-vec table exists; concepts get canonical_id + link_score
  [ ] dedup uses canonical_id (not just 82% fuzzy)
  [ ] KB seed loaded (intro STEM + liberal arts) + on-demand Wikidata cache
  [ ] embedding dim locked at 384 (same model as Stage 1)

STAGE 3 — deterministic extraction (target criteria):
  [ ] GLiNER concept extractor selectable via provider switch
  [ ] REBEL + Hearst relations; output flows through Stage 1/2 unchanged
  [ ] same input → identical output (reproducible), runs CPU-only

STAGE 4 — fine-tuning (target criteria):
  [ ] gold set = confirmed concept→sentence corrections + confirmed maps
  [ ] L0–L5 complexity ladder annotated (eval set)
  [ ] specialized model beats stock 7B on the ladder

STAGE 5 — cross-map fusion (target criteria):
  [ ] same-textbook merge by canonical_id (ship first)
  [ ] cross-author merge is confirm-gated; viewpoints kept parallel
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOTE