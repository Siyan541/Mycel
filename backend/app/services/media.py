# backend/app/services/media.py
# Media extraction (images / tables / formulas) + source-provenance repair.
# Requires: PyMuPDF (fitz) and pdfplumber  ->  pip install PyMuPDF pdfplumber
import base64, re, logging
logger = logging.getLogger(__name__)


# ─────────────────────────────────────────────────────────────────────────
# MEDIA: pull figures, tables and display formulas out of the PDF.
# Returns a list the frontend already understands (App.jsx -> extractMediaCards):
#   {kind:"image",   page:int, image:"data:image/png;base64,..."}
#   {kind:"table",   page:int, rows:[[cell,...],...]}
#   {kind:"formula", page:int, formula:"E = mc^2"}
# Gated by text_only=True (the Settings "Text only" toggle sends ?text_only=1).
# ─────────────────────────────────────────────────────────────────────────
def extract_media(pdf_path, text_only=False, max_images=40):
    if text_only:
        return []
    out = []

    # ---- Images (PyMuPDF) ----
    try:
        import fitz
        doc = fitz.open(pdf_path)
        seen, n_img = set(), 0
        for pno in range(len(doc)):
            if n_img >= max_images:
                break
            for img in doc[pno].get_images(full=True):
                xref = img[0]
                if xref in seen:
                    continue
                seen.add(xref)
                try:
                    pix = fitz.Pixmap(doc, xref)
                    if pix.n - pix.alpha >= 4:          # CMYK -> RGB
                        pix = fitz.Pixmap(fitz.csRGB, pix)
                    if pix.width < 60 or pix.height < 60:  # skip rules / icons
                        continue
                    b64 = base64.b64encode(pix.tobytes("png")).decode("ascii")
                    out.append({"kind": "image", "page": pno + 1,
                                "image": "data:image/png;base64," + b64})
                    n_img += 1
                    if n_img >= max_images:
                        break
                except Exception as e:
                    logger.warning("image xref %s: %s", xref, e)
        doc.close()
    except Exception as e:
        logger.warning("PyMuPDF image pass failed: %s", e)

    # ---- Tables (pdfplumber) ----
    try:
        import pdfplumber
        with pdfplumber.open(pdf_path) as pdf:
            for pno, page in enumerate(pdf.pages):
                for tbl in (page.extract_tables() or []):
                    rows = [[(c or "").strip() for c in row] for row in tbl if any(row)]
                    if len(rows) >= 2 and len(rows[0]) >= 2:
                        out.append({"kind": "table", "page": pno + 1, "rows": rows[:20]})
    except Exception as e:
        logger.warning("pdfplumber table pass failed: %s", e)

    # ---- Display formulas (heuristic over text lines) ----
    try:
        import fitz
        doc = fitz.open(pdf_path)
        has_eq   = re.compile(r"[A-Za-z0-9_)\]\(\[]+\s*=\s*[^=\n]{2,60}")
        mathish  = re.compile(r"[=±∑∫√∂≤≥≈→·×^_]|\\frac|\\sqrt")
        seenf = set()
        for pno in range(len(doc)):
            for line in doc[pno].get_text("text").split("\n"):
                s = line.strip()
                if 3 <= len(s) <= 80 and mathish.search(s) and has_eq.search(s):
                    if s not in seenf:
                        seenf.add(s)
                        out.append({"kind": "formula", "page": pno + 1, "formula": s})
        doc.close()
    except Exception as e:
        logger.warning("formula scan failed: %s", e)

    return out


# ─────────────────────────────────────────────────────────────────────────
# PROVENANCE: make the PDF split-view's auto-scroll + highlight actually work.
# The LLM often paraphrases `source_quote`, so the client can't find it in the
# text layer. This finds where each concept really appears and rewrites
# source_quote to a VERBATIM sentence span and sets the correct source_page.
# ─────────────────────────────────────────────────────────────────────────
def _norm(s):
    return re.sub(r"\s+", " ", (s or "")).strip().lower()


def _page_texts(pdf_path):
    import fitz
    doc = fitz.open(pdf_path)
    texts = [doc[i].get_text("text") for i in range(len(doc))]
    doc.close()
    return texts


def attach_provenance(nodes, pdf_path):
    """nodes: list of pydantic GraphNode OR dicts. Mutates in place; returns nodes."""
    try:
        pages = _page_texts(pdf_path)
    except Exception as e:
        logger.warning("provenance: cannot read pages: %s", e)
        return nodes
    flat = [re.sub(r"\s+", " ", t) for t in pages]
    low  = [t.lower() for t in flat]

    for n in nodes:
        is_dict = isinstance(n, dict)
        get  = (lambda k: n.get(k)) if is_dict else (lambda k: getattr(n, k, None))
        setv = (lambda k, v: n.__setitem__(k, v)) if is_dict else (lambda k, v: setattr(n, k, v))

        quote = get("source_quote") or ""
        label = get("label") or ""
        probe = _norm(quote)[:24] or _norm(label)[:24]
        if not probe:
            continue

        for i in range(len(low)):
            j = low[i].find(probe)
            if j < 0:
                continue
            # expand to the surrounding sentence for a clean verbatim highlight
            start = max(flat[i].rfind(".", 0, j), flat[i].rfind(";", 0, j)) + 1
            end = flat[i].find(".", j + len(probe))
            if end < 0:
                end = min(len(flat[i]), j + 160)
            verbatim = flat[i][start:end].strip()[:200]
            if verbatim:
                setv("source_quote", verbatim)
            setv("source_page", i + 1)
            break
    return nodes