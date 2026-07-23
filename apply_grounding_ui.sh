#!/usr/bin/env bash
# ============================================================================
# Mycel — (b) surface KB grounding in the UI + Wikidata on-demand
#
#   A. App.jsx  : the node inspector shows a "grounded" badge with canonical_id
#                 + link_score whenever a concept linked to the KB.
#   B. kb.py    : optional Wikidata fallback for concepts the seed KB misses —
#                 OFF by default; enable with  export KB_WIKIDATA=1  (makes one
#                 network call per unlinked concept, so it is slow / opt-in).
#
# Run from repo ROOT:  bash apply_grounding_ui.sh   (idempotent)
# ============================================================================
set -e
if   [ -f backend/app/main.py ]; then APP="backend/app";
elif [ -f app/main.py ];         then APP="app";
else echo "ERROR: run from repo root."; exit 1; fi
echo "→ backend: $APP"

# ── A. App.jsx grounded badge ───────────────────────────────────
FE=""
for c in frontend/src/App.jsx frontend/App.jsx src/App.jsx App.jsx; do [ -f "$c" ] && FE="$c" && break; done
[ -z "$FE" ] && FE="$(find . -name App.jsx -not -path '*/node_modules/*' 2>/dev/null | head -1)"
if [ -n "$FE" ]; then
  if grep -q "selN.canonical_id" "$FE"; then
    echo "  · App.jsx already shows grounded badge"
  else
    cp "$FE" "$FE.gbak"
    python3 - "$FE" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
OLD='selN.description||"Click to add description"),'
BADGE=('selN.description||"Click to add description"),\n'
       '        (selN.canonical_id)?h("div",{style:{display:"flex",alignItems:"center",gap:5,'
       'marginBottom:6,padding:"3px 8px",background:"rgba(0,184,169,0.10)",'
       'border:"1px solid rgba(0,184,169,0.35)",borderRadius:6,fontSize:10.5,color:"#0A9E90"}},'
       'h("span",{style:{fontWeight:700}},"grounded"),'
       'h("span",{style:{opacity:0.85,fontFamily:"monospace"}},selN.canonical_id),'
       'h("span",{style:{marginLeft:"auto",opacity:0.7}},Math.round((selN.link_score||0)*100)+"%")):null,')
if s.count(OLD)!=1:
    print("  ! description anchor not unique — add the grounded badge by hand"); sys.exit(3)
open(p,"w").write(s.replace(OLD,BADGE,1)); print("  OK App.jsx: grounded badge added to inspector")
PY
    if command -v node >/dev/null 2>&1; then
      cp "$FE" /tmp/_g.mjs; node --check /tmp/_g.mjs 2>/dev/null && echo "  OK App.jsx parses" || { echo "  ERROR App.jsx parse failed — restoring"; mv "$FE.gbak" "$FE"; exit 1; }
      rm -f /tmp/_g.mjs
    fi
    rm -f "$FE.gbak"
  fi
else
  echo "  !  App.jsx not found — skipping UI part."
fi

# ── B. kb.py Wikidata on-demand (opt-in) ────────────────────────
KB="$APP/services/kb.py"
if [ ! -f "$KB" ]; then
  echo "  !  kb.py not found — run apply_concept_stage2_kb.sh first."
elif grep -q "KB_WIKIDATA" "$KB"; then
  echo "  · kb.py already has Wikidata fallback"
else
  cp "$KB" "$KB.gbak"
  python3 - "$KB" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
ANCHOR='                _set(n,"canonical_id",cid); _set(n,"link_score",round(float(sc),3))\n        return nodes'
BLOCK=(
'                _set(n,"canonical_id",cid); _set(n,"link_score",round(float(sc),3))\n'
'        if os.environ.get("KB_WIKIDATA","")=="1":\n'
'            import numpy as np, json as _json\n'
'            for n in targets:\n'
'                if _get(n,"canonical_id"): continue\n'
'                ent=fetch_wikidata(_get(n,"label","") or "")\n'
'                if not ent: continue\n'
'                ev=_enc([ent["label"]+". "+(ent.get("description","") or "")])\n'
'                if ev is None: continue\n'
'                c=_conn(); c.execute("INSERT OR REPLACE INTO kb_entries VALUES (?,?,?,?,?,?,?)",\n'
'                    (ent["canonical_id"],ent["label"],_json.dumps([]),ent.get("description",""),\n'
'                     ent.get("domain",""),len(ev[0]),np.asarray(ev[0],dtype="float32").tobytes()))\n'
'                c.commit(); c.close()\n'
'                q=_enc([((_get(n,"label","") or "")+". "+(_get(n,"description","") or ""))])\n'
'                if q is None: continue\n'
'                s2=float(q[0] @ ev[0])\n'
'                if s2>=min_score: _set(n,"canonical_id",ent["canonical_id"]); _set(n,"link_score",round(s2,3))\n'
'        return nodes')
if ANCHOR not in s:
    print("  ! kb.py link loop anchor not found — Wikidata fallback not added (UI badge still applied)"); sys.exit(0)
open(p,"w").write(s.replace(ANCHOR,BLOCK,1)); print("  OK kb.py: Wikidata fallback added (opt-in via KB_WIKIDATA=1)")
PY
  python3 -m py_compile "$KB" && echo "  OK kb.py compiles" || { echo "  ERROR kb.py compile failed — restoring"; mv "$KB.gbak" "$KB"; exit 1; }
  rm -f "$KB.gbak"
fi

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
(b) applied. Frontend hot-reloads; restart backend if kb.py changed:
  lsof -ti:8000 | xargs kill -9 2>/dev/null; uvicorn backend.app.main:app --reload --port 8000

  • Select a concept → if it linked to the KB, the inspector shows a green
    "grounded  kb:derivative  87%" badge (canonical id + link score).
  • Your linear-algebra chapter should ground many concepts against the math
    seed already — no Wikidata needed. To grow coverage beyond the seed:
        export KB_WIKIDATA=1     # before starting uvicorn (slow: 1 web call/miss)

⚠ RECOMMENDED NEXT (the real blocker in your screenshots): the concept-map
  LAYOUT. A full chapter renders as an overlapping hairball because textbook
  maps still use organicLayout. A readable layout (cluster by grounded domain /
  type into lanes, spread by force with hard de-overlap, collapse leaf concepts)
  would do far more for usability than any badge. Say the word and I'll build it.
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."