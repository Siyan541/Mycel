#!/usr/bin/env bash
# ============================================================================
# Mycel Code — fix .py upload ("Unsupported format" / "PDF only")
#
# Root cause: the /api/upload route gates on ALLOWED_EXT (no .py), so .py is
# rejected before run() is ever called. This opens the gate and routes .py
# straight to the deterministic code parser — no dependence on the mode
# plumbing, so it works even if the Stage 0+1 frontend patches only half-applied.
#
# Run from repo ROOT:  bash fix_code_upload.sh   (idempotent)
# ============================================================================
set -e
if   [ -f backend/app/main.py ]; then APP="backend/app";
elif [ -f app/main.py ];         then APP="app";
else echo "ERROR: run from repo root (backend/app/main.py not found)."; exit 1; fi
BASE="$(echo "$APP" | sed 's#/#.#g')"
MAIN="$APP/main.py"
echo "→ backend: $APP   main: $MAIN"

[ -f "$APP/pipeline/code_parser.py" ] || { echo "ERROR: code_parser.py missing — run the code Stage 1/2 script first."; exit 1; }

cp "$MAIN" "$MAIN.codeupbak"
MAIN="$MAIN" BASE="$BASE" python3 - <<'PY'
import os, re, sys
p = os.environ["MAIN"]; base = os.environ["BASE"]
s = open(p).read(); orig = s; notes = []; manual = []

# (1) add '.py' to ALLOWED_EXT
m = re.search(r"ALLOWED_EXT\s*=\s*\{([^}]*)\}", s)
if not m:
    manual.append("Add '.py' to your ALLOWED_EXT set in main.py.")
elif ".py" in m.group(1):
    notes.append("ALLOWED_EXT already has .py")
else:
    inner = m.group(1).rstrip()
    if not inner.endswith(","): inner += ","
    s = s[:m.start()] + "ALLOWED_EXT = {" + inner + " '.py'}" + s[m.end():]
    notes.append("added .py to ALLOWED_EXT")

# (2) route .py to the code parser in the upload route
branch = (
    'if ext == ".py":\n'
    '        from ' + base + '.pipeline.code_parser import build_code_graph\n'
    '        graph = build_code_graph(str(fp))\n'
    '    else:\n'
    '        graph = run(str(fp))'
)
if "build_code_graph(str(fp))" in s:
    notes.append("upload already routes .py to code parser")
else:
    replaced = False
    for pat in ("graph = run(str(fp), mode=mode)", "graph = run(str(fp))"):
        if pat in s:
            s = s.replace(pat, branch, 1); replaced = True
            notes.append("upload now routes .py -> build_code_graph"); break
    if not replaced:
        manual.append("In /api/upload, wrap the graph-building call:\n"
                      '        if ext == ".py":\n'
                      '            from ' + base + '.pipeline.code_parser import build_code_graph\n'
                      '            graph = build_code_graph(str(fp))\n'
                      "        else:\n"
                      "            graph = run(str(fp))")

if s != orig: open(p, "w").write(s)
for n in notes: print("  \u2713 " + n)
for mnt in manual:
    print("  !  MANUAL: " + mnt)
sys.exit(3 if manual else 0)
PY
rc=$?

python3 -m py_compile "$MAIN" && echo "  ✓ main.py compiles" || {
  echo "  ✗ compile failed — restoring"; mv "$MAIN.codeupbak" "$MAIN"; exit 1; }
rm -f "$MAIN.codeupbak"

# (3) frontend: let the file picker choose .py
FE=""
for c in frontend/src/App.jsx frontend/App.jsx src/App.jsx App.jsx; do [ -f "$c" ] && FE="$c" && break; done
[ -z "$FE" ] && FE="$(find . -name App.jsx -not -path '*/node_modules/*' 2>/dev/null | head -1)"
if [ -n "$FE" ]; then
  if grep -q '\.pdf,\.docx,\.txt,\.md,\.epub,\.py' "$FE"; then
    echo "  · $FE already accepts .py"
  elif grep -q '\.pdf,\.docx,\.txt,\.md,\.epub' "$FE"; then
    cp "$FE" "$FE.codeupbak"
    python3 - "$FE" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace(".pdf,.docx,.txt,.md,.epub", ".pdf,.docx,.txt,.md,.epub,.py")
open(p,"w").write(s)
PY
    rm -f "$FE.codeupbak"; echo "  ✓ $FE file picker now accepts .py"
  else
    echo "  !  MANUAL: add .py to the file <input accept=...> in $FE"
  fi
else
  echo "  !  App.jsx not found — add .py to the upload accept manually."
fi

cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
.py uploads now work:
  • backend accepts .py and routes it to build_code_graph (Stage 1+2 parser)
  • the file picker lets you choose .py

TEST:
  # restart the backend (venv):  uvicorn backend.app.main:app --reload --port 8000
  # frontend:                    cd frontend && npm run dev
  # upload a .py file (or a small package zipped is Stage 5; single file works now)
  # you should get module/class/function nodes + CALLS/INHERITS/etc edges.

NOTE: for a whole package, point the backend at a directory in code — a single
.py upload maps that one file; multi-file resolution (CALLS across files) needs
the files present together (Stage 5 adds zip/folder upload to the UI).
────────────────────────────────────────────────────────────────────────
NOTE
[ "$rc" = "3" ] && echo "⚠ finished with MANUAL steps above." || echo "✓ done."