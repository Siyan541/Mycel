#!/usr/bin/env bash
# ============================================================================
# Mycel — unified, readable layout (concept + code) using domain/canonical signals
#
#   • App.jsx: conceptLayout — groups concepts into LANES by domain (from KB
#     grounding) else by concept_type, grids each group, then hard de-overlaps.
#     smartLayout dispatches: code maps -> codeLayout (tree), concept -> lanes.
#     Wired into upload/open load AND the Tidy action.
#   • kb.py: grounding now also sets node.cluster = domain, so math concepts
#     cluster together (and domain hulls form).
#
# Concept (textbook) maps stop being an organic hairball and read as labelled
# clusters. Code maps keep their tree. Run from repo ROOT (idempotent).
# ============================================================================
set -e
if   [ -f backend/app/main.py ]; then APP="backend/app";
elif [ -f app/main.py ];         then APP="app";
else echo "ERROR: run from repo root."; exit 1; fi
echo "→ backend: $APP"

# ── A. App.jsx: conceptLayout + smartLayout + wiring ────────────
FE=""
for c in frontend/src/App.jsx frontend/App.jsx src/App.jsx App.jsx; do [ -f "$c" ] && FE="$c" && break; done
[ -z "$FE" ] && FE="$(find . -name App.jsx -not -path '*/node_modules/*' 2>/dev/null | head -1)"
[ -z "$FE" ] && { echo "ERROR: App.jsx not found."; exit 1; }
echo "  → $FE"

if grep -q "function conceptLayout" "$FE"; then
  echo "  · conceptLayout already present"
else
  cp "$FE" "$FE.laybak"
  python3 - "$FE" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()

FUNCS = r'''function conceptLayout(nodes, edges){
  if(!nodes||nodes.length<2) return (nodes||[]).map(function(n){return Object.assign({},n,{x:n.x||0,y:n.y||0});});
  function gkey(n){ return String((n.cluster||n.domain||n.concept_type||"misc")); }
  var groups={}; nodes.forEach(function(n){ (groups[gkey(n)]=groups[gkey(n)]||[]).push(n); });
  var deg={}; (edges||[]).forEach(function(e){deg[e.source]=(deg[e.source]||0)+1;deg[e.target]=(deg[e.target]||0)+1;});
  var keys=Object.keys(groups).sort(function(a,b){return groups[b].length-groups[a].length;});
  var CW=210, CH=130, LANE_PAD=150, ROW_PAD=180, pos={}, gw={}, gh={}, gc={};
  keys.forEach(function(k){var m=groups[k].length;var c=Math.max(1,Math.ceil(Math.sqrt(m)));gc[k]=c;gw[k]=c*CW;gh[k]=Math.ceil(m/c)*CH;});
  var maxRowW=Math.max(900, Math.sqrt(nodes.length)*280);
  var x=0,y=0,rowH=0;
  keys.forEach(function(k){
    if(x>0 && x+gw[k]>maxRowW){ x=0; y+=rowH+ROW_PAD; rowH=0; }
    var c=gc[k], members=groups[k].slice().sort(function(a,b){return (deg[b.id]||0)-(deg[a.id]||0);});
    members.forEach(function(n,i){ pos[n.id]={x:x+(i%c)*CW, y:y+Math.floor(i/c)*CH}; });
    x+=gw[k]+LANE_PAD; rowH=Math.max(rowH,gh[k]);
  });
  var laid=nodes.map(function(n){var p=pos[n.id]||{x:0,y:0};return Object.assign({},n,{x:p.x,y:p.y});});
  return separateOverlaps(laid,'brief',140);
}
function smartLayout(nodes, edges){
  if(nodes && nodes.some(function(n){return n.concept_type==='module'||n.concept_type==='function'||n.concept_type==='parameter';}))
    return (typeof codeLayout==='function')?codeLayout(nodes,edges):conceptLayout(nodes,edges);
  return conceptLayout(nodes,edges);
}

'''
anchor="function organizedLayout(nodes, edges, density) {"
if anchor not in s: print("  X organizedLayout anchor not found"); sys.exit(3)
s=s.replace(anchor, FUNCS+anchor, 1)

# route load paths + Tidy through smartLayout
load_old="organizedLayout(organicLayout(r.nodes,edgesN),edgesN,'brief')"
load_new="smartLayout(organicLayout(r.nodes,edgesN),edgesN)"
nload=s.count(load_old); s=s.replace(load_old, load_new)
tidy_old="organizedLayout(nodes,edges,curDensity())"
tidy_new="smartLayout(nodes,edges)"
ntidy=s.count(tidy_old); s=s.replace(tidy_old, tidy_new)

open(p,"w").write(s)
print(f"  OK conceptLayout+smartLayout added; wired {nload} load path(s) + {ntidy} tidy action(s)")
PY
  if command -v node >/dev/null 2>&1; then
    cp "$FE" /tmp/_cl.mjs; node --check /tmp/_cl.mjs 2>/dev/null && echo "  OK App.jsx parses" || { echo "  X parse failed — restoring"; mv "$FE.laybak" "$FE"; exit 1; }
    rm -f /tmp/_cl.mjs
  fi
  rm -f "$FE.laybak"
fi

# ── B. kb.py: grounding sets cluster = domain ───────────────────
KB="$APP/services/kb.py"
if [ ! -f "$KB" ]; then
  echo "  !  kb.py not found — run apply_concept_stage2_kb.sh first (layout still works, groups by type)."
elif grep -q '_set(n,"cluster",domain)' "$KB"; then
  echo "  · kb.py already sets cluster=domain"
else
  cp "$KB" "$KB.laybak"
  python3 - "$KB" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
OLD='                _set(n,"canonical_id",cid); _set(n,"link_score",round(float(sc),3))'
NEW=OLD+'\n                if domain: _set(n,"cluster",domain)'
if s.count(OLD)!=1: print("  ! kb link line not unique — set cluster=domain by hand"); sys.exit(0)
open(p,"w").write(s.replace(OLD,NEW,1)); print("  OK kb.py: grounding now sets cluster=domain")
PY
  python3 -m py_compile "$KB" && echo "  OK kb.py compiles" || { echo "  X kb.py compile failed — restoring"; mv "$KB.laybak" "$KB"; exit 1; }
  rm -f "$KB.laybak"
fi

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
Unified layout applied. Frontend hot-reloads; restart backend if kb.py changed:
  lsof -ti:8000 | xargs kill -9 2>/dev/null; uvicorn backend.app.main:app --reload --port 8000

WHAT CHANGES
  • Concept maps now load as labelled CLUSTERS (lanes) instead of an organic
    hairball: grouped by domain when grounded (math / physics / CS / …), else by
    concept type; each cluster is a tidy grid; hard de-overlap guarantees no
    stacking. Hubs (most-connected concepts) sit first in each cluster.
  • Code maps keep the containment tree (smartLayout auto-detects).
  • "Tidy" now uses the same smart layout, so you can re-cluster any time.
  • Re-upload the linear-algebra chapter (or press Tidy on the existing map) to
    see it reorganize.

STILL ON THE UI LIST (design doc § Code mode + concept):
  • cross-cluster link emphasis (the edges the learning research rewards)
  • collapse/expand a cluster; per-cluster hull labels
  • legend switches to code-entity types on code maps
  • dependency-only view for large code files
Tell me which next.
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."