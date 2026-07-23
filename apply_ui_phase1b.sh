#!/usr/bin/env bash
# ============================================================================
# Mycel — UI Phase 1b: importance emphasis (mind-map hierarchy)
#
# Scale each concept node by its importance (degree) so the hubs — the ideas the
# rest hang off — are visibly LARGER and the leaf details are smaller, the way a
# hand-drawn course map anchors on a few big concepts. Layout spacing is widened
# to give the enlarged hubs room, so nothing collides.
#
# Pairs with apply_concept_quality.sh (which makes degree meaningful). Frontend
# hot-reloads. Run from repo ROOT (idempotent).
# ============================================================================
set -e
FE=""
for c in frontend/src/App.jsx frontend/App.jsx src/App.jsx App.jsx; do [ -f "$c" ] && FE="$c" && break; done
[ -z "$FE" ] && FE="$(find . -name App.jsx -not -path '*/node_modules/*' 2>/dev/null | head -1)"
[ -z "$FE" ] && { echo "ERROR: App.jsx not found."; exit 1; }
echo "→ $FE"

if grep -q "cam.z\*imp" "$FE"; then
  echo "  · importance emphasis already applied"; echo "✓ done."; exit 0
fi

cp "$FE" "$FE.p1bbak"
python3 - "$FE" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read(); n=0

# 1) compute an importance factor per node (0.85 leaf .. 1.30 hub) from degree
o1="var sbox=shapeBox(shp,n.w,totalH);"
n1=o1+"var imp=0.85+(deg[n.id]||0)/Math.max(maxDeg,1)*0.45;"
if s.count(o1)==1: s=s.replace(o1,n1); n+=1
else: print("  ! sbox anchor not unique")

# 2) scale the whole node group by importance (box + text together, no overflow)
o2='transform:"translate("+sx2+","+sy2+") scale("+cam.z+")"'
n2='transform:"translate("+sx2+","+sy2+") scale("+(cam.z*imp)+")"'
if s.count(o2)==1: s=s.replace(o2,n2); n+=1
else: print("  ! node transform anchor not unique")

# 3) widen concept-layout spacing so enlarged hubs have room (skip if conceptLayout absent)
o3="var CW=210, CH=130,"
n3="var CW=245, CH=165,"
if s.count(o3)==1: s=s.replace(o3,n3); n+=1
elif s.count(o3)==0: print("  · conceptLayout not present — spacing bump skipped (run apply_concept_layout.sh)")
else: print("  ! CW anchor not unique")

open(p,"w").write(s)
print("  OK applied %d edit(s)" % n)
if n<2: sys.exit(4)   # need at least the imp + transform edits
PY
rc=$?

if command -v node >/dev/null 2>&1; then
  cp "$FE" /tmp/_p1b.mjs
  node --check /tmp/_p1b.mjs 2>/dev/null && echo "  OK App.jsx parses" || { echo "  X parse failed — restoring"; mv "$FE.p1bbak" "$FE"; exit 1; }
  rm -f /tmp/_p1b.mjs
fi
[ "$rc" = "4" ] && { echo "  X core edits missed — restoring"; mv "$FE.p1bbak" "$FE"; exit 1; }
rm -f "$FE.p1bbak"

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
UI Phase 1b applied (frontend hot-reloads). Reload the map:
  • Key concepts (the well-connected hubs) now render visibly LARGER; leaf
    details shrink — the map gains the size-hierarchy of a hand-drawn course map.
  • Concept-layout spacing widened so the enlarged hubs don't collide; press
    Tidy if you want to re-space an existing map.
  • Combine with apply_concept_quality.sh so degree reflects real structure,
    and with UI Phase 1 (edge fade + cluster labels) for the full effect.

Best next UI (from the proposal): docked inspector + true semantic-zoom
(collapse each cluster to one labelled bubble at low zoom, expand on zoom-in).
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."