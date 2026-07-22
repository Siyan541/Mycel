#!/usr/bin/env bash
# ============================================================================
# Mycel Code — Stage 3 (code theme) + storage save fix
#
#   A. FIX: /api/maps/{id}/graph 500 — storage.update_map_state connected to the
#      DATA_DIR *directory* instead of the app.db file ("unable to open database").
#   B. UI: theme.js — give each code entity type a distinct colour, and classify
#      code relations so edges render with meaningful colour + arrows.
#
# Run from repo ROOT:  bash apply_mycel_code_stage3.sh   (idempotent)
# ============================================================================
set -e
if   [ -f backend/app/main.py ]; then APP="backend/app";
elif [ -f app/main.py ];         then APP="app";
else echo "ERROR: run from repo root."; exit 1; fi

# ── A. storage save fix ─────────────────────────────────────────
STORE="$APP/services/storage.py"; [ -f "$STORE" ] || STORE="$APP/storage.py"
if [ -f "$STORE" ]; then
  if grep -q "sqlite3.connect(DATA_DIR)" "$STORE"; then
    cp "$STORE" "$STORE.bak"
    python3 - "$STORE" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("sqlite3.connect(DATA_DIR)", 'sqlite3.connect(str(DATA_DIR / "app.db"))')
open(p,"w").write(s)
PY
    python3 -m py_compile "$STORE" && echo "  ✓ storage: save now uses app.db (was the DATA_DIR directory)" \
      || { echo "  ✗ storage compile failed — restoring"; mv "$STORE.bak" "$STORE"; }
    rm -f "$STORE.bak"
  else
    echo "  · storage: no 'sqlite3.connect(DATA_DIR)' found (already fixed or different)"
  fi
else
  echo "  !  storage.py not found — if saves 500, ensure update_map_state connects to app.db, not DATA_DIR."
fi

# ── B. theme.js: code colours + code edge categories ────────────
TH=""
for c in frontend/src/utils/theme.js frontend/utils/theme.js src/utils/theme.js; do [ -f "$c" ] && TH="$c" && break; done
[ -z "$TH" ] && TH="$(find . -path '*/utils/theme.js' -not -path '*/node_modules/*' 2>/dev/null | head -1)"
[ -z "$TH" ] && { echo "  !  theme.js not found — skipping UI part."; echo "✓ done."; exit 0; }
echo "  → theme: $TH"

if grep -q "CODE_COLORS" "$TH"; then
  echo "  · theme already has code colours — skipping UI part."
else
  cp "$TH" "$TH.bak"
  TH="$TH" python3 - <<'PY'
import os, sys, re
p=os.environ["TH"]; s=open(p).read(); n=0

OLD_TC='export function typeColor(P,t){return P.types[t]||P.types.term;}'
NEW_TC=(
'var CODE_COLORS={module:"#4C78C9",class:"#B07CC6",function:"#3F9E68",method:"#3F9E68",'
'parameter:"#C9A227",constant:"#D9730D",variable:"#E08A50",type:"#4FA6A6",'
'interface:"#4FA6A6",test:"#8A8F98",decorator:"#C77DA5"};\n'
'export function typeColor(P,t){if(CODE_COLORS[t]){var c=CODE_COLORS[t];return{a:c,s:c,b:c+"22"};}return P.types[t]||P.types.term;}'
)
if OLD_TC in s: s=s.replace(OLD_TC,NEW_TC,1); n+=1
else: print("  !  typeColor anchor not found — add CODE_COLORS + code fallback manually.")

OLD_EC=('var EC={logical:["IMPLIES","REQUIRES","CONTRADICTS","EQUIVALENT","GENERALIZES","SPECIALIZES"],'
        'compositional:["PART_OF","CONTAINS","INSTANCE_OF","DEFINED_BY"],'
        'pedagogical:["PREREQUISITE_FOR","ILLUSTRATES","EXTENDS","CONTRASTS_WITH"],'
        'causal:["CAUSES","ENABLES","CONSTRAINS","ANALOGOUS_TO"]};')
NEW_EC=('var EC={logical:["IMPLIES","REQUIRES","CONTRADICTS","EQUIVALENT","GENERALIZES","SPECIALIZES","CALLS","INSTANTIATES","INHERITS"],'
        'compositional:["PART_OF","CONTAINS","INSTANCE_OF","DEFINED_BY","DEFINES","IMPORTS"],'
        'pedagogical:["PREREQUISITE_FOR","ILLUSTRATES","EXTENDS","CONTRASTS_WITH"],'
        'causal:["CAUSES","ENABLES","CONSTRAINS","ANALOGOUS_TO","HAS_TYPE","RETURNS","READS","WRITES"]};')
if OLD_EC in s: s=s.replace(OLD_EC,NEW_EC,1); n+=1
else:
    # tolerant fallback: inject code types into each category list
    s2=s
    s2=re.sub(r'(logical:\[[^\]]*)\]', r'\1,"CALLS","INSTANTIATES","INHERITS"]', s2, count=1)
    s2=re.sub(r'(compositional:\[[^\]]*)\]', r'\1,"DEFINES","IMPORTS"]', s2, count=1)
    s2=re.sub(r'(causal:\[[^\]]*)\]', r'\1,"HAS_TYPE","RETURNS","READS","WRITES"]', s2, count=1)
    if s2!=s: s=s2; n+=1
    else: print("  !  EC anchor not found — add code relations to edgeCat manually.")

open(p,"w").write(s)
print(f"  \u2713 theme patched ({n}/2 edits): code node colours + code edge categories")
PY
  if command -v node >/dev/null 2>&1; then
    node --check "$TH" 2>/dev/null && echo "  ✓ theme.js parses" || { echo "  ✗ theme parse failed — restoring"; mv "$TH.bak" "$TH"; exit 1; }
  fi
  rm -f "$TH.bak"
fi

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
Applied. Restart backend + frontend, reload the code map:

  lsof -ti:8000 | xargs kill -9 2>/dev/null; uvicorn backend.app.main:app --reload --port 8000
  (frontend hot-reloads)

NOW THE MAP READS AS:
  node colour  = kind →  module (blue) · class (purple) · function (green)
                          parameter (gold) · constant (orange) · variable (amber)
                          type/interface (teal) · test (grey) · decorator (pink)
  edge style   = relation kind:
     structure  (CONTAINS/DEFINES/IMPORTS)      dashed, no arrow
     call graph (CALLS/INSTANTIATES/INHERITS)   solid, arrow
     data/type  (HAS_TYPE/RETURNS/READS/WRITES) solid, arrow
  Click any node → the "Connections" panel names each relation with its colour.
  Tip: use a LIGHT palette + "Solid" line mode for the clearest code reading.

STILL TODO (bigger, separate task — say the word):
  • hierarchical code layout (module→class→method→param) instead of organic
    scatter. This is a layout-engine change in App.jsx; worth its own focused pass.
  • optional on-canvas legend panel.
  • edits now persist (save fix), so positions/groups you set will survive reload.
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."