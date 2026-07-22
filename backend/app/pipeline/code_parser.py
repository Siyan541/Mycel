"""
Mycel Code — Stage 1 + Stage 2 deterministic Python parser (stdlib ast only).

Stage 1 (structure): module/class/function/variable/parameter nodes +
  DEFINES / CONTAINS / IMPORTS edges. Node id = fully-qualified name, so
  re-runs and multi-file packages merge by exact match (canonical identity
  for free — the concept track has to earn this via KB grounding).

Stage 2 (connections, deterministic name resolution): CALLS / INSTANTIATES
  (call graph), INHERITS (class hierarchy), HAS_TYPE / RETURNS (annotations,
  user types only), READS / WRITES (module/class-level state). Every edge is
  resolved to a KNOWN node only — unresolved names are dropped, never guessed —
  and carries page=line + evidence=source-line, the code analog of the concept
  track's source_page + source_quote. No LLM, no external deps.
  (tree-sitter multi-language backend is Stage 5.)
"""
import ast, os, logging
from backend.app.models import (KnowledgeGraph, GraphNode, GraphEdge,
                             CodeEntityType, CodeRelationType)

logger = logging.getLogger(__name__)

_LEVEL = {"module": 0, "class": 1, "interface": 1, "type": 1,
          "function": 2, "variable": 3, "parameter": 3,
          "constant": 3, "decorator": 3, "test": 3}
_BUILTIN_TYPES = {"int", "float", "str", "bool", "bytes", "list", "dict", "set",
                  "tuple", "None", "Any", "Optional", "object", "complex",
                  "frozenset", "List", "Dict", "Set", "Tuple", "Union", "Callable"}


def _fields(model):
    try: return set(model.model_fields.keys())
    except Exception: return None

def _mk(model, **kw):
    a = _fields(model)
    if a is not None: kw = {k: v for k, v in kw.items() if k in a}
    return model(**kw)


class _Graph:
    def __init__(self):
        self.nodes = {}; self._edges = {}
        self.func_by_name = {}; self.class_by_name = {}; self.node_module = {}
        self.methods_of = {}; self.var_by_scope = {}

    def node(self, nid, label, etype, desc="", signature="", file_path="",
             line=0, kind="", module="", quote=""):
        if nid not in self.nodes:
            self.nodes[nid] = _mk(GraphNode, id=nid, label=label, description=desc,
                concept_type=etype, abstraction_level=_LEVEL.get(etype, 2),
                confidence=1.0, cluster=file_path or "", source_page=line,
                source_quote=(quote or signature)[:240], in_text=True,
                signature=signature, language="python", file_path=file_path,
                line=line, kind_detail=kind)
            self.node_module[nid] = module
        return nid

    def edge(self, src, rel, tgt, why="", line=0, evidence=""):
        if not src or not tgt or src == tgt: return
        if src not in self.nodes or tgt not in self.nodes: return   # known nodes only
        k = (src, rel, tgt)
        if k not in self._edges:
            self._edges[k] = _mk(GraphEdge, id=(rel + ":" + src + ">" + tgt)[:120],
                source_id=src, target_id=tgt, relation_type=rel,
                justification=why, confidence=1.0, page=line, evidence=(evidence or "")[:240])

    def edges(self): return list(self._edges.values())

    def _pick(self, index, name, module):
        c = index.get(name)
        if not c: return None
        if len(c) == 1: return next(iter(c))
        same = [x for x in c if self.node_module.get(x) == module]
        return same[0] if len(same) == 1 else None            # else ambiguous -> skip

    def resolve_func(self, n, m):  return self._pick(self.func_by_name, n, m)
    def resolve_class(self, n, m): return self._pick(self.class_by_name, n, m)


def _sig(fn):
    try:
        a = fn.args; parts = []
        for arg in getattr(a, "posonlyargs", []) + a.args: parts.append(arg.arg)
        if a.vararg: parts.append("*" + a.vararg.arg)
        for arg in a.kwonlyargs: parts.append(arg.arg)
        if a.kwarg: parts.append("**" + a.kwarg.arg)
        return fn.name + "(" + ", ".join(parts) + ")"
    except Exception:
        return getattr(fn, "name", "") + "(...)"

def _is_test(n): return n.startswith("test_") or n.startswith("Test")

def _module_name(path, root):
    rel = os.path.relpath(path, root); rel = rel[:-3] if rel.endswith(".py") else rel
    rel = rel.replace(os.sep, ".")
    if rel.endswith(".__init__"): rel = rel[:-9]
    return rel or os.path.basename(path)

def _all_args(fn):
    a = fn.args
    return list(getattr(a, "posonlyargs", [])) + list(a.args) + list(a.kwonlyargs)

def _type_names(ann):
    return [x.id for x in ast.walk(ann) if isinstance(x, ast.Name)]

def _mark(skip, node):
    for x in ast.walk(node): skip.add(id(x))

def _ln(lines, node):
    try:
        i = getattr(node, "lineno", 0) - 1
        if 0 <= i < len(lines): return lines[i].strip()[:240]
    except Exception: pass
    return ""


# ── Stage 1: structure + indices ──────────────────────────────────────────
def _walk(body, parent_id, parent_kind, qual, g, fpath, modname, lines):
    for stmt in body:
        if isinstance(stmt, ast.ClassDef):
            cq = qual + "." + stmt.name
            cid = g.node("cls:" + cq, stmt.name, CodeEntityType.CLASS.value,
                         desc="class " + stmt.name, signature="class " + stmt.name,
                         file_path=fpath, line=getattr(stmt, "lineno", 0), module=modname)
            g.class_by_name.setdefault(stmt.name, set()).add(cid)
            g.edge(parent_id, CodeRelationType.CONTAINS.value, cid, parent_kind + " contains class")
            g.edge(parent_id, CodeRelationType.DEFINES.value, cid, parent_kind + " defines class")
            _walk(stmt.body, cid, "class", cq, g, fpath, modname, lines)

        elif isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef)):
            fq = qual + "." + stmt.name
            etype = CodeEntityType.TEST.value if _is_test(stmt.name) else CodeEntityType.FUNCTION.value
            fid = g.node("fn:" + fq, stmt.name, etype,
                         desc=("async " if isinstance(stmt, ast.AsyncFunctionDef) else "") + "function",
                         signature=_sig(stmt), file_path=fpath, line=getattr(stmt, "lineno", 0),
                         kind=("async" if isinstance(stmt, ast.AsyncFunctionDef) else ""), module=modname)
            g.func_by_name.setdefault(stmt.name, set()).add(fid)
            if parent_kind == "class":
                g.methods_of.setdefault(qual, {})[stmt.name] = fid
            g.edge(parent_id, CodeRelationType.CONTAINS.value, fid, parent_kind + " contains function")
            g.edge(parent_id, CodeRelationType.DEFINES.value, fid, parent_kind + " defines function")
            try:
                for arg in _all_args(stmt):
                    if arg.arg in ("self", "cls"): continue
                    pid = g.node("par:" + fq + "." + arg.arg, arg.arg, CodeEntityType.PARAMETER.value,
                                 desc="parameter", file_path=fpath, line=getattr(arg, "lineno", 0), module=modname)
                    g.edge(fid, CodeRelationType.CONTAINS.value, pid, "function contains parameter")
            except Exception: pass
            _walk([s for s in stmt.body if isinstance(s, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef))],
                  fid, "function", fq, g, fpath, modname, lines)

        elif isinstance(stmt, (ast.Assign, ast.AnnAssign)):
            targets = stmt.targets if isinstance(stmt, ast.Assign) else [stmt.target]
            for t in targets:
                if isinstance(t, ast.Name):
                    name = t.id; is_const = name.isupper() and len(name) > 1
                    etype = CodeEntityType.CONSTANT.value if is_const else CodeEntityType.VARIABLE.value
                    vid = g.node("var:" + qual + "." + name, name, etype,
                                 desc=("constant" if is_const else "variable"), file_path=fpath,
                                 line=getattr(stmt, "lineno", 0), module=modname)
                    g.var_by_scope.setdefault(qual, {})[name] = vid
                    g.edge(parent_id, CodeRelationType.DEFINES.value, vid,
                           parent_kind + " defines " + ("constant" if is_const else "variable"))

        elif isinstance(stmt, ast.Import) and parent_kind == "module":
            for alias in stmt.names:
                top = alias.name.split(".")[0]
                iid = g.node("mod:" + top, top, CodeEntityType.MODULE.value,
                             desc="imported module", kind="external", module=top)
                g.edge(parent_id, CodeRelationType.IMPORTS.value, iid, "module imports " + top)
        elif isinstance(stmt, ast.ImportFrom) and parent_kind == "module":
            top = (stmt.module or "").split(".")[0]
            if top:
                iid = g.node("mod:" + top, top, CodeEntityType.MODULE.value,
                             desc="imported module", kind="external", module=top)
                g.edge(parent_id, CodeRelationType.IMPORTS.value, iid, "module imports " + top)


def _parse_structure(path, root, g):
    try:
        src = open(path, "r", encoding="utf-8", errors="replace").read()
        tree = ast.parse(src, filename=path); lines = src.splitlines()
    except SyntaxError as e:
        logger.warning("code_parser: skip %s (%s)", path, e); return None
    modname = _module_name(path, root)
    mid = g.node("mod:" + modname, modname, CodeEntityType.MODULE.value,
                 desc="module " + modname, file_path=path, line=1, module=modname)
    _walk(tree.body, mid, "module", modname, g, path, modname, lines)
    return (tree, lines, modname, mid)


# ── Stage 2: name resolution ───────────────────────────────────────────────
def _qual(node, modname):
    names = []; cur = node
    while cur is not None and not isinstance(cur, ast.Module):
        if isinstance(cur, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.append(cur.name)
        cur = getattr(cur, "_parent", None)
    return modname + ("." + ".".join(reversed(names)) if names else "")

def _method_class(fn, modname):
    cur = getattr(fn, "_parent", None)
    while cur is not None:
        if isinstance(cur, (ast.FunctionDef, ast.AsyncFunctionDef)): return None
        if isinstance(cur, ast.ClassDef): return _qual(cur, modname)
        if isinstance(cur, ast.Module): return None
        cur = getattr(cur, "_parent", None)
    return None

def _owner(node, modname, mid):
    cur = getattr(node, "_parent", None)
    while cur is not None:
        if isinstance(cur, (ast.FunctionDef, ast.AsyncFunctionDef)):
            return "fn:" + _qual(cur, modname), _method_class(cur, modname), set(a.arg for a in _all_args(cur))
        if isinstance(cur, ast.ClassDef):
            return "cls:" + _qual(cur, modname), _qual(cur, modname), set()
        if isinstance(cur, ast.Module): break
        cur = getattr(cur, "_parent", None)
    return mid, None, set()

def _resolve_var(g, name, class_qual, modname):
    if class_qual and class_qual in g.var_by_scope:
        v = g.var_by_scope[class_qual].get(name)
        if v: return v
    if modname in g.var_by_scope:
        return g.var_by_scope[modname].get(name)
    return None

def _resolve_file(tree, modname, mid, g, lines):
    for n in ast.walk(tree):
        for c in ast.iter_child_nodes(n): c._parent = n
    tree._parent = None
    skip = set()   # ids of annotation/base nodes, so type names are not read as READS

    for n in ast.walk(tree):
        if isinstance(n, ast.ClassDef):
            cid = "cls:" + _qual(n, modname)
            for b in n.bases:
                _mark(skip, b)
                for tn in _type_names(b):
                    if tn in _BUILTIN_TYPES: continue
                    tgt = g.resolve_class(tn, modname)
                    if tgt:
                        g.edge(cid, CodeRelationType.INHERITS.value, tgt,
                               cid + " inherits " + tn, getattr(n, "lineno", 0), _ln(lines, n))
        elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)):
            fq = _qual(n, modname); fid = "fn:" + fq
            for arg in _all_args(n):
                if getattr(arg, "annotation", None) is not None:
                    _mark(skip, arg.annotation)
                    for tn in _type_names(arg.annotation):
                        if tn in _BUILTIN_TYPES: continue
                        tgt = g.resolve_class(tn, modname); pid = "par:" + fq + "." + arg.arg
                        if tgt and pid in g.nodes:
                            g.edge(pid, CodeRelationType.HAS_TYPE.value, tgt,
                                   arg.arg + ": " + tn, getattr(arg, "lineno", 0), "")
            if getattr(n, "returns", None) is not None:
                _mark(skip, n.returns)
                for tn in _type_names(n.returns):
                    if tn in _BUILTIN_TYPES: continue
                    tgt = g.resolve_class(tn, modname)
                    if tgt:
                        g.edge(fid, CodeRelationType.RETURNS.value, tgt,
                               fq + " -> " + tn, getattr(n, "lineno", 0), _ln(lines, n))

    for n in ast.walk(tree):
        if isinstance(n, ast.Call):
            owner, cq, _p = _owner(n, modname, mid); f = n.func
            if isinstance(f, ast.Name):
                cls = g.resolve_class(f.id, modname)
                if cls:
                    g.edge(owner, CodeRelationType.INSTANTIATES.value, cls,
                           "instantiates " + f.id, getattr(n, "lineno", 0), _ln(lines, n))
                else:
                    fn = g.resolve_func(f.id, modname)
                    if fn:
                        g.edge(owner, CodeRelationType.CALLS.value, fn,
                               "calls " + f.id, getattr(n, "lineno", 0), _ln(lines, n))
            elif (isinstance(f, ast.Attribute) and isinstance(f.value, ast.Name)
                  and f.value.id == "self" and cq and cq in g.methods_of):
                m = g.methods_of[cq].get(f.attr)
                if m:
                    g.edge(owner, CodeRelationType.CALLS.value, m,
                           "calls self." + f.attr, getattr(n, "lineno", 0), _ln(lines, n))
        elif isinstance(n, ast.Name) and id(n) not in skip:
            par = getattr(n, "_parent", None)
            if isinstance(par, ast.Call) and par.func is n: continue
            owner, cq, params = _owner(n, modname, mid)
            if n.id in params: continue
            vid = _resolve_var(g, n.id, cq, modname)
            if vid and vid != owner:
                if isinstance(getattr(n, "ctx", None), ast.Store):
                    g.edge(owner, CodeRelationType.WRITES.value, vid,
                           "writes " + n.id, getattr(n, "lineno", 0), _ln(lines, n))
                elif isinstance(getattr(n, "ctx", None), ast.Load):
                    g.edge(owner, CodeRelationType.READS.value, vid,
                           "reads " + n.id, getattr(n, "lineno", 0), _ln(lines, n))


def build_code_graph(filepath, language="python"):
    """Entry point called by orchestrator.run(mode='code')."""
    g = _Graph(); files = []
    if os.path.isdir(filepath):
        root = filepath
        for dp, dn, fn in os.walk(filepath):
            dn[:] = [d for d in dn if d not in (".git", "__pycache__", "node_modules", ".venv", "venv")]
            files += [os.path.join(dp, f) for f in fn if f.endswith(".py")]
    else:
        root = os.path.dirname(filepath) or "."
        if filepath.endswith(".py"): files = [filepath]

    if not files:
        return KnowledgeGraph(document_name=os.path.basename(filepath), nodes=[], edges=[],
            metadata={"mode": "code", "language": language,
                      "error": "No .py files found. Stage 1/2 support Python only."})

    parsed = []
    for f in sorted(files):
        r = _parse_structure(f, root, g)
        if r: parsed.append(r)
    for (tree, lines, modname, mid) in parsed:
        _resolve_file(tree, modname, mid, g, lines)

    return KnowledgeGraph(document_name=os.path.basename(filepath.rstrip("/")) or "code",
        nodes=list(g.nodes.values()), edges=g.edges(),
        metadata={"mode": "code", "language": language, "generator": "code_parser.stage2",
                  "files": len(files), "node_count": len(g.nodes), "edge_count": len(g.edges())})
