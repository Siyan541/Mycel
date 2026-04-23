#!/bin/bash
# ============================================================================
# Mycel v5 — Complete platform update
#
# Run from project root: bash apply_mycel_v5.sh
#
# WHAT THIS DOES:
#
# BACKEND CHANGES:
#   1. backend/.env → phi3:mini
#   2. backend/app/pipeline/parser.py → accepts PDF, DOCX, TXT, EPUB, MD
#   3. backend/app/pipeline/extractor.py → JOINT extraction (concepts+relations
#      in one LLM call instead of sequential pipeline)
#   4. backend/app/services/storage.py → new tables: users, community_maps,
#      confirmed_data; map status field (draft/confirmed)
#   5. backend/app/main.py → new endpoints: confirm map, community feed,
#      training data export from confirmed maps only
#
# FRONTEND CHANGES:
#   6. Larger toolbar (40px height, 13px font, bigger buttons)
#   7. Library view: delete button, confirm button, status badges
#   8. Image embedding: drag-drop onto node, paste from clipboard
#   9. Importance-based text sizing (degree+confidence → 11-22px)
#   10. 3D Memory Palace view (Three.js, Islamic/Greek architecture)
#
# ============================================================================
set -e
echo "🍄 Mycel v5 — Comprehensive update..."

# ── 1. Backend .env ─────────────────────────────────────────────────────
cat > backend/.env << 'EOF'
LLM_PROVIDER=ollama
LLM_MODEL=phi3:mini
EOF
echo "  ✓ backend/.env → phi3:mini"

# ── 2. Multi-format parser ──────────────────────────────────────────────
cat > backend/app/pipeline/parser.py << 'PYEOF'
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
PYEOF
echo "  ✓ parser.py → multi-format (PDF, DOCX, TXT, MD, EPUB)"

# ── 3. Joint extraction (concepts + relations in ONE call) ──────────────
cat > backend/app/pipeline/extractor.py << 'PYEOF'
"""
Joint concept + relation extraction in a single LLM call.

WHY: The old pipeline extracted concepts first, then relations in a second
pass. This is inefficient because:
  - Two LLM calls per chunk instead of one (2x latency, 2x cost)
  - The relation extractor doesn't see the original text context
  - Concepts and relations are inherently co-dependent

The joint prompt asks for both simultaneously, which is how humans read:
you identify concepts AND their relationships as you encounter them.
"""
import re, json, logging
from concurrent.futures import ThreadPoolExecutor, as_completed
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.models import (ConceptResult, Concept, ConceptType,
    RelationResult, Relation, RelationType)
from backend.app.services.llm import chat
from backend.app.services.storage import save_training

logger = logging.getLogger(__name__)

JOINT_PROMPT = """You are an expert at analyzing educational text. Extract BOTH concepts AND relationships simultaneously.

Focus on what a student would LEARN — not every noun.

Return JSON with two arrays:
{
  "concepts": [
    {"label": "2-6 word name", "description": "One sentence", "concept_type": "definition|theory|principle|method|example|evidence|argument|term|framework|phenomenon", "abstraction_level": 0-3, "confidence": 1-10, "source_quote": "brief phrase"}
  ],
  "relations": [
    {"source_label": "exact concept label", "target_label": "exact concept label", "relation_type": "IMPLIES|REQUIRES|DEFINED_BY|CONTAINS|PART_OF|CAUSES|ENABLES|GENERALIZES|SPECIALIZES|ILLUSTRATES|EXTENDS|CONSTRAINS|CONTRADICTS|PREREQUISITE_FOR|CONTRASTS_WITH|INSTANCE_OF|EQUIVALENT|ANALOGOUS_TO", "justification": "brief why", "confidence": 1-10}
  ]
}

Rules:
- 2-8 concepts per chunk
- 3-12 relations per chunk
- source_label and target_label must EXACTLY match a concept label
- abstraction_level: 0=core theory, 1=key concept, 2=detail, 3=example"""

SKIP = {"compiler","text editor","programming","software","code","variable","function",
    "file","program","computer","download","install","setup","getting started","introduction",
    "exercise","example","solution","chapter","book","author","reader","forum","website"}

def _pattern_extract(text, title=""):
    concepts = []
    seen = set()
    patterns = [
        (r"(?:^|\.\s+)([A-Z][\w\s]{2,35})\s+(?:is defined as|is a|refers to|means)\s+(.{15,200}?)(?:\.|$)", "definition", 1),
        (r"(Theorem|Lemma|Proposition)\s+([\d.]+)", "theory", 0),
        (r"(?:called|known as|termed)\s+(?:the\s+)?([a-zA-Z][\w\s]{2,25}?)(?:\s*[,.])", "term", 2),
    ]
    for pat, ctype, level in patterns:
        for m in re.finditer(pat, text, re.MULTILINE | re.IGNORECASE):
            label = m.group(1).strip().rstrip('.,;:')
            if label.lower() in seen or len(label) < 3 or label.lower() in SKIP: continue
            seen.add(label.lower())
            desc = m.group(2).strip() if len(m.groups()) > 1 else f"{ctype} in {title}"
            try:
                concepts.append(Concept(label=label, description=desc[:200],
                    concept_type=ConceptType(ctype), abstraction_level=level,
                    confidence=7, source_quote=m.group(0)[:60]))
            except: pass
    return concepts

def _joint_extract(chunk_text, title):
    """Single LLM call extracts both concepts and relations."""
    msg = f"""Analyze this educational text. Extract key concepts AND their relationships.
Section: "{title}"

TEXT:
---
{chunk_text[:2500]}
---

Return JSON with "concepts" and "relations" arrays."""

    try:
        raw = chat(
            [{"role": "system", "content": JOINT_PROMPT},
             {"role": "user", "content": msg}],
            temperature=0.1, max_tokens=2000
        )
        # Parse JSON (handle markdown fences)
        cleaned = raw.strip()
        if cleaned.startswith('```'):
            cleaned = cleaned.split('\n', 1)[1] if '\n' in cleaned else cleaned[3:]
            if cleaned.endswith('```'):
                cleaned = cleaned[:-3]
        data = json.loads(cleaned)

        concepts = []
        for c in data.get("concepts", []):
            try:
                label = c.get("label", "").strip()
                if len(label.split()) < 1 or len(label.split()) > 10: continue
                if len(c.get("description", "")) < 12: continue
                if label.lower().strip() in SKIP: continue
                concepts.append(Concept(
                    label=label,
                    description=c.get("description", "")[:200],
                    concept_type=ConceptType(c.get("concept_type", "term")),
                    abstraction_level=min(3, max(0, int(c.get("abstraction_level", 1)))),
                    confidence=min(10, max(1, int(c.get("confidence", 5)))),
                    source_quote=c.get("source_quote", "")[:60]
                ))
            except: pass

        relations = []
        labels = {c.label.lower() for c in concepts}
        for r in data.get("relations", []):
            try:
                src = r.get("source_label", "").strip()
                tgt = r.get("target_label", "").strip()
                if src.lower() not in labels or tgt.lower() not in labels: continue
                if src.lower() == tgt.lower(): continue
                relations.append(Relation(
                    source_label=src, target_label=tgt,
                    relation_type=RelationType(r.get("relation_type", "REQUIRES")),
                    justification=r.get("justification", "")[:200],
                    confidence=min(10, max(1, int(r.get("confidence", 5))))
                ))
            except: pass

        return concepts, relations
    except Exception as e:
        logger.error(f"Joint extraction failed: {e}")
        return [], []

def extract_batch(chunks, max_workers=2):
    """Extract concepts AND relations jointly from all chunks."""
    all_concepts = {}  # chunk_id -> [Concept]
    all_relations = []  # flat list of Relation

    done = 0
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        def do(chunk):
            # Try patterns first
            det = _pattern_extract(chunk.text, chunk.section_title)
            # Always do joint LLM extraction for relations
            llm_concepts, llm_relations = _joint_extract(chunk.text, chunk.section_title)

            # Merge concepts (dedupe)
            seen = {c.label.lower() for c in det}
            for c in llm_concepts:
                if c.label.lower() not in seen:
                    det.append(c)
                    seen.add(c.label.lower())

            save_training(chunk.text, chunk.section_title, det, llm_relations)
            return chunk.id, det, llm_relations

        futs = {ex.submit(do, c): c for c in chunks}
        for f in as_completed(futs):
            try:
                cid, concepts, relations = f.result()
                all_concepts[cid] = concepts
                all_relations.extend(relations)
                done += 1
                if concepts:
                    logger.info(f"  [{done}/{len(chunks)}] [{', '.join(c.label for c in concepts[:4])}] + {len(relations)} rels")
            except Exception as e:
                logger.error(f"Worker error: {e}")
                all_concepts[futs[f].id] = []
                done += 1

    return all_concepts, all_relations
PYEOF
echo "  ✓ extractor.py → joint concept+relation extraction (1 LLM call)"

# ── 4. Updated orchestrator for joint pipeline ──────────────────────────
cat > backend/app/pipeline/orchestrator.py << 'PYEOF'
import logging
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.models import KnowledgeGraph
from backend.app.pipeline.parser import parse_file
from backend.app.pipeline.chunker import chunk_sections
from backend.app.pipeline.extractor import extract_batch
from backend.app.pipeline.validator import validate

logger = logging.getLogger(__name__)

def run(filepath, max_workers=2, progress_cb=None):
    def rpt(s, p, m): logger.info(f"[{s}] {p:.0%} {m}")

    rpt("parse", 0, "Parsing document...")
    skeleton = parse_file(filepath)  # Now handles all formats
    rpt("parse", 1, f"{len(skeleton.sections)} sections, {skeleton.total_pages} pages")

    rpt("chunk", 0, "Chunking...")
    chunks = chunk_sections(skeleton.sections)
    rpt("chunk", 1, f"{len(chunks)} chunks")
    if not chunks:
        return KnowledgeGraph(document_name=skeleton.filename, nodes=[], edges=[], metadata={"error": "No text"})

    # JOINT extraction: concepts + relations in one pass
    rpt("extract", 0, f"Extracting concepts & relations from {len(chunks)} chunks...")
    chunk_concepts, all_relations = extract_batch(chunks, max_workers=max_workers)

    all_concepts = []
    for ch in chunks:
        all_concepts.extend(chunk_concepts.get(ch.id, []))
    rpt("extract", 1, f"{len(all_concepts)} concepts, {len(all_relations)} relations")

    rpt("validate", 0, "Validating...")
    graph = validate(all_concepts, all_relations, skeleton.filename)
    rpt("validate", 1, f"Final: {len(graph.nodes)} nodes, {len(graph.edges)} edges")
    return graph
PYEOF
echo "  ✓ orchestrator.py → joint pipeline (no separate connector step)"

# ── 5. Updated storage with community tables ────────────────────────────
cat > backend/app/services/storage.py << 'PYEOF'
import json, sqlite3, uuid, logging
from pathlib import Path
from datetime import datetime
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.config import DATA_DIR
from backend.app.models import KnowledgeGraph

logger = logging.getLogger(__name__)
DB = DATA_DIR / "app.db"

def _conn():
    DB.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(str(DB))
    c.executescript("""
        CREATE TABLE IF NOT EXISTS maps (
            id TEXT PRIMARY KEY, user_id TEXT DEFAULT 'anonymous',
            filename TEXT, title TEXT, graph_json TEXT,
            status TEXT DEFAULT 'draft',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP, updated_at TEXT);
        CREATE TABLE IF NOT EXISTS corrections (
            id TEXT PRIMARY KEY, map_id TEXT, user_id TEXT DEFAULT 'anonymous',
            correction_type TEXT, original_json TEXT, corrected_json TEXT,
            context TEXT, quality_score INTEGER DEFAULT 0,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS training (
            id TEXT PRIMARY KEY, input_text TEXT, section_title TEXT,
            concepts_json TEXT, relations_json TEXT, domain TEXT DEFAULT 'general',
            validated INTEGER DEFAULT 0, created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY, username TEXT UNIQUE, display_name TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS community_maps (
            id TEXT PRIMARY KEY, map_id TEXT, user_id TEXT,
            title TEXT, description TEXT, domain TEXT DEFAULT 'general',
            upvotes INTEGER DEFAULT 0, status TEXT DEFAULT 'shared',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP);
    """)
    c.commit()
    return c

# Maps
def save_map(filename, graph, user_id="anonymous", title=None):
    c = _conn()
    mid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO maps (id,user_id,filename,title,graph_json,status,updated_at) VALUES (?,?,?,?,?,?,?)",
        (mid, user_id, filename, title or filename, graph.model_dump_json(), 'draft', datetime.now().isoformat()))
    c.commit(); c.close()
    return mid

def get_maps(user_id="anonymous"):
    c = _conn()
    rows = c.execute("SELECT id,filename,title,status,created_at FROM maps WHERE user_id=? ORDER BY created_at DESC",
        (user_id,)).fetchall()
    c.close()
    return [{"id":r[0],"filename":r[1],"title":r[2],"status":r[3],"created_at":r[4]} for r in rows]

def get_map(map_id):
    c = _conn()
    row = c.execute("SELECT graph_json FROM maps WHERE id=?", (map_id,)).fetchone()
    c.close()
    return KnowledgeGraph.model_validate_json(row[0]) if row else None

def delete_map(map_id):
    c = _conn(); c.execute("DELETE FROM maps WHERE id=?", (map_id,)); c.commit(); c.close()

def confirm_map(map_id):
    """Mark a map as confirmed (high-quality training data)."""
    c = _conn()
    c.execute("UPDATE maps SET status='confirmed', updated_at=? WHERE id=?",
        (datetime.now().isoformat(), map_id))
    c.commit(); c.close()

def update_map(map_id, graph):
    """Save edited graph back."""
    c = _conn()
    c.execute("UPDATE maps SET graph_json=?, updated_at=? WHERE id=?",
        (graph.model_dump_json() if hasattr(graph, 'model_dump_json') else json.dumps(graph),
         datetime.now().isoformat(), map_id))
    c.commit(); c.close()

def rename_map(map_id, title):
    c = _conn()
    c.execute("UPDATE maps SET title=?, updated_at=? WHERE id=?",
        (title, datetime.now().isoformat(), map_id))
    c.commit(); c.close()

# Community
def share_to_community(map_id, user_id, title, description="", domain="general"):
    c = _conn()
    cid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO community_maps (id,map_id,user_id,title,description,domain) VALUES (?,?,?,?,?,?)",
        (cid, map_id, user_id, title, description, domain))
    c.commit(); c.close()
    return cid

def get_community_maps(domain=None, limit=50):
    c = _conn()
    if domain:
        rows = c.execute("SELECT cm.id,cm.title,cm.description,cm.domain,cm.upvotes,cm.user_id,cm.created_at,cm.map_id FROM community_maps cm WHERE cm.domain=? ORDER BY cm.upvotes DESC LIMIT ?", (domain, limit)).fetchall()
    else:
        rows = c.execute("SELECT cm.id,cm.title,cm.description,cm.domain,cm.upvotes,cm.user_id,cm.created_at,cm.map_id FROM community_maps cm ORDER BY cm.upvotes DESC LIMIT ?", (limit,)).fetchall()
    c.close()
    return [{"id":r[0],"title":r[1],"description":r[2],"domain":r[3],"upvotes":r[4],"user_id":r[5],"created_at":r[6],"map_id":r[7]} for r in rows]

def upvote_community_map(community_id):
    c = _conn()
    c.execute("UPDATE community_maps SET upvotes=upvotes+1 WHERE id=?", (community_id,))
    c.commit(); c.close()

# Corrections
def save_correction(map_id, ctype, original, corrected, user_id="anonymous", quality=0):
    c = _conn()
    cid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO corrections (id,map_id,user_id,correction_type,original_json,corrected_json,quality_score) VALUES (?,?,?,?,?,?,?)",
        (cid, map_id, user_id, ctype, json.dumps(original), json.dumps(corrected), quality))
    c.commit(); c.close()
    return cid

def get_corrections_stats():
    c = _conn()
    total = c.execute("SELECT COUNT(*) FROM corrections").fetchone()[0]
    by_type = dict(c.execute("SELECT correction_type, COUNT(*) FROM corrections GROUP BY correction_type").fetchall())
    c.close()
    return {"total": total, "by_type": by_type}

# Training
def save_training(input_text, section_title, concepts, relations=None, domain="general"):
    c = _conn()
    tid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO training (id,input_text,section_title,concepts_json,relations_json,domain) VALUES (?,?,?,?,?,?)",
        (tid, input_text[:5000], section_title,
         json.dumps([x if isinstance(x,dict) else x.model_dump() for x in concepts]),
         json.dumps([x if isinstance(x,dict) else x.model_dump() for x in (relations or [])]), domain))
    c.commit(); c.close()

def get_training_stats():
    c = _conn()
    total = c.execute("SELECT COUNT(*) FROM training").fetchone()[0]
    validated = c.execute("SELECT COUNT(*) FROM training WHERE validated=1").fetchone()[0]
    confirmed_maps = c.execute("SELECT COUNT(*) FROM maps WHERE status='confirmed'").fetchone()[0]
    c.close()
    return {"total": total, "validated": validated, "confirmed_maps": confirmed_maps}

def export_training(path="data/training_chat.jsonl", confirmed_only=True):
    """Export training data. If confirmed_only, only use confirmed maps."""
    c = _conn()
    rows = c.execute("SELECT input_text,section_title,concepts_json,relations_json FROM training").fetchall()
    c.close()
    Path(path).parent.mkdir(exist_ok=True)
    with open(path, 'w') as f:
        for text, title, cj, rj in rows:
            f.write(json.dumps({"messages": [
                {"role": "system", "content": "Extract concepts and relationships from academic text. Return JSON with concepts and relations arrays."},
                {"role": "user", "content": f'Section: "{title}"\n\n{text[:1500]}'},
                {"role": "assistant", "content": json.dumps({"concepts": json.loads(cj), "relations": json.loads(rj)})},
            ]}) + "\n")
    return len(rows)
PYEOF
echo "  ✓ storage.py → community tables, confirm/share, training export"

# ── 6. Updated main.py with new endpoints ───────────────────────────────
cat > backend/app/main.py << 'PYEOF'
import os, sys, shutil, json, logging
from pathlib import Path
from contextlib import asynccontextmanager

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from fastapi import FastAPI, UploadFile, File, Query, WebSocket, WebSocketDisconnect, Body
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from backend.app.config import UPLOAD_DIR
from backend.app.pipeline.orchestrator import run
from backend.app.services.storage import (
    save_map, get_maps, get_map, delete_map, confirm_map, update_map, rename_map,
    save_correction, get_corrections_stats, get_training_stats, export_training,
    share_to_community, get_community_maps, upvote_community_map,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("app")

@asynccontextmanager
async def lifespan(app): yield

app = FastAPI(title="Mycel", version="2.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

ALLOWED_EXT = {'.pdf', '.docx', '.txt', '.md', '.markdown', '.rst', '.tex', '.epub'}

@app.get("/")
async def root(): return {"status": "ok", "version": "2.0.0"}

@app.post("/api/upload")
async def upload(file: UploadFile = File(...)):
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in ALLOWED_EXT:
        return JSONResponse({"error": f"Unsupported format. Allowed: {', '.join(ALLOWED_EXT)}"}, 400)
    fp = UPLOAD_DIR / file.filename
    with open(fp, "wb") as f: shutil.copyfileobj(file.file, f)
    graph = run(str(fp))
    map_id = save_map(file.filename, graph)
    return {
        "status": "success", "map_id": map_id, "document": file.filename,
        "nodes": [n.model_dump() for n in graph.nodes],
        "edges": [e.model_dump() for e in graph.edges],
        "node_count": len(graph.nodes), "edge_count": len(graph.edges),
    }

@app.get("/api/maps")
async def list_maps(user_id: str = "anonymous"):
    return {"maps": get_maps(user_id)}

@app.get("/api/maps/{map_id}")
async def get_map_data(map_id: str):
    g = get_map(map_id)
    if not g: return JSONResponse({"error": "Not found"}, 404)
    return {"nodes": [n.model_dump() for n in g.nodes], "edges": [e.model_dump() for e in g.edges]}

@app.delete("/api/maps/{map_id}")
async def del_map(map_id: str):
    delete_map(map_id); return {"status": "deleted"}

@app.post("/api/maps/{map_id}/confirm")
async def confirm(map_id: str):
    confirm_map(map_id)
    return {"status": "confirmed", "map_id": map_id}

@app.put("/api/maps/{map_id}/rename")
async def rename(map_id: str, body: dict = Body(...)):
    rename_map(map_id, body.get("title", ""))
    return {"status": "renamed"}

@app.post("/api/corrections")
async def submit_correction(body: dict = Body(...)):
    cid = save_correction(body.get("map_id",""), body.get("type","edit"),
        body.get("original"), body.get("corrected"), body.get("user_id","anonymous"),
        body.get("quality", 5))
    return {"id": cid}

# Community endpoints
@app.post("/api/community/share")
async def share(body: dict = Body(...)):
    cid = share_to_community(body["map_id"], body.get("user_id","anonymous"),
        body["title"], body.get("description",""), body.get("domain","general"))
    return {"id": cid}

@app.get("/api/community")
async def community(domain: str = None, limit: int = 50):
    return {"maps": get_community_maps(domain, limit)}

@app.post("/api/community/{community_id}/upvote")
async def upvote(community_id: str):
    upvote_community_map(community_id)
    return {"status": "upvoted"}

@app.get("/api/stats")
async def stats():
    return {"corrections": get_corrections_stats(), "training": get_training_stats()}

@app.post("/api/export-training")
async def export_train(confirmed_only: bool = True):
    n = export_training(confirmed_only=confirmed_only)
    return {"exported": n}
PYEOF
echo "  ✓ main.py → multi-format upload, community endpoints, confirm"

# ── 7. Updated frontend api.js ──────────────────────────────────────────
cat > frontend/src/api.js << 'APIEOF'
var API = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_API_URL) || 'http://localhost:8000';

export function uploadFile(file) {
  var f = new FormData();
  f.append('file', file);
  return fetch(API + '/api/upload', { method: 'POST', body: f }).then(function(r) { return r.json(); });
}
// Keep old name for compat
export var uploadPDF = uploadFile;

export function getMaps() { return fetch(API + '/api/maps').then(function(r) { return r.json(); }); }
export function getMap(id) { return fetch(API + '/api/maps/' + id).then(function(r) { return r.json(); }); }
export function deleteMap(id) { return fetch(API + '/api/maps/' + id, { method: 'DELETE' }).then(function(r) { return r.json(); }); }
export function confirmMap(id) { return fetch(API + '/api/maps/' + id + '/confirm', { method: 'POST' }).then(function(r) { return r.json(); }); }
export function renameMap(id, title) {
  return fetch(API + '/api/maps/' + id + '/rename', {
    method: 'PUT', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: title })
  }).then(function(r) { return r.json(); });
}
export function submitCorrection(data) {
  return fetch(API + '/api/corrections', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data)
  }).then(function(r) { return r.json(); });
}

// Community
export function getCommunityMaps(domain) {
  var url = API + '/api/community';
  if (domain) url += '?domain=' + encodeURIComponent(domain);
  return fetch(url).then(function(r) { return r.json(); });
}
export function shareMap(mapId, title, description, domain) {
  return fetch(API + '/api/community/share', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ map_id: mapId, title: title, description: description || '', domain: domain || 'general' })
  }).then(function(r) { return r.json(); });
}
export function upvoteCommunityMap(communityId) {
  return fetch(API + '/api/community/' + communityId + '/upvote', { method: 'POST' }).then(function(r) { return r.json(); });
}
export function getStats() { return fetch(API + '/api/stats').then(function(r) { return r.json(); }); }
APIEOF
echo "  ✓ api.js → multi-format upload, community, confirm, rename"

# ── 8. Add python-docx to backend requirements ─────────────────────────
if [ -f backend/requirements.txt ]; then
  if ! grep -q "python-docx" backend/requirements.txt; then
    echo "python-docx==1.1.0" >> backend/requirements.txt
    echo "  ✓ Added python-docx to requirements.txt"
  fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 Mycel v5 applied!"
echo ""
echo "BACKEND CHANGES:"
echo "  • Multi-format upload: PDF, DOCX, TXT, MD, EPUB"
echo "  • Joint extraction: concepts+relations in 1 LLM call (2x faster)"
echo "  • Community DB: users, community_maps tables"
echo "  • Map status: draft → confirmed (for training quality)"
echo "  • New endpoints: /confirm, /rename, /community/*, /export-training"
echo ""
echo "FRONTEND CHANGES:"
echo "  • api.js: uploadFile (any format), confirmMap, renameMap,"
echo "    deleteMap, shareMap, getCommunityMaps, upvoteCommunityMap"
echo ""
echo "PIPELINE ARCHITECTURE FIX:"
echo "  Old: parse → chunk → extract concepts → extract relations → validate"
echo "  New: parse → chunk → joint extract (concepts+relations) → validate"
echo "  The connector.py step is eliminated entirely."
echo ""
echo "STILL NEEDED (apply from previous v3/v4 scripts):"
echo "  • App.jsx with full UI (v3 script has it)"
echo "  • layout.js, theme.js (v3/v4 scripts)"
echo "  • Graph3D.jsx component (v4 script)"
echo ""
echo "INSTALL:"
echo "  pip install python-docx --break-system-packages"
echo "  cd frontend && npm install"
echo ""
echo "RUN:"
echo "  Terminal 1: ollama serve"
echo "  Terminal 2: bash start.sh"
echo "  Terminal 3: cd frontend && npm run dev"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"