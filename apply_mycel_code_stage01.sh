#!/usr/bin/env bash
# ============================================================================
# Mycel Code — Stage 0 + Stage 1
#
# Run from repo ROOT:  chmod +x apply_mycel_code_stage01.sh && ./apply_mycel_code_stage01.sh
# Safe to re-run (idempotent). Nothing here touches the concept pipeline.
#
# STAGE 0 — mode plumbing
#   1. models.py         → add CodeEntityType + CodeRelationType enums;
#                          widen GraphNode.concept_type / GraphEdge.relation_type so they
#                          also accept code types; add optional code-only node fields.
#   2. orchestrator.py   → run(..., mode="concept"); branch mode=="code" to the code parser;
#                          stamp graph.metadata["mode"].
#   3. main.py (upload)  → best-effort: accept ?mode=code and pass it to run().
#   4. api.js            → uploadFile passes opts.mode as ?mode=.
#   5. App.jsx           → add a "Code" card to the mode picker; accept .py uploads;
#                          pass the chosen mode on upload.
#
# STAGE 1 — deterministic Python parser
#   6. pipeline/code_parser.py (NEW) → Python `ast` walk emitting
#        module / class / function / variable / parameter nodes
#        + DEFINES / CONTAINS / IMPORTS edges. No LLM, no external deps.
#        (tree-sitter is the multi-language path for Stage 5; stdlib ast is exact for Py.)
# ============================================================================
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

# ── locate the backend app package (backend/app or app) ─────────────────────
if   [ -f backend/app/main.py ]; then APP="backend/app";
elif [ -f app/main.py ];         then APP="app";
else echo "ERROR: can't find backend/app/main.py or app/main.py. Run from repo root."; exit 1; fi
BASE="$(echo "$APP" | sed 's#/#.#g')"   # backend/app -> backend.app
echo "→ backend package: $APP   (module base: $BASE)"

# ── locate the frontend src (frontend/src or src) ───────────────────────────
if   [ -f frontend/src/App.jsx ]; then FE="frontend/src";
elif [ -f src/App.jsx ];          then FE="src";
else FE=""; echo "!  frontend App.jsx not found — skipping frontend patches (backend still applies)."; fi
[ -n "$FE" ] && echo "→ frontend src: $FE"

# ════════════════════════════════════════════════════════════════════════════
# 1. models.py — enums + relaxed types + optional node fields
# ════════════════════════════════════════════════════════════════════════════
MODELS="$APP/models.py"
[ -f "$MODELS" ] || { echo "ERROR: $MODELS not found."; exit 1; }
MODELS="$MODELS" python3 - <<'PY'
import os, re
p = os.environ["MODELS"]; s = open(p).read(); orig = s

# (a) add the two code enums right after the ConceptType class block
if "class CodeEntityType" not in s:
    enums = '''

class CodeEntityType(str, Enum):
    MODULE="module"; CLASS="class"; FUNCTION="function"; TYPE="type"
    VARIABLE="variable"; PARAMETER="parameter"; CONSTANT="constant"
    INTERFACE="interface"; TEST="test"; DECORATOR="decorator"

class CodeRelationType(str, Enum):
    CALLS="CALLS"; INSTANTIATES="INSTANTIATES"; RETURNS="RETURNS"; THROWS="THROWS"; OVERRIDES="OVERRIDES"
    READS="READS"; WRITES="WRITES"; PASSES_TO="PASSES_TO"; DEPENDS_ON="DEPENDS_ON"
    DEFINES="DEFINES"; CONTAINS="CONTAINS"; IMPORTS="IMPORTS"; EXPORTS="EXPORTS"
    HAS_TYPE="HAS_TYPE"; IMPLEMENTS="IMPLEMENTS"; INHERITS="INHERITS"; CONSTRAINS="CONSTRAINS"; INSTANCE_OF="INSTANCE_OF"
'''
    m = re.search(r'class ConceptType\(str, Enum\):', s)
    if not m:
        raise SystemExit("ERROR: ConceptType class not found in models.py — aborting so nothing is corrupted.")
    # insert before the NEXT class after ConceptType (or append if none)
    nxt = re.search(r'\nclass ', s[m.end():])
    pos = m.end() + nxt.start() if nxt else len(s)
    s = s[:pos] + enums + s[pos:]
    print("  ✓ added CodeEntityType + CodeRelationType")
else:
    print("  · enums already present")

# (b) widen ONLY GraphNode.concept_type and GraphEdge.relation_type so they accept
#     code types. Robust to whatever the field is currently annotated as
#     (ConceptType, str, Optional[...], already-a-union). str-enums serialize by
#     .value in pydantic v2, so a union keeps validation and correct output.
def widen(src, cls, field, extra):
    m = re.search(r'(class '+cls+r'\(BaseModel\):.*?)(\nclass |\Z)', src, re.S)
    if not m:
        return src, "missing"
    block = m.group(1)
    # capture the field's current annotation (stop at ; = newline)
    fm = re.search(r'(\b'+field+r'\s*:\s*)([^\n;=]+)', block)
    if not fm:
        return src, "nofield"
    ann = fm.group(2).rstrip()
    # already accepts code types, or already permissive (str) → nothing to do
    if extra in ann or ann == "str" or "str" in ann.split():
        return src, "already"
    new_ann = ann + " | " + extra
    nb = block[:fm.start(2)] + new_ann + block[fm.end(2):]
    return src[:m.start(1)] + nb + src[m.end(1):], "ok"

s, r1 = widen(s, "GraphNode", "concept_type", "CodeEntityType")
s, r2 = widen(s, "GraphEdge", "relation_type", "CodeRelationType")
_msg = {"ok":      "  ✓ widened {0} to accept code types",
        "already": "  · {0} already accepts code types",
        "nofield": "  !  {0} field not found — check models.py by hand",
        "missing": "  !  {0} class not found — check models.py by hand"}
print(_msg[r1].format("GraphNode.concept_type"))
print(_msg[r2].format("GraphEdge.relation_type"))

# (c) add optional, default-empty code fields to GraphNode
if "kind_detail" not in s:
    field_line = '    signature: str = ""; language: str = ""; file_path: str = ""; line: int = 0; kind_detail: str = ""\n'
    s2 = re.sub(r'(class GraphNode\(BaseModel\):\n)', r'\1'+field_line, s, count=1)
    if s2 == s:
        raise SystemExit("ERROR: could not locate 'class GraphNode(BaseModel):' to add fields — aborting.")
    s = s2
    print("  ✓ added optional code fields to GraphNode")
else:
    print("  · code fields already present")

if s != orig:
    open(p, "w").write(s)
print("→ models.py done")
PY

# ════════════════════════════════════════════════════════════════════════════
# 6. pipeline/code_parser.py  (Stage 1 — written before orchestrator patch)
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$APP/pipeline"
[ -f "$APP/pipeline/__init__.py" ] || touch "$APP/pipeline/__init__.py"
cat > "$APP/pipeline/code_parser.py" <<'PY'
"""
Mycel Code — Stage 1 deterministic code parser (Python only).

Uses the standard-library `ast` module: zero dependencies, deterministic,
and exact for Python. Emits module / class / function / variable / parameter
nodes and DEFINES / CONTAINS / IMPORTS edges. Node identity is the
fully-qualified name, so re-running or spanning files merges by exact match.

Later stages add CALLS / READS / WRITES / type edges (Stage 2) and a
tree-sitter backend for other languages (Stage 5). This module is that seam.
"""
import ast, os, logging
from __BASE__.models import (KnowledgeGraph, GraphNode, GraphEdge,
                             CodeEntityType, CodeRelationType)

logger = logging.getLogger(__name__)

# scope depth → abstraction_level (drives node sizing, reused from concept mode)
_LEVEL = {"module": 0, "class": 1, "interface": 1, "type": 1,
          "function": 2, "variable": 3, "parameter": 3,
          "constant": 3, "decorator": 3, "test": 3}


class _Graph:
    def __init__(self):
        self.nodes = {}      # id -> GraphNode
        self._edges = {}     # (src,rel,tgt) -> GraphEdge

    def node(self, nid, label, etype, desc="", signature="",
             file_path="", line=0, kind=""):
        if nid not in self.nodes:
            self.nodes[nid] = GraphNode(
                id=nid, label=label, description=desc,
                concept_type=etype, abstraction_level=_LEVEL.get(etype, 2),
                confidence=1.0, cluster=file_path or "", source_page=0,
                signature=signature, language="python",
                file_path=file_path, line=line, kind_detail=kind)
        return nid

    def edge(self, src, rel, tgt, why=""):
        if src == tgt:
            return
        k = (src, rel, tgt)
        if k not in self._edges:
            self._edges[k] = GraphEdge(
                id=(rel + ":" + src + ">" + tgt)[:120],
                source_id=src, target_id=tgt, relation_type=rel,
                justification=why, confidence=1.0)

    def edges(self):
        return list(self._edges.values())


def _sig(fn: ast.AST) -> str:
    """Best-effort function signature string."""
    try:
        a = fn.args
        parts = []
        for arg in getattr(a, "posonlyargs", []) + a.args:
            parts.append(arg.arg)
        if a.vararg:
            parts.append("*" + a.vararg.arg)
        for arg in a.kwonlyargs:
            parts.append(arg.arg)
        if a.kwarg:
            parts.append("**" + a.kwarg.arg)
        return fn.name + "(" + ", ".join(parts) + ")"
    except Exception:
        return getattr(fn, "name", "") + "(...)"


def _is_test(name: str) -> bool:
    return name.startswith("test_") or name.startswith("Test")


def _module_name(path: str, root: str) -> str:
    rel = os.path.relpath(path, root)
    rel = rel[:-3] if rel.endswith(".py") else rel
    rel = rel.replace(os.sep, ".")
    if rel.endswith(".__init__"):
        rel = rel[:-9]
    return rel or os.path.basename(path)


def _walk(body, parent_id, parent_kind, qual, g: _Graph, fpath):
    """Recursively add DEFINES/CONTAINS children of a scope."""
    for stmt in body:
        # ── classes ──────────────────────────────────────────────
        if isinstance(stmt, ast.ClassDef):
            cq = qual + "." + stmt.name
            cid = g.node("cls:" + cq, stmt.name, CodeEntityType.CLASS.value,
                         desc="class " + stmt.name, signature="class " + stmt.name,
                         file_path=fpath, line=getattr(stmt, "lineno", 0))
            g.edge(parent_id, CodeRelationType.CONTAINS.value, cid,
                   parent_kind + " contains class")
            g.edge(parent_id, CodeRelationType.DEFINES.value, cid,
                   parent_kind + " defines class")
            _walk(stmt.body, cid, "class", cq, g, fpath)

        # ── functions / methods ─────────────────────────────────
        elif isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
            fq = qual + "." + stmt.name
            etype = (CodeEntityType.TEST.value if _is_test(stmt.name)
                     else CodeEntityType.FUNCTION.value)
            fid = g.node("fn:" + fq, stmt.name, etype,
                         desc=("async " if isinstance(stmt, ast.AsyncFunctionDef) else "") + "function",
                         signature=_sig(stmt), file_path=fpath,
                         line=getattr(stmt, "lineno", 0),
                         kind=("async" if isinstance(stmt, ast.AsyncFunctionDef) else ""))
            g.edge(parent_id, CodeRelationType.CONTAINS.value, fid,
                   parent_kind + " contains function")
            g.edge(parent_id, CodeRelationType.DEFINES.value, fid,
                   parent_kind + " defines function")
            # parameters
            try:
                allargs = (getattr(stmt.args, "posonlyargs", []) + stmt.args.args
                           + stmt.args.kwonlyargs)
                for arg in allargs:
                    if arg.arg in ("self", "cls"):
                        continue
                    pid = g.node("par:" + fq + "." + arg.arg, arg.arg,
                                 CodeEntityType.PARAMETER.value, desc="parameter",
                                 file_path=fpath, line=getattr(arg, "lineno", 0))
                    g.edge(fid, CodeRelationType.CONTAINS.value, pid,
                           "function contains parameter")
            except Exception:
                pass
            # capture nested defs/classes only (skip local variables in Stage 1)
            _walk([s for s in stmt.body
                   if isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))],
                  fid, "function", fq, g, fpath)

        # ── module/class-level variables & constants ────────────
        elif isinstance(stmt, (ast.Assign, ast.AnnAssign)):
            targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
            for t in targets:
                if isinstance(t, ast.Name):
                    name = t.id
                    is_const = name.isupper() and len(name) > 1
                    etype = (CodeEntityType.CONSTANT.value if is_const
                             else CodeEntityType.VARIABLE.value)
                    vid = g.node("var:" + qual + "." + name, name, etype,
                                 desc=("constant" if is_const else "variable"),
                                 file_path=fpath, line=getattr(stmt, "lineno", 0))
                    g.edge(parent_id, CodeRelationType.DEFINES.value, vid,
                           parent_kind + " defines " + ("constant" if is_const else "variable"))

        # ── imports (module scope only) ─────────────────────────
        elif isinstance(stmt, ast.Import) and parent_kind == "module":
            for alias in stmt.names:
                top = alias.name.split(".")[0]
                iid = g.node("mod:" + top, top, CodeEntityType.MODULE.value,
                             desc="imported module", kind="external")
                g.edge(parent_id, CodeRelationType.IMPORTS.value, iid,
                       "module imports " + top)
        elif isinstance(stmt, ast.ImportFrom) and parent_kind == "module":
            top = (stmt.module or "").split(".")[0]
            if top:
                iid = g.node("mod:" + top, top, CodeEntityType.MODULE.value,
                             desc="imported module", kind="external")
                g.edge(parent_id, CodeRelationType.IMPORTS.value, iid,
                       "module imports " + top)


def _parse_file(path, root, g: _Graph):
    try:
        src = open(path, "r", encoding="utf-8", errors="replace").read()
        tree = ast.parse(src, filename=path)
    except SyntaxError as e:
        logger.warning("code_parser: skip %s (%s)", path, e)
        return
    modname = _module_name(path, root)
    mid = g.node("mod:" + modname, modname, CodeEntityType.MODULE.value,
                 desc="module " + modname, file_path=path, line=1)
    _walk(tree.body, mid, "module", modname, g, path)


def build_code_graph(filepath, language="python") -> KnowledgeGraph:
    """Entry point called by orchestrator.run(mode='code')."""
    g = _Graph()
    files = []
    if os.path.isdir(filepath):
        root = filepath
        for dp, dn, fn in os.walk(filepath):
            dn[:] = [d for d in dn if d not in
                     (".git", "__pycache__", "node_modules", ".venv", "venv")]
            files += [os.path.join(dp, f) for f in fn if f.endswith(".py")]
    else:
        root = os.path.dirname(filepath) or "."
        if filepath.endswith(".py"):
            files = [filepath]

    if not files:
        return KnowledgeGraph(
            document_name=os.path.basename(filepath),
            nodes=[], edges=[],
            metadata={"mode": "code", "language": language,
                      "error": "No .py files found. Stage 1 supports Python only."})

    for f in sorted(files):
        _parse_file(f, root, g)

    return KnowledgeGraph(
        document_name=os.path.basename(filepath.rstrip("/")) or "code",
        nodes=list(g.nodes.values()), edges=g.edges(),
        metadata={"mode": "code", "language": language,
                  "generator": "code_parser.stage1",
                  "files": len(files),
                  "node_count": len(g.nodes), "edge_count": len(g.edges())})
PY
python3 - "$APP/pipeline/code_parser.py" "$BASE" <<'PY'
import sys
path, base = sys.argv[1], sys.argv[2]
s = open(path).read()
open(path, "w").write(s.replace("__BASE__", base))
PY
echo "  ✓ wrote $APP/pipeline/code_parser.py (import base: $BASE)"

# quick import sanity check (won't fail the script if deps missing at build time)
python3 - <<PY || echo "  !  (skip) could not import-check code_parser now; will run in the app."
import ast
compile(open("$APP/pipeline/code_parser.py").read(), "code_parser.py", "exec")
print("  ✓ code_parser.py compiles")
PY

# ════════════════════════════════════════════════════════════════════════════
# 2. orchestrator.py — mode param + code branch
# ════════════════════════════════════════════════════════════════════════════
ORCH="$APP/pipeline/orchestrator.py"
[ -f "$ORCH" ] || { echo "ERROR: $ORCH not found."; exit 1; }
ORCH="$ORCH" BASE="$BASE" python3 - <<'PY'
import os, re
p = os.environ["ORCH"]; base = os.environ["BASE"]
s = open(p).read(); orig = s

if "build_code_graph" in s:
    print("  · orchestrator already patched")
else:
    m = re.search(r'def run\(([^)]*)\):', s)
    if not m:
        raise SystemExit("ERROR: could not find 'def run(...):' in orchestrator.py — aborting.")
    params = m.group(1)
    new_params = params if "mode" in params else (params.rstrip() + ', mode="concept"')
    branch = (
        '\n    if mode == "code":\n'
        '        from ' + base + '.pipeline.code_parser import build_code_graph\n'
        '        g = build_code_graph(filepath)\n'
        '        g.metadata = dict(getattr(g, "metadata", None) or {})\n'
        '        g.metadata["mode"] = "code"\n'
        '        return g\n'
    )
    head = s[:m.start()] + 'def run(' + new_params + '):' + branch
    s = head + s[m.end():]
    print("  ✓ added mode param + code branch to run()")

if s != orig:
    open(p, "w").write(s)
print("→ orchestrator.py done")
PY

# ════════════════════════════════════════════════════════════════════════════
# 3. main.py — best-effort: accept ?mode= and pass to run()
# ════════════════════════════════════════════════════════════════════════════
MAIN="$APP/main.py"
if [ -f "$MAIN" ]; then
MAIN="$MAIN" python3 - <<'PY'
import os, re
p = os.environ["MAIN"]; s = open(p).read(); orig = s
did = []; manual = False

def find_upload_params(src):
    """Return (open_paren_idx, close_paren_idx) of the /api/upload handler's
    parameter list, using balanced-paren scanning so File(...)/Query(...) inside
    the signature don't fool us. Returns None if not found."""
    m = re.search(r'@app\.post\(\s*["\']/api/upload["\']', src)
    if not m:
        return None
    dm = re.search(r'\basync\s+def\s+\w+\s*\(|\bdef\s+\w+\s*\(', src[m.end():])
    if not dm:
        return None
    op = m.end() + dm.end() - 1            # index of the '(' opening the params
    depth = 0
    for i in range(op, len(src)):
        if src[i] == '(':
            depth += 1
        elif src[i] == ')':
            depth -= 1
            if depth == 0:
                return (op, i)
    return None

loc = find_upload_params(s)
already = False
if not loc:
    manual = True
else:
    op, cl = loc
    sig = s[op+1:cl]
    if re.search(r'\bmode\s*:', sig) and "mode=mode" in s:
        already = True
    if not re.search(r'\bmode\s*:', sig):          # add param if absent
        if "Query" not in s:
            manual = True                          # can't add Query(...) safely
        else:
            add = ('' if sig.strip() == '' else ', ') + 'mode: str = Query("concept")'
            s = s[:cl] + add + s[cl:]
            did.append('added mode: str = Query("concept") to upload')
    # pass mode into run() (only the bare-path forms), once
    if not manual and "mode=mode" not in s:
        s2, n = re.subn(r'run\((str\(fp\)|fp|filepath|str\(filepath\))\)',
                        r'run(\1, mode=mode)', s)
        if n:
            s = s2; did.append("run(...) now passes mode")
        else:
            manual = True   # signature patched but couldn't find run() call — flag it

if s != orig:
    open(p, "w").write(s)

if already:
    print("  · main.py already patched")
elif did and not manual:
    print("  ✓ main.py: " + "; ".join(did))
else:
    if did:
        print("  ~ main.py partially patched: " + "; ".join(did))
    print("  !  main.py needs a manual check. Ensure the /api/upload route has:")
    print("       signature:  mode: str = Query(\"concept\")")
    print("       body:       run(str(fp))  ->  run(str(fp), mode=mode)")
PY
else
  echo "  !  $MAIN not found — add ?mode= handling to your upload route manually."
fi

# ════════════════════════════════════════════════════════════════════════════
# 4. api.js — uploadFile passes opts.mode
# ════════════════════════════════════════════════════════════════════════════
if [ -n "$FE" ] && [ -f "$FE/api.js" ]; then
API="$FE/api.js" python3 - <<'PY'
import os, re
p = os.environ["API"]; s = open(p).read(); orig = s
if "opts.mode" in s:
    print("  · api.js uploadFile already passes mode")
else:
    new = ('export function uploadFile(file,opts){var f=new FormData();f.append("file",file);'
           'var pr=[];if(opts&&opts.textOnly)pr.push("text_only=1");'
           'if(opts&&opts.mode)pr.push("mode="+encodeURIComponent(opts.mode));'
           'var q=pr.length?("?"+pr.join("&")):"";'
           'return fetch(API+"/api/upload"+q,{method:"POST",body:f,headers:uh()}).then(function(r){return r.json();});}')
    s2 = re.sub(r'export function uploadFile\(file,opts\)\{.*?\}\n', new + "\n", s, count=1, flags=re.S)
    if s2 == s:
        print("  !  api.js uploadFile not matched — add ?mode= to the upload query manually.")
    else:
        open(p, "w").write(s2)
        print("  ✓ api.js uploadFile passes mode")
PY
else
  [ -n "$FE" ] && echo "  !  $FE/api.js not found — skipping."
fi

# ════════════════════════════════════════════════════════════════════════════
# 5. App.jsx — Code mode card + .py accept + pass mode on upload
# ════════════════════════════════════════════════════════════════════════════
if [ -n "$FE" ] && [ -f "$FE/App.jsx" ]; then
APPJSX="$FE/App.jsx" python3 - <<'PY'
import os, re
p = os.environ["APPJSX"]; s = open(p).read(); orig = s
did = []

# (a) add a "code" card to the MODES array (after the sketch entry, "#FDCB6E")
if '"code","Code"' not in s:
    code_card = ('["code","Code","Map a codebase - functions, types, and how they '
                 'connect. No LLM needed.","#F7768E"]')
    s2 = s.replace('"#FDCB6E"]]', '"#FDCB6E"],' + code_card + ']', 1)
    if s2 != s:
        s = s2; did.append('added Code card to MODES')

# (b) accept .py uploads
if ".pdf,.docx,.txt,.md,.epub" in s and ".py" not in ".pdf,.docx,.txt,.md,.epub,.py"[:0] or True:
    if ".pdf,.docx,.txt,.md,.epub,.py" not in s:
        s3 = s.replace(".pdf,.docx,.txt,.md,.epub", ".pdf,.docx,.txt,.md,.epub,.py")
        if s3 != s:
            s = s3; did.append('accept .py')

# (c) pass the chosen mode on upload
if "mode:(pendingMode" not in s:
    s4 = s.replace("uploadPDF(file,{textOnly:textOnly})",
                   "uploadPDF(file,{textOnly:textOnly,mode:(pendingMode==='code'?'code':'concept')})", 1)
    if s4 != s:
        s = s4; did.append('upload passes mode')

if s != orig:
    open(p, "w").write(s)

if did:
    print("  ✓ App.jsx: " + "; ".join(did))
else:
    print("  · App.jsx already patched (or patterns differ — check MODES / accept / uploadPDF)")
PY
else
  [ -n "$FE" ] && echo "  !  $FE/App.jsx not found — skipping."
fi

# ════════════════════════════════════════════════════════════════════════════
cat <<'NOTE'

────────────────────────────────────────────────────────────────────────
Mycel Code — Stage 0 + Stage 1 applied.

WHAT WORKS NOW
  • Pick the "Code" card on the home screen, upload a .py file (or point the
    backend at a package directory), and run() routes to the deterministic
    parser instead of the concept pipeline.
  • You get module / class / function / variable / parameter nodes with
    DEFINES / CONTAINS / IMPORTS edges. Node ids are fully-qualified names,
    so re-uploads and multi-file packages merge by exact match.
  • The map saves with metadata.mode = "code" and round-trips through storage.

NOT YET (by design — later stages)
  • CALLS / READS / WRITES and type edges  → Stage 2 (name resolution).
  • Code-specific colors / monospace labels → Stage 3 (theme.js codeTypes).
    Until then, code nodes reuse concept-type colors and render fine.
  • Other languages / tree-sitter           → Stage 5.

IF main.py DID NOT AUTO-PATCH (see message above), make two edits in the
/api/upload route:
    signature:  add   mode: str = Query("concept")
    body:       run(str(fp))   ->   run(str(fp), mode=mode)

TEST
    # from repo root, point the parser at its own backend as a smoke test:
    python3 -c "from $BASE.pipeline.code_parser import build_code_graph as b; \
g=b('$APP'); print(len(g.nodes),'nodes',len(g.edges),'edges', g.metadata)"

Then commit:  git add -A && git commit -m "Mycel Code: Stage 0 + Stage 1" && git push
────────────────────────────────────────────────────────────────────────
NOTE
echo "✓ done."