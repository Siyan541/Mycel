#!/usr/bin/env bash
# ============================================================================
# Mycel Code — .py upload fix v3 (targets the real route)
#
# Fixes BOTH live bugs:
#   1. the "PDF only" gate that rejects .py before routing
#   2. the undefined `ext` (v1 inserted `if ext == ".py"` with no `ext = ...`),
#      which also crashes PDF uploads with NameError
#
# It replaces the gate with a line that DEFINES ext and allows the real formats
# (incl .py). Whitespace/quote tolerant; multi-line def signature is fine.
#
# Run from repo ROOT:  bash fix_code_upload_v3.sh   (idempotent)
# ============================================================================
set -e
if   [ -f backend/app/main.py ]; then APP="backend/app";
elif [ -f app/main.py ];         then APP="app";
else echo "ERROR: run from repo root."; exit 1; fi
MAIN="$APP/main.py"
echo "→ patching $MAIN"
cp "$MAIN" "$MAIN.v3bak"

MAIN="$MAIN" python3 - <<'PY'
import os, re, sys
p = os.environ["MAIN"]; s = open(p).read(); orig = s; did = []

if "import os" not in s.splitlines()[0:40].__str__() and not re.search(r'(?m)^import os\b', s):
    s = "import os\n" + s; did.append("added 'import os'")

ALLOWED = '(".pdf", ".docx", ".txt", ".md", ".markdown", ".rst", ".tex", ".epub", ".py")'
gate_new = (
    '    ext = os.path.splitext(file.filename)[1].lower()\n'
    '    if ext not in ' + ALLOWED + ':\n'
    '        return JSONResponse({"error": "Unsupported format: " + ext}, 400)'
)

# 1) replace the "PDF only" gate (whitespace/quote tolerant)
gate_re = re.compile(
    r'[ \t]*if not file\.filename\.lower\(\)\.endswith\(\s*["\']\.pdf["\']\s*\):[ \t]*\n'
    r'[ \t]*return JSONResponse\(\s*\{\s*["\']error["\']\s*:\s*["\']PDF only["\']\s*\}\s*,\s*400\s*\)'
)
if "Unsupported format: " in s and "ext = os.path.splitext(file.filename)" in s:
    did.append("gate already fixed")
elif gate_re.search(s):
    s = gate_re.sub(gate_new, s, count=1)
    did.append("replaced PDF-only gate; ext now defined; .py allowed")
else:
    did.append("!  PDF-only gate not matched")

# 2) safety net: if `if ext ==` exists but ext is never assigned, define it
if "if ext ==" in s and "ext = os.path.splitext(file.filename)" not in s:
    m = re.search(r'(?m)^([ \t]*)if ext ==', s)
    if m:
        indent = m.group(1)
        s = s[:m.start()] + indent + 'ext = os.path.splitext(file.filename)[1].lower()\n' + s[m.start():]
        did.append("inserted missing `ext = ...` before the code branch")

if s != orig: open(p, "w").write(s)
for d in did: print("  " + ("\u2713 " + d if not d.startswith("!") else d))
PY

python3 -m py_compile "$MAIN" && echo "  ✓ main.py compiles" || {
  echo "  ✗ compile failed — restoring"; mv "$MAIN.v3bak" "$MAIN"; exit 1; }
rm -f "$MAIN.v3bak"

echo "  ── upload() head after patch ──"
awk '/async def upload\(/{f=1} f{print "     "$0} f&&/graph = run\(str\(fp\)\)/{print "     ..."; exit}' "$MAIN"

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
Now restart the backend (kill the old one first — "Address already in use"):
  lsof -ti:8000 | xargs kill -9 2>/dev/null; \
  uvicorn backend.app.main:app --reload --port 8000

Then upload example_code_test.py in Code mode → expect 200 with
module/class/function nodes + CALLS/INHERITS/INSTANTIATES/HAS_TYPE/RETURNS/READS.
PDF uploads also work again (the NameError is fixed).
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."