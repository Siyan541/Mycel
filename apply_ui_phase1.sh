#!/usr/bin/env bash
# ============================================================================
# Mycel — UI Phase 1 (legibility): edge fade + cluster labels
#
#   1. Edges fade by default. Only selected/hovered edges and CROSS-CLUSTER
#      links (where the learning lives) are drawn boldly; intra-cluster clutter
#      recedes. When zoomed out, edges fade further so the map reads as clusters.
#   2. Cluster hulls get a NAME label (domain when grounded, else concept type),
#      giving an overview — the map's "table of contents" in place.
#   3. Hull grouping aligned to the layout's grouping (cluster || concept_type).
#
# This is the highest-impact, lowest-risk slice of the UI proposal. Docked
# inspector + full cluster-collapse are the next slice.
#
# Run from repo ROOT:  bash apply_ui_phase1.sh   (idempotent)
# ============================================================================
set -e
FE=""
for c in frontend/src/App.jsx frontend/App.jsx src/App.jsx App.jsx; do [ -f "$c" ] && FE="$c" && break; done
[ -z "$FE" ] && FE="$(find . -name App.jsx -not -path '*/node_modules/*' 2>/dev/null | head -1)"
[ -z "$FE" ] && { echo "ERROR: App.jsx not found (run from repo root)."; exit 1; }
echo "→ $FE"

if grep -q "s.cluster!==t.cluster" "$FE"; then
  echo "  · UI Phase 1 already applied"; echo "✓ done."; exit 0
fi

cp "$FE" "$FE.p1bak"
python3 - "$FE" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read(); n=0

# 1. edge base opacity: fade intra-cluster, emphasize cross-cluster + selected
o1="(hi?0.9:0.55)"
n1="(hi?0.95:((s.cluster&&t.cluster&&s.cluster!==t.cluster)?0.5:0.18))"
if s.count(o1)==1: s=s.replace(o1,n1); n+=1
else: print("  ! edge opacity anchor not unique")

# 2. fade edges further when zoomed out (clean cluster overview)
o2="*(dimE?0.16:1)"
n2="*(dimE?0.16:1)*(cam.z<0.5&&!hi?0.4:1)"
if s.count(o2)==1: s=s.replace(o2,n2); n+=1
else: print("  ! edge dim-tail anchor not unique")

# 3. hull labels
o3='return h("path",{key:hl.key,d:hl.d,fill:gc?(gc+"14"):P.hullFill,stroke:gc||P.hullStroke,strokeWidth:studyMode===\'soil\'?1.5:1,transform:"translate("+cam.x+","+cam.y+") scale("+cam.z+")"});'
n3=('return h("g",{key:hl.key},'
    'h("path",{d:hl.d,fill:gc?(gc+"14"):P.hullFill,stroke:gc||P.hullStroke,strokeWidth:studyMode===\'soil\'?1.5:1,transform:"translate("+cam.x+","+cam.y+") scale("+cam.z+")"}),'
    'h("text",{x:hl.lx*cam.z+cam.x,y:hl.ly*cam.z+cam.y,textAnchor:"middle",fontSize:Math.max(11,15*cam.z),fontWeight:700,fill:(gc||P.hullStroke),opacity:0.6,style:{pointerEvents:"none",fontFamily:"\'Inter\',sans-serif",textTransform:"capitalize"}},String(hl.key).replace(/_/g," ")));')
if s.count(o3)==1: s=s.replace(o3,n3); n+=1
else: print("  ! hull render anchor not unique")

# 4. hull grouping aligned to layout (cluster || concept_type)
o4="var c=n.cluster||'x';"
n4="var c=n.cluster||n.concept_type||'x';"
if s.count(o4)==1: s=s.replace(o4,n4); n+=1
else: print("  ! hull key anchor not unique")

open(p,"w").write(s)
print("  OK applied %d/4 Phase-1 edits" % n)
if n<4: sys.exit(4)
PY
rc=$?

if command -v node >/dev/null 2>&1; then
  cp "$FE" /tmp/_p1.mjs
  node --check /tmp/_p1.mjs 2>/dev/null && echo "  OK App.jsx parses" || { echo "  X parse failed — restoring"; mv "$FE.p1bak" "$FE"; exit 1; }
  rm -f /tmp/_p1.mjs
fi
[ "$rc" = "4" ] && { echo "  X some edits missed — restoring"; mv "$FE.p1bak" "$FE"; exit 1; }
rm -f "$FE.p1bak"

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
UI Phase 1 applied (frontend hot-reloads). Reload the map:

  • Edges no longer form a hairball at rest — intra-cluster links are faint;
    cross-cluster links (the integration the learning research rewards) and the
    selected/hovered concept's links stand out. Zoom out and edges recede so you
    see the CLUSTER SHAPE of the chapter.
  • Each cluster now carries a NAME label (its domain when grounded, e.g. "Math",
    else its concept type) — an at-a-glance table of contents.
  • Selecting a concept still brings its own links forward.

NEXT UI SLICES (from the proposal):
  • docked side Inspector (stop the card from covering the canvas)
  • true semantic zoom: collapse each cluster to one bubble at low zoom, expand
    on zoom-in (a whole chapter = ~6 domain bubbles)
  • outline/cluster panel + minimap + legend-as-filter; code structure/dependency toggle
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."