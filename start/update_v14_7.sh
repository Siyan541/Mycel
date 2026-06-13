#!/usr/bin/env bash
# Mycel backend wiring — detects where your files already are and wires main.py.
# Safe to re-run. Run from your repo ROOT:
#   chmod +x update_v14_7.sh && ./update_v14_7.sh
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

# 1) locate the app package
if   [ -f backend/app/main.py ]; then APP="backend/app";
elif [ -f app/main.py ];         then APP="app";
else echo "ERROR: can't find backend/app/main.py or app/main.py. Run from repo root."; exit 1; fi
BASE="$(echo "$APP" | sed 's#/#.#g')"   # backend/app -> backend.app
echo "→ app package: $APP   (module base: $BASE)"

# 2) find where media.py and socratic.py already live (services/ or routes/)
find_sub() { for sub in services routes; do [ -f "$APP/$sub/$1" ] && { echo "$sub"; return; }; done; echo ""; }
MEDIA_SUB="$(find_sub media.py)"
SOC_SUB="$(find_sub socratic.py)"

# if missing, try to copy from next to the script (accept either name)
place() { # $1 destfile-basename  $2 target-subpkg  $3..candidates
  local base="$1"; local sub="$2"; shift 2
  if [ -n "$(find_sub "$base")" ]; then return; fi
  for c in "$@"; do
    if [ -f "$HERE/$c" ]; then mkdir -p "$APP/$sub"; cp "$HERE/$c" "$APP/$sub/$base"; echo "→ copied $c -> $APP/$sub/$base"; return; fi
  done
}
place media.py    services backend_media.py media.py
place socratic.py routes   backend_socratic.py socratic.py
MEDIA_SUB="$(find_sub media.py)"
SOC_SUB="$(find_sub socratic.py)"
[ -z "$MEDIA_SUB" ] && { echo "ERROR: media.py not found in $APP/services or $APP/routes, and no copy beside the script."; exit 1; }
[ -z "$SOC_SUB" ]   && { echo "ERROR: socratic.py not found in $APP/services or $APP/routes, and no copy beside the script."; exit 1; }
echo "→ media.py in $MEDIA_SUB/ , socratic.py in $SOC_SUB/"

# 3) ensure these folders are real packages (prevents 'No module named')
[ -f "$APP/__init__.py" ]            || touch "$APP/__init__.py"
[ -f "$APP/$MEDIA_SUB/__init__.py" ] || touch "$APP/$MEDIA_SUB/__init__.py"
[ -f "$APP/$SOC_SUB/__init__.py" ]   || touch "$APP/$SOC_SUB/__init__.py"

# 4) requirements
REQ="requirements.txt"; [ -f "$REQ" ] || REQ="backend/requirements.txt"
if [ -f "$REQ" ]; then
  grep -qi '^PyMuPDF'    "$REQ" || echo "PyMuPDF"    >> "$REQ"
  grep -qi '^pdfplumber' "$REQ" || echo "pdfplumber" >> "$REQ"
  echo "→ ensured PyMuPDF + pdfplumber in $REQ"
else
  echo "!  no requirements.txt found — add PyMuPDF and pdfplumber yourself."
fi

# 5) wire main.py with the CORRECT import paths for where your files actually are
IMP_MEDIA="from $BASE.$MEDIA_SUB.media import enrich"
IMP_SOC="from $BASE.$SOC_SUB.socratic import router as socratic_router"
MAIN="$APP/main.py" IMP_MEDIA="$IMP_MEDIA" IMP_SOC="$IMP_SOC" python3 - <<'PY'
import os, re
p = os.environ["MAIN"]; im = os.environ["IMP_MEDIA"]; isoc = os.environ["IMP_SOC"]
s = open(p).read(); orig = s
# drop any stale/duplicate versions of these imports (wrong subpackage etc.)
s = re.sub(r'^\s*from\s+[\w.]+\.(services|routes)\.media\s+import\s+enrich\s*$\n?', '', s, flags=re.M)
s = re.sub(r'^\s*from\s+[\w.]+\.(services|routes)\.socratic\s+import\s+router\s+as\s+socratic_router\s*$\n?', '', s, flags=re.M)
# prepend the correct ones
s = im + "\n" + isoc + "\n" + s
# ensure include_router once
if "include_router(socratic_router)" not in s:
    m = re.search(r'^\s*app\s*=\s*FastAPI\([^\n]*\)\s*$', s, re.M)
    if m: s = s[:m.end()] + "\napp.include_router(socratic_router)" + s[m.end():]
    else: s += "\napp.include_router(socratic_router)\n"
open(p, "w").write(s)
print("→ main.py imports/router set:")
print("   ", im); print("   ", isoc)
PY

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
AUTOMATED: file placement check, __init__.py, requirements, main.py imports + router.

3 edits left — they're INSIDE functions, so do them by hand:

(A) models.py — Relation/Edge class, add:
        page: int = 0
        evidence: str = ""

(B) /api/upload route:
        graph = run(str(fp))
        figures = enrich(graph, str(fp), text_only=text_only)   # add this line
        map_id = save_map(file.filename, graph)
        return { ...same as before...,
                 "figures": figures }
    and add to the route signature:  text_only: bool = Query(False)

(C) GET /api/maps/{id} + autosave: follow MYCEL_BACKEND_GUIDE.md section 3.

Then:  git add -A && git commit -m "pdf provenance + media + socratic" && git push
TIP: commit (A)+(B) first, confirm the site loads, then do (C).
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."