import re, uuid, os
from collections import Counter
import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.models import Section, Skeleton

CHAPTER_RE = [r"^chapter\s+\d+", r"^\d+\s+[A-Z][a-z]", r"^\d+\.\s+[A-Z]",
    r"^part\s+[ivxlcdm\d]+", r"^lesson\s+\d+", r"^appendix\s+[a-z]"]
SECTION_RE = [r"^\d+\.\d+\s+[A-Z]"]

def _heading_level(text):
    t = text.strip()
    for p in CHAPTER_RE:
        if re.match(p, t, re.IGNORECASE): return 0
    if re.match(r"^\d+\.\d+\.\d+\s+[A-Z]", t): return 2
    for p in SECTION_RE:
        if re.match(p, t): return 1
    return None

def _sections_from_text(text, filename):
    """Parse plain text into sections by detecting heading patterns."""
    lines = text.split('\n')
    sections = []
    current_title = "Full Document"
    current_lines = []
    current_level = 0

    for line in lines:
        hl = _heading_level(line)
        if hl is not None and len(line.strip()) < 150 and len(line.strip()) > 2:
            if current_lines:
                body = '\n'.join(current_lines).strip()
                if len(body) > 50:
                    sections.append(Section(
                        id=str(uuid.uuid4())[:12], title=current_title[:120],
                        level=current_level, page_start=0, page_end=0,
                        text=body))
            current_title = line.strip()
            current_level = hl
            current_lines = []
        else:
            current_lines.append(line)

    if current_lines:
        body = '\n'.join(current_lines).strip()
        if len(body) > 50:
            sections.append(Section(
                id=str(uuid.uuid4())[:12], title=current_title[:120],
                level=current_level, page_start=0, page_end=0, text=body))

    if not sections:
        sections = [Section(id=str(uuid.uuid4())[:12], title="Full Document",
            level=0, page_start=0, page_end=0, text=text[:50000])]

    return sections

def _parse_pdf(filepath):
    import pymupdf
    doc = pymupdf.open(filepath)
    total = len(doc)
    sizes = Counter()
    for pg in range(min(total, 40)):
        for b in doc[pg].get_text("dict")["blocks"]:
            if b.get("type") != 0: continue
            for l in b.get("lines", []):
                for s in l.get("spans", []):
                    sz = round(s["size"], 1)
                    if len(s["text"].strip()) > 2: sizes[sz] += len(s["text"])
    body = sizes.most_common(1)[0][0] if sizes else 12
    hsizes = sorted([s for s in sizes if s > body * 1.15], reverse=True)
    lmap = {sz: i for i, sz in enumerate(hsizes[:4])}
    sections, stack, body_parts, cur = [], [], [], None

    def flush():
        nonlocal body_parts
        if cur and body_parts:
            text = "\n".join(body_parts).strip()
            for s in sections:
                if s.id == cur: s.text = text; break
        body_parts = []

    for pg in range(total):
        for b in doc[pg].get_text("dict")["blocks"]:
            if b.get("type") != 0: continue
            text, maxsz, bold = "", 0, False
            for l in b.get("lines", []):
                for s in l.get("spans", []):
                    text += s["text"]; maxsz = max(maxsz, round(s["size"], 1))
                    if any(x in s.get("font","").lower() for x in ("bold","cmbx","black")): bold = True
                text += "\n"
            text = text.strip()
            if not text or len(text) < 2: continue
            hl = None
            if round(maxsz,1) in lmap and len(text) < 200: hl = lmap[round(maxsz,1)]
            rl = _heading_level(text)
            if rl is not None and len(text) < 150: hl = rl if hl is None else min(hl, rl)
            if hl is None and bold and len(text) < 80: hl = 1
            if hl is not None:
                flush()
                sid = str(uuid.uuid4())[:12]; pid = None
                while stack and len(stack) > hl: stack.pop()
                if stack: pid = stack[-1]
                sections.append(Section(id=sid, title=text[:120], level=hl,
                    page_start=pg, page_end=pg, text="", parent_id=pid))
                stack = stack[:hl] + [sid]; cur = sid
            else:
                body_parts.append(text)
                if cur:
                    for s in sections:
                        if s.id == cur: s.page_end = pg; break
    flush()
    if not any(s.text and len(s.text) > 100 for s in sections):
        full = "\n".join(p.get_text() for p in doc)
        sections = [Section(id=str(uuid.uuid4())[:12], title="Full Document",
            level=0, page_start=0, page_end=total-1, text=full)]
    doc.close()
    return Skeleton(filename=filepath.split("/")[-1], total_pages=total, sections=sections)

def _parse_docx(filepath):
    """Parse DOCX using python-docx."""
    try:
        from docx import Document
    except ImportError:
        # Fallback: extract as plain text
        import zipfile
        with zipfile.ZipFile(filepath) as z:
            from xml.etree import ElementTree as ET
            tree = ET.parse(z.open('word/document.xml'))
            ns = {'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
            text = '\n'.join(p.text or '' for p in tree.iter('{%s}t' % ns['w']))
        sections = _sections_from_text(text, filepath)
        return Skeleton(filename=os.path.basename(filepath), total_pages=1, sections=sections)

    doc = Document(filepath)
    text = '\n'.join(p.text for p in doc.paragraphs if p.text.strip())
    sections = _sections_from_text(text, filepath)
    return Skeleton(filename=os.path.basename(filepath), total_pages=1, sections=sections)

def _parse_text(filepath):
    """Parse plain text, markdown, or similar."""
    with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
        text = f.read()
    sections = _sections_from_text(text, filepath)
    return Skeleton(filename=os.path.basename(filepath), total_pages=1, sections=sections)

def parse_file(filepath):
    """Route to the right parser based on file extension."""
    ext = os.path.splitext(filepath)[1].lower()
    if ext == '.pdf':
        return _parse_pdf(filepath)
    elif ext == '.docx':
        return _parse_docx(filepath)
    elif ext in ('.txt', '.md', '.markdown', '.rst', '.tex'):
        return _parse_text(filepath)
    elif ext == '.epub':
        # Extract text from EPUB
        try:
            import zipfile
            from xml.etree import ElementTree as ET
            texts = []
            with zipfile.ZipFile(filepath) as z:
                for name in z.namelist():
                    if name.endswith(('.xhtml', '.html', '.htm')):
                        tree = ET.parse(z.open(name))
                        for elem in tree.iter():
                            if elem.text and elem.text.strip():
                                texts.append(elem.text.strip())
            text = '\n'.join(texts)
        except:
            text = "Could not parse EPUB"
        sections = _sections_from_text(text, filepath)
        return Skeleton(filename=os.path.basename(filepath), total_pages=1, sections=sections)
    else:
        # Try as plain text
        return _parse_text(filepath)

# Keep backward compat
parse_pdf = _parse_pdf
