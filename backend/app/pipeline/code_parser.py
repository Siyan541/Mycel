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
from backend.app.models import (KnowledgeGraph, GraphNode, GraphEdge,
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
