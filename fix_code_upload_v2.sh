#!/usr/bin/env bash
# ============================================================================
# Mycel Code — .py upload fix v2 (gate-proof)
#
# Handles .py at the TOP of the /api/upload function, with an early return,
# BEFORE any file-type gate ("PDF only" / "Unsupported format") can reject it.
# Gate-agnostic: works no matter which upload route version you have. Also
# repairs the case where fix v1 left an `ext`-referencing branch without
# defining `ext`.
#
# Run from repo ROOT:  bash fix_code_upload_v2.sh   (idempotent)
# ============================================================================
set -e
if   [ -f backend/app/main.py ]; then APP="backend/app";
elif [ -f app/main.py ];         then APP="app";
else echo "ERROR: run from repo root (backend/app/main.py not found)."; exit 1; fi
BASE="$(echo "$APP" | sed 's#/#.#g')"
MAIN="$APP/main.py"
[ -f "$APP/pipeline/code_parser.py" ] || { echo "ERROR: code_parser.py missing — run code Stage 1/2 first."; exit 1; }
echo "→ patching $MAIN (base $BASE)"

cp "$MAIN" "$MAIN.v2bak"
MAIN="$MAIN" BASE="$BASE" python3 - <<'PY'
import os, re, sys
p = os.environ["MAIN"]; base = os.environ["BASE"]
s = open(p).read(); orig = s

if "import os" not in s:
    s = "import os\n" + s
    print("  \u2713 added 'import os'")

if "build_code_graph(str(_fp))" in s:
    print("  \u00b7 .py early-return already present")
else:
    m = re.search(r"(async def upload\([^\n]*\):\n)", s)
    if not m:
        print("  \u2717 could not find 'async def upload(...):' — paste your route to me.")
        sys.exit(3)
    block = (
        '    ext = os.path.splitext(file.filename)[1].lower()\n'
        '    if ext == ".py":\n'
        '        import shutil as _sh\n'
        '        _fp = UPLOAD_DIR / file.filename\n'
        '        with open(_fp, "wb") as _f: _sh.copyfileobj(file.file, _f)\n'
        '        from ' + base + '.pipeline.code_parser import build_code_graph\n'
        '        _g = build_code_graph(str(_fp))\n'
        '        try: _mid = save_map(file.filename, _g)\n'
        '        except TypeError:\n'
        '            try: _mid = save_map(file.filename, _g, None)\n'
        '            except Exception: _mid = None\n'
        '        return {"status": "success", "map_id": _mid, "document": file.filename,\n'
        '                "nodes": [n.model_dump() for n in _g.nodes],\n'
        '                "edges": [e.model_dump() for e in _g.edges],\n'
        '                "node_count": len(_g.nodes), "edge_count": len(_g.edges)}\n'
    )
    s = s[:m.end()] + block + s[m.end():]
    print("  \u2713 inserted .py early-return at top of upload()")

# make sure .py is allowed anywhere a set gate is used too (harmless if unused)
m2 = re.search(r"ALLOWED_EXT\s*=\s*\{([^}]*)\}", s)
if m2 and ".py" not in m2.group(1):
    inner = m2.group(1).rstrip().rstrip(",")
    s = s[:m2.start()] + "ALLOWED_EXT = {" + inner + ", '.py'}" + s[m2.end():]
    print("  \u2713 added .py to ALLOWED_EXT")

if s != orig: open(p, "w").write(s)
PY
rc=$?
[ "$rc" = "3" ] && { echo "  (aborted, no changes kept)"; mv "$MAIN.v2bak" "$MAIN"; exit 1; }

python3 -m py_compile "$MAIN" && echo "  ✓ main.py compiles" || {
  echo "  ✗ compile failed — restoring"; mv "$MAIN.v2bak" "$MAIN"; exit 1; }
rm -f "$MAIN.v2bak"

echo "  ── resulting upload() head ──"
awk '/async def upload\(/{f=1} f{print "     "$0} f&&/node_count/{exit}' "$MAIN" | head -20

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
Restart the backend (venv) and re-upload a .py:
  uvicorn backend.app.main:app --reload --port 8000
You should now get 200 with module/class/function nodes + CALLS/INHERITS edges.
If it STILL 400s, paste me the printed upload() head above.
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."