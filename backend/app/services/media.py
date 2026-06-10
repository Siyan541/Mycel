# backend/app/services/media.py
# Records provenance at EXTRACTION time so the frontend never has to guess:
#   - concepts get an exact page + verbatim definition sentence
#   - relations get an exact page + verbatim evidence sentence (for the link underline)
#   - figures/tables/formulas get a page + caption (+ vector figures via caption-region render)
# Requires: PyMuPDF (fitz) + pdfplumber   ->   pip install PyMuPDF pdfplumber
import base64, re, logging
logger = logging.getLogger(__name__)

_CAPTION = re.compile(r'^\s*(figure|fig\.?|table|chart|diagram|plate)\s*\d', re.I)
_SENT = re.compile(r'[^.!?]*[.!?]')


def _get(o, k, d=None):
    return o.get(k, d) if isinstance(o, dict) else getattr(o, k, d)


def _set(o, k, v):
    if isinstance(o, dict):
        o[k] = v
    else:
        try:
            setattr(o, k, v)
        except Exception:
            pass


def _norm(s):
    return re.sub(r'\s+', ' ', (s or '')).strip()


def _page_texts(pdf_path):
    import fitz
    doc = fitz.open(pdf_path)
    texts = [doc[i].get_text("text") for i in range(len(doc))]
    doc.close()
    return texts


def _sig_tokens(s):
    common = {"theorem", "figure", "table", "definition", "section", "chapter",
              "equation", "example", "lemma", "proof", "corollary", "the", "and",
              "for", "with", "that", "this", "from"}
    out = []
    for w in re.split(r'[^a-z0-9.]+', (s or '').lower()):
        w = w.strip('.')
        if len(w) >= 3 and w not in common:
            out.append(w)
    return out


def _sentence_with(text, needle_lower):
    flat = _norm(text)
    low = flat.lower()
    i = low.find(needle_lower)
    if i < 0:
        return None
    for m in _SENT.finditer(flat):
        if m.start() <= i < m.end():
            return m.group().strip()
    return flat[max(0, i - 80): i + 160].strip()


# 1) concept provenance: exact page + verbatim definition sentence
def attach_provenance(nodes, pdf_path):
    try:
        pages = _page_texts(pdf_path)
    except Exception as e:
        logger.warning("provenance: %s", e)
        return nodes
    low = [_norm(t).lower() for t in pages]
    for n in nodes:
        label = _get(n, "label") or ""
        quote = _get(n, "source_quote") or ""
        lab_l = _norm(label).lower()
        probe = _norm(quote).lower()[:60] or lab_l
        if not probe:
            continue
        hit = None
        if lab_l:
            for i, lt in enumerate(low):
                if lab_l in lt:
                    hit, probe = i, lab_l
                    break
        if hit is None:
            for i, lt in enumerate(low):
                if probe and probe in lt:
                    hit = i
                    break
        if hit is None:
            toks = _sig_tokens(label)
            toks.sort(key=lambda t: sum(1 for lt in low if t in lt) or 999)
            for t in toks:
                for i, lt in enumerate(low):
                    if t in lt:
                        hit, probe = i, t
                        break
                if hit is not None:
                    break
        if hit is not None:
            sent = _sentence_with(pages[hit], probe) or _norm(quote) or label
            _set(n, "source_page", hit + 1)
            _set(n, "source_quote", sent[:240])
    return nodes


# 2) relation provenance: page + verbatim evidence sentence
def attach_relation_provenance(edges, nodes, pdf_path):
    try:
        pages = _page_texts(pdf_path)
    except Exception as e:
        logger.warning("rel provenance: %s", e)
        return edges
    lbl = {}
    for n in nodes:
        lbl[_get(n, "id")] = _get(n, "label") or ""
    for e in edges:
        sa = _sig_tokens(lbl.get(_get(e, "source") or _get(e, "source_id"), ""))
        sb = _sig_tokens(lbl.get(_get(e, "target") or _get(e, "target_id"), ""))
        if not sa or not sb:
            continue
        found = False
        for pi, text in enumerate(pages):
            for m in _SENT.finditer(_norm(text)):
                s = m.group().lower()
                if any(t in s for t in sa) and any(t in s for t in sb):
                    _set(e, "page", pi + 1)
                    _set(e, "evidence", m.group().strip()[:240])
                    found = True
                    break
            if found:
                break
    return edges


# 3) media: rasters + vector figures (caption regions) + tables + formulas
def extract_media(pdf_path, text_only=False, max_items=60):
    if text_only:
        return []
    out = []
    try:
        import fitz
        doc = fitz.open(pdf_path)
        for pno in range(len(doc)):
            page = doc[pno]
            pw, ph = page.rect.width, page.rect.height
            for img in page.get_images(full=True):
                try:
                    pix = fitz.Pixmap(doc, img[0])
                    if pix.n - pix.alpha >= 4:
                        pix = fitz.Pixmap(fitz.csRGB, pix)
                    if pix.width < 70 or pix.height < 70:
                        continue
                    b64 = base64.b64encode(pix.tobytes("png")).decode("ascii")
                    out.append({"kind": "image", "page": pno + 1, "image": "data:image/png;base64," + b64})
                except Exception:
                    pass
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
            if len(out) >= max_items:
                break
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
                    seen.add(s)
                    out.append({"kind": "formula", "page": pno + 1, "formula": s})
        doc.close()
    except Exception as e:
        logger.warning("formula scan: %s", e)
    return out


# one call from the upload route (before save_map)
def enrich(graph, pdf_path, text_only=False):
    try:
        attach_provenance(graph.nodes, pdf_path)
    except Exception as e:
        logger.warning("enrich nodes: %s", e)
    try:
        attach_relation_provenance(graph.edges, graph.nodes, pdf_path)
    except Exception as e:
        logger.warning("enrich edges: %s", e)
    figures = extract_media(pdf_path, text_only=text_only)
    try:
        graph.metadata = dict(getattr(graph, "metadata", None) or {})
        graph.metadata["figures"] = figures
    except Exception:
        pass
    return figures