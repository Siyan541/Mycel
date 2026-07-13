# services/media.py (v15)
# Explainable provenance: match each concept to its BEST source sentence by
# EMBEDDING similarity (paraphrase-robust), attach a match score + all top
# mentions, and mark in_text honestly. Falls back to token overlap if no
# embedding backend is installed. Relation evidence now lands on GraphEdge
# (which finally has page/evidence fields).
# Deps: fastembed (light, onnx) preferred; PyMuPDF + pdfplumber for media.
import base64, re, logging, os
logger = logging.getLogger(__name__)

_CAPTION = re.compile(r'^\s*(figure|fig\.?|table|chart|diagram|plate)\s*\d', re.I)
_SENT = re.compile(r'[^.!?]*[.!?]')
_COMMON = {"theorem","figure","table","definition","section","chapter","equation",
           "example","lemma","proof","corollary","the","and","for","with","that",
           "this","from","are","was","which"}

_EMB = None; _EMB_OK = None

def _embedder():
    """Return (kind, model) or None. fastembed first, then sentence-transformers."""
    global _EMB, _EMB_OK
    if _EMB_OK is False: return None
    if _EMB is not None: return _EMB
    try:
        from fastembed import TextEmbedding
        name = os.environ.get("EMBED_MODEL", "BAAI/bge-small-en-v1.5")
        _EMB = ("fastembed", TextEmbedding(model_name=name)); _EMB_OK = True
        logger.info("embeddings: fastembed %s", name); return _EMB
    except Exception as e:
        logger.info("fastembed unavailable (%s)", e)
    try:
        from sentence_transformers import SentenceTransformer
        name = os.environ.get("EMBED_MODEL_ST", "sentence-transformers/all-MiniLM-L6-v2")
        _EMB = ("st", SentenceTransformer(name)); _EMB_OK = True
        logger.info("embeddings: sentence-transformers %s", name); return _EMB
    except Exception as e:
        logger.warning("no embedding backend, token-overlap fallback: %s", e)
        _EMB_OK = False; return None

def _encode(embedder, texts):
    import numpy as np
    kind, m = embedder
    texts = list(texts)
    if kind == "fastembed":
        return np.asarray(list(m.embed(texts)), dtype="float32")   # normalized
    v = np.asarray(m.encode(texts, normalize_embeddings=True), dtype="float32")
    return v

def _get(o, k, d=None): return o.get(k, d) if isinstance(o, dict) else getattr(o, k, d)
def _set(o, k, v):
    if isinstance(o, dict): o[k] = v
    else:
        try: setattr(o, k, v)
        except Exception: pass
def _norm(s): return re.sub(r'\s+', ' ', (s or '')).strip()

def _page_texts(pdf_path):
    import fitz
    doc = fitz.open(pdf_path)
    t = [doc[i].get_text("text") for i in range(len(doc))]
    doc.close(); return t

def _toks(s):
    out = []
    for w in re.split(r'[^a-z0-9.]+', (s or '').lower()):
        w = w.strip('.')
        if len(w) >= 3 and w not in _COMMON: out.append(w)
    return out

def _sentences(pages):
    for pi, text in enumerate(pages):
        flat = _norm(text)
        for m in _SENT.finditer(flat):
            s = m.group().strip()
            if len(s) < 12: continue
            yield pi, s, set(re.split(r'[^a-z0-9]+', s.lower()))

# 1) concept provenance — embedding-scored best sentence + all mentions
def attach_provenance(nodes, pdf_path):
    try:
        pages = _page_texts(pdf_path)
    except Exception as e:
        logger.warning("provenance: %s", e); return nodes
    low = [_norm(t).lower() for t in pages]
    sents = list(_sentences(pages))
    if not sents: return nodes

    emb = _embedder(); sent_vecs = None
    if emb is not None:
        try:
            sent_vecs = _encode(emb, [s for _, s, _ in sents])
        except Exception as e:
            logger.warning("sentence encode failed: %s", e); sent_vecs = None

    import numpy as np
    for n in nodes:
        label = _get(n, "label") or ""; desc = _get(n, "description") or ""
        lab_l = _norm(label).lower()
        lab_tokens = set(_toks(label)); desc_tokens = set(_toks(desc))
        if not lab_tokens and not desc_tokens:
            _set(n, "in_text", False); continue

        ranked = []   # (score0to1, page_index, sentence)
        if sent_vecs is not None:
            try:
                q = _encode(emb, [f"{label}. {desc}".strip()])[0]
                sims = sent_vecs @ q
                for idx in np.argsort(-sims)[:8]:
                    pi, s, _sl = sents[int(idx)]
                    sc = float(sims[int(idx)])
                    if lab_l and lab_l in s.lower(): sc = min(1.0, sc + 0.15)
                    ranked.append((sc, pi, s))
            except Exception as e:
                logger.warning("embed match: %s", e); ranked = []

        if not ranked:   # token-overlap fallback (normalized to ~0–1)
            for pi, s, sl in sents:
                raw = 0; sloc = s.lower()
                if lab_l and lab_l in sloc: raw += 6
                raw += 2 * len(lab_tokens & sl) + 1 * len(desc_tokens & sl)
                if raw > 0: ranked.append((min(1.0, raw / 8.0), pi, s))
            ranked.sort(key=lambda x: -x[0]); ranked = ranked[:8]

        if not ranked:
            # last resort: first page mentioning any distinctive token
            for t in _toks(label):
                for i, lt in enumerate(low):
                    if t in lt: _set(n, "source_page", i + 1); break
                else: continue
                break
            _set(n, "in_text", False); continue

        best_sc, best_pi, best_s = ranked[0]
        grounded = best_sc >= 0.45 or (lab_l and lab_l in best_s.lower())
        _set(n, "source_page", best_pi + 1)
        _set(n, "source_quote", best_s[:240])
        _set(n, "source_score", round(best_sc, 3))
        _set(n, "in_text", bool(grounded))
        _set(n, "mentions", [{"page": pi + 1, "quote": s[:240], "score": round(sc, 3)}
                             for sc, pi, s in ranked[:5]])
    return nodes

# 2) relation provenance — co-occurrence, embedding re-ranked
def attach_relation_provenance(edges, nodes, pdf_path):
    try:
        pages = _page_texts(pdf_path)
    except Exception as e:
        logger.warning("rel provenance: %s", e); return edges
    lbl = {_get(n, "id"): (_get(n, "label") or "") for n in nodes}
    sents = list(_sentences(pages))
    emb = _embedder()
    for e in edges:
        sid = _get(e, "source") or _get(e, "source_id")
        tid = _get(e, "target") or _get(e, "target_id")
        sa = set(_toks(lbl.get(sid, ""))); sb = set(_toks(lbl.get(tid, "")))
        if not sa or not sb: continue
        cands = []
        for pi, s, sl in sents:
            if (sa & sl) and (sb & sl):
                cands.append((len(sa & sl) + len(sb & sl), pi, s))
        if not cands: continue
        cands.sort(key=lambda x: -x[0]); cands = cands[:6]
        best = cands[0]
        if emb is not None and len(cands) > 1:
            try:
                import numpy as np
                q = _encode(emb, [f"{lbl.get(sid,'')} relates to {lbl.get(tid,'')}"])[0]
                cv = _encode(emb, [c[2] for c in cands])
                best = cands[int(np.argmax(cv @ q))]
            except Exception: pass
        _set(e, "page", best[1] + 1)
        _set(e, "evidence", best[2][:240])
    return edges

# 3) media: rasters + vector figures + tables + formulas
def extract_media(pdf_path, text_only=False, max_items=60):
    if text_only: return []
    out = []
    try:
        import fitz
        doc = fitz.open(pdf_path)
        for pno in range(len(doc)):
            page = doc[pno]; pw, ph = page.rect.width, page.rect.height
            for img in page.get_images(full=True):
                try:
                    pix = fitz.Pixmap(doc, img[0])
                    if pix.n - pix.alpha >= 4: pix = fitz.Pixmap(fitz.csRGB, pix)
                    if pix.width < 70 or pix.height < 70: continue
                    b64 = base64.b64encode(pix.tobytes("png")).decode("ascii")
                    out.append({"kind": "image", "page": pno + 1,
                                "image": "data:image/png;base64," + b64})
                except Exception: pass
            try:
                d = page.get_text("dict")
                for blk in d.get("blocks", []):
                    for line in blk.get("lines", []):
                        txt = "".join(sp.get("text", "") for sp in line.get("spans", []))
                        if _CAPTION.match(txt or ""):
                            y1 = line["bbox"][1]
                            clip = fitz.Rect(0, max(0, y1 - 320), pw, min(ph, y1 + 6))
                            pix = page.get_pixmap(matrix=fitz.Matrix(2, 2), clip=clip)
                            if pix.width > 80 and pix.height > 60:
                                b64 = base64.b64encode(pix.tobytes("png")).decode("ascii")
                                out.append({"kind": "image", "page": pno + 1,
                                            "image": "data:image/png;base64," + b64,
                                            "caption": _norm(txt)[:120]})
            except Exception as e:
                logger.warning("vector figure p%s: %s", pno, e)
            if len(out) >= max_items: break
        doc.close()
    except Exception as e:
        logger.warning("PyMuPDF media: %s", e)
    try:
        import pdfplumber
        with pdfplumber.open(pdf_path) as pdf:
            for pno, page in enumerate(pdf.pages):
                for tbl in (page.extract_tables() or []):
                    rows = [[(c or "").strip() for c in r] for r in tbl if any(r)]
                    if len(rows) >= 2 and len(rows[0]) >= 2:
                        out.append({"kind": "table", "page": pno + 1, "rows": rows[:20]})
    except Exception as e:
        logger.warning("pdfplumber: %s", e)
    try:
        import fitz
        doc = fitz.open(pdf_path)
        has_eq = re.compile(r"[A-Za-z0-9_)\]\(\[]+\s*=\s*[^=\n]{2,60}")
        mathish = re.compile(r"[=\u00b1\u2211\u222b\u221a\u2202\u2264\u2265\u2248\u2192\u00b7\u00d7^_]|\\frac|\\sqrt")
        seen = set()
        for pno in range(len(doc)):
            for line in doc[pno].get_text("text").split("\n"):
                s = line.strip()
                if 3 <= len(s) <= 80 and mathish.search(s) and has_eq.search(s) and s not in seen:
                    seen.add(s); out.append({"kind": "formula", "page": pno + 1, "formula": s})
        doc.close()
    except Exception as e:
        logger.warning("formula scan: %s", e)
    return out

def enrich(graph, pdf_path, text_only=False):
    try: attach_provenance(graph.nodes, pdf_path)
    except Exception as e: logger.warning("enrich nodes: %s", e)
    try: attach_relation_provenance(graph.edges, graph.nodes, pdf_path)
    except Exception as e: logger.warning("enrich edges: %s", e)
    figures = extract_media(pdf_path, text_only=text_only)
    try:
        graph.metadata = dict(getattr(graph, "metadata", None) or {})
        graph.metadata["figures"] = figures
    except Exception: pass
    return figures
