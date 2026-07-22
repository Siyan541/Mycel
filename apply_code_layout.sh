#!/usr/bin/env bash
# ============================================================================
# Mycel Code — hierarchical layout for code maps
#
# Replaces the organic scatter with a tidy containment TREE for code maps:
#   module (top) -> classes / top-level functions -> methods -> parameters,
# following CONTAINS edges. CALLS/INHERITS/etc. overlay as curves.
# Concept (textbook) maps are untouched — they still use organicLayout.
#
# Run from repo ROOT:  bash apply_code_layout.sh   (idempotent)
# ============================================================================
set -e
FE=""
for c in frontend/src/App.jsx frontend/App.jsx src/App.jsx App.jsx; do [ -f "$c" ] && FE="$c" && break; done
[ -z "$FE" ] && FE="$(find . -name App.jsx -not -path '*/node_modules/*' 2>/dev/null | head -1)"
[ -z "$FE" ] && { echo "ERROR: App.jsx not found (run from repo root)."; exit 1; }
echo "→ $FE"

if grep -q "function codeLayout" "$FE"; then
  echo "  · codeLayout already present — skipping."; echo "✓ done."; exit 0
fi

cp "$FE" "$FE.laybak"
FE="$FE" python3 - <<'PY'
import os, sys
p = os.environ["FE"]; s = open(p).read(); orig = s

CODE_LAYOUT = r'''function codeLayout(nodes, edges){
  var byId={}; nodes.forEach(function(n){byId[n.id]=n;});
  var kids={}, parent={};
  (edges||[]).forEach(function(e){
    var rt=e.relation_type; if(rt&&rt.value)rt=rt.value;
    if(rt==='CONTAINS'&&byId[e.source]&&byId[e.target]&&parent[e.target]==null){
      (kids[e.source]=kids[e.source]||[]).push(e.target); parent[e.target]=e.source;
    }
  });
  var GAP=30, Y=160, wmemo={};
  function subW(id, guard){
    if(wmemo[id]!=null) return wmemo[id];
    guard=guard||{}; if(guard[id]) return (byId[id]&&byId[id].w)||160; guard[id]=1;
    var n=byId[id], w=(n&&n.w)||160, ch=kids[id]||[];
    if(!ch.length){ wmemo[id]=w; return w; }
    var cw=0; ch.forEach(function(c,i){ cw+=subW(c,guard)+(i?GAP:0); });
    var r=Math.max(w,cw); wmemo[id]=r; return r;
  }
  var pos={};
  function place(id,left,depth,guard){
    guard=guard||{}; if(guard[id])return; guard[id]=1;
    var n=byId[id], w=(n&&n.w)||160, ch=kids[id]||[], sw=subW(id);
    if(!ch.length){ pos[id]={x:left+w/2,y:depth*Y}; return; }
    var total=0; ch.forEach(function(c,i){ total+=subW(c)+(i?GAP:0); });
    var cx=left+(sw-total)/2, centers=[];
    ch.forEach(function(c){ var cw2=subW(c); place(c,cx,depth+1,guard); centers.push(cx+cw2/2); cx+=cw2+GAP; });
    pos[id]={x:(centers[0]+centers[centers.length-1])/2, y:depth*Y};
  }
  var roots=[]; nodes.forEach(function(n){ if(parent[n.id]==null) roots.push(n.id); });
  roots.sort(function(a,b){ return ((byId[b].concept_type==='module')?1:0)-((byId[a].concept_type==='module')?1:0); });
  var cursor=0;
  roots.forEach(function(rid){ var sw=subW(rid); place(rid,cursor,0,{}); cursor+=sw+80; });
  nodes.forEach(function(n){ if(!pos[n.id]){ pos[n.id]={x:cursor,y:0}; cursor+=((n.w)||160)+GAP; } });
  return nodes.map(function(n){ return Object.assign({},n,{x:pos[n.id].x,y:pos[n.id].y}); });
}

'''

anchor = "function organizedLayout(nodes, edges, density) {"
if anchor not in s:
    print("  \u2717 organizedLayout anchor not found — aborting."); sys.exit(3)
s = s.replace(anchor, CODE_LAYOUT + anchor, 1)

OLD = "organizedLayout(organicLayout(r.nodes,edgesN),edgesN,'brief')"
NEW = ("(r.nodes.some(function(_n){return _n.concept_type==='module';})"
       "?codeLayout(organicLayout(r.nodes,edgesN),edgesN)"
       ":organizedLayout(organicLayout(r.nodes,edgesN),edgesN,'brief'))")
cnt = s.count(OLD)
if cnt == 0:
    print("  \u2717 load-path call not found — aborting."); sys.exit(3)
s = s.replace(OLD, NEW)
print(f"  \u2713 inserted codeLayout; wrapped {cnt} load path(s) to use it for code maps")

open(p, "w").write(s)
PY
rc=$?
[ "$rc" = "3" ] && { echo "  (aborted, restoring)"; mv "$FE.laybak" "$FE"; exit 1; }

if command -v node >/dev/null 2>&1; then
  cp "$FE" /tmp/_app_check.mjs
  node --check /tmp/_app_check.mjs 2>/dev/null && echo "  ✓ App.jsx parses" || { echo "  ✗ parse failed — restoring"; mv "$FE.laybak" "$FE"; exit 1; }
  rm -f /tmp/_app_check.mjs
fi
rm -f "$FE.laybak"

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
Code maps now lay out as a containment tree (frontend hot-reloads):
  module (top) → classes / top-level functions → methods → parameters
CALLS / INHERITS / HAS_TYPE / READS overlay as curves on top.
Concept (textbook) maps are unchanged.

Re-open your code map (re-upload example_code_test.py, or open the saved one)
and the parameters will sit under their functions, methods under their class,
and the module at the top — matching the actual code structure.

Tip: hit "Tidy" / fit-to-view after load if you want to recenter.
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."