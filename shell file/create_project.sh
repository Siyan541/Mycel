#!/bin/bash
# ============================================================================
# Complete Project Setup — REPLACES all previous patches
#
# Creates a clean, consolidated, deployment-ready project.
# Run: mkdir ~/Desktop/PROJECT_NAME && cd ~/Desktop/PROJECT_NAME && bash create_project.sh
#
# Placeholder: mycel and Mycel — find-replace with your chosen name
# ============================================================================
set -e

APP="mycel"  # Change this to your app name (lowercase, no spaces)
TITLE="Mycel" # Change this to your display name

echo "Building ${TITLE}..."

# ── Directory structure ─────────────────────────────────────────────────────
mkdir -p backend/app/pipeline backend/app/services backend/app/training
mkdir -p frontend/src/components frontend/src/utils frontend/public
mkdir -p data uploads

touch backend/__init__.py backend/app/__init__.py
touch backend/app/pipeline/__init__.py backend/app/services/__init__.py
touch backend/app/training/__init__.py

# ── Backend: requirements.txt ───────────────────────────────────────────────
cat > backend/requirements.txt << 'EOF'
fastapi==0.115.6
uvicorn[standard]==0.34.0
python-multipart==0.0.20
PyMuPDF==1.25.3
pydantic==2.10.4
rapidfuzz==3.11.0
python-dotenv==1.0.1
httpx==0.28.1
ollama==0.4.7
EOF

# ── Backend: .env ───────────────────────────────────────────────────────────
cat > backend/.env << 'EOF'
# For local dev: use ollama
LLM_PROVIDER=ollama
LLM_MODEL=llama3.1:8b

# For deployed version: use together.ai (uncomment + add key)
# LLM_PROVIDER=together
# TOGETHER_API_KEY=your_key_here
# TOGETHER_MODEL=Qwen/Qwen2.5-7B-Instruct-Turbo
EOF

# ── Backend: config.py ──────────────────────────────────────────────────────
cat > backend/app/config.py << 'PYEOF'
import os
from pathlib import Path
from dotenv import load_dotenv

load_dotenv(Path(__file__).parent.parent / ".env")

LLM_PROVIDER = os.getenv("LLM_PROVIDER", "ollama")
LLM_MODEL = os.getenv("LLM_MODEL", "llama3.1:8b")
TOGETHER_API_KEY = os.getenv("TOGETHER_API_KEY", "")
TOGETHER_MODEL = os.getenv("TOGETHER_MODEL", "Qwen/Qwen2.5-7B-Instruct-Turbo")
UPLOAD_DIR = Path(__file__).parent.parent.parent / "uploads"
DATA_DIR = Path(__file__).parent.parent.parent / "data"
UPLOAD_DIR.mkdir(exist_ok=True)
DATA_DIR.mkdir(exist_ok=True)
PYEOF

# ── Backend: models.py (all schemas in one file) ───────────────────────────
cat > backend/app/models.py << 'PYEOF'
from __future__ import annotations
from enum import Enum
from typing import Optional
from pydantic import BaseModel, Field

class RelationType(str, Enum):
    IMPLIES="IMPLIES"; REQUIRES="REQUIRES"; CONTRADICTS="CONTRADICTS"
    EQUIVALENT="EQUIVALENT"; GENERALIZES="GENERALIZES"; SPECIALIZES="SPECIALIZES"
    CAUSES="CAUSES"; ENABLES="ENABLES"; CONSTRAINS="CONSTRAINS"
    ANALOGOUS_TO="ANALOGOUS_TO"; PART_OF="PART_OF"; CONTAINS="CONTAINS"
    INSTANCE_OF="INSTANCE_OF"; DEFINED_BY="DEFINED_BY"
    PREREQUISITE_FOR="PREREQUISITE_FOR"; ILLUSTRATES="ILLUSTRATES"
    EXTENDS="EXTENDS"; CONTRASTS_WITH="CONTRASTS_WITH"

class ConceptType(str, Enum):
    THEORY="theory"; PRINCIPLE="principle"; DEFINITION="definition"
    METHOD="method"; EXAMPLE="example"; EVIDENCE="evidence"
    ARGUMENT="argument"; TERM="term"; FRAMEWORK="framework"; PHENOMENON="phenomenon"

class Section(BaseModel):
    id: str; title: str; level: int; page_start: int; page_end: int
    text: str; parent_id: Optional[str] = None; children_ids: list[str] = Field(default_factory=list)

class Skeleton(BaseModel):
    filename: str; total_pages: int; sections: list[Section]

class Concept(BaseModel):
    label: str = Field(description="2-6 word name")
    description: str = Field(description="One sentence explanation")
    concept_type: ConceptType
    abstraction_level: int = Field(ge=0, le=3)
    confidence: int = Field(ge=1, le=10)
    source_quote: str = Field(description="Brief phrase from source")

class ConceptResult(BaseModel):
    concepts: list[Concept]

class Relation(BaseModel):
    source_label: str; target_label: str; relation_type: RelationType
    justification: str; confidence: int = Field(ge=1, le=10)

class RelationResult(BaseModel):
    relations: list[Relation]

class GraphNode(BaseModel):
    id: str; label: str; description: str; concept_type: ConceptType
    abstraction_level: int; confidence: float
    cluster: str = ""; source_page: int = 0

class GraphEdge(BaseModel):
    id: str; source_id: str; target_id: str; relation_type: RelationType
    justification: str; confidence: float

class KnowledgeGraph(BaseModel):
    document_name: str; nodes: list[GraphNode]; edges: list[GraphEdge]
    metadata: dict = Field(default_factory=dict)
PYEOF

# ── Backend: LLM service (Ollama + Together.ai) ────────────────────────────
cat > backend/app/services/llm.py << 'PYEOF'
import os, json, logging, httpx

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.config import LLM_PROVIDER, LLM_MODEL, TOGETHER_API_KEY, TOGETHER_MODEL

logger = logging.getLogger(__name__)

def chat(messages, json_schema=None, temperature=0.1, max_tokens=1500):
    if LLM_PROVIDER == "together":
        return _together(messages, json_schema, temperature, max_tokens)
    return _ollama(messages, json_schema, temperature, max_tokens)

def _ollama(messages, schema, temp, max_tok):
    import ollama as ol
    kw = {"model": LLM_MODEL, "messages": messages,
          "options": {"temperature": temp, "num_ctx": 4096, "num_predict": max_tok}}
    if schema: kw["format"] = schema
    return ol.chat(**kw).message.content

def _together(messages, schema, temp, max_tok):
    body = {"model": TOGETHER_MODEL, "messages": messages,
            "temperature": temp, "max_tokens": max_tok}
    if schema:
        body["response_format"] = {"type": "json_schema",
            "json_schema": {"name": "extraction", "schema": schema}}
    with httpx.Client(timeout=120) as c:
        r = c.post("https://api.together.xyz/v1/chat/completions",
            headers={"Authorization": f"Bearer {TOGETHER_API_KEY}", "Content-Type": "application/json"},
            json=body)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
PYEOF

# ── Backend: Storage (SQLite — maps + corrections + training) ───────────────
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
    """)
    c.commit()
    return c

# Maps
def save_map(filename, graph, user_id="anonymous", title=None):
    c = _conn()
    mid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO maps (id,user_id,filename,title,graph_json,updated_at) VALUES (?,?,?,?,?,?)",
        (mid, user_id, filename, title or filename, graph.model_dump_json(), datetime.now().isoformat()))
    c.commit(); c.close()
    return mid

def get_maps(user_id="anonymous"):
    c = _conn()
    rows = c.execute("SELECT id,filename,title,created_at FROM maps WHERE user_id=? ORDER BY created_at DESC",
        (user_id,)).fetchall()
    c.close()
    return [{"id":r[0],"filename":r[1],"title":r[2],"created_at":r[3]} for r in rows]

def get_map(map_id):
    c = _conn()
    row = c.execute("SELECT graph_json FROM maps WHERE id=?", (map_id,)).fetchone()
    c.close()
    return KnowledgeGraph.model_validate_json(row[0]) if row else None

def delete_map(map_id):
    c = _conn(); c.execute("DELETE FROM maps WHERE id=?", (map_id,)); c.commit(); c.close()

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
    c.close()
    return {"total": total, "validated": validated}

def export_training(path="data/training_chat.jsonl", min_quality=0):
    c = _conn()
    rows = c.execute("SELECT input_text,section_title,concepts_json,relations_json FROM training").fetchall()
    c.close()
    Path(path).parent.mkdir(exist_ok=True)
    with open(path, 'w') as f:
        for text, title, cj, rj in rows:
            f.write(json.dumps({"messages": [
                {"role": "system", "content": "Extract concepts and relationships from academic text. Return JSON."},
                {"role": "user", "content": f'Section: "{title}"\n\n{text[:1500]}'},
                {"role": "assistant", "content": json.dumps({"concepts": json.loads(cj), "relations": json.loads(rj)})},
            ]}) + "\n")
    return len(rows)
PYEOF

# ── Backend: PDF Parser ────────────────────────────────────────────────────
cat > backend/app/pipeline/parser.py << 'PYEOF'
import re, uuid, pymupdf
from collections import Counter
import sys, os
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

def _is_toc(text):
    t = text.strip()
    return bool(re.match(r".*\.{4,}.*\d+\s*$", t) or re.match(r"^[ivxlcdm]+$", t.lower()) or re.match(r"^\d{1,3}$", t))

def parse_pdf(filepath):
    doc = pymupdf.open(filepath)
    total = len(doc)
    # Analyze fonts
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
            text = "\n".join(p for p in body_parts if not _is_toc(p)).strip()
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
            if not text or len(text) < 2 or _is_toc(text): continue

            hl = None
            if round(maxsz,1) in lmap and len(text) < 200: hl = lmap[round(maxsz,1)]
            rl = _heading_level(text)
            if rl is not None and len(text) < 150: hl = rl if hl is None else min(hl, rl)
            if hl is None and bold and len(text) < 80: hl = 1

            if hl is not None:
                flush()
                sid = str(uuid.uuid4())[:12]
                pid = None
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
PYEOF

# ── Backend: Chunker ───────────────────────────────────────────────────────
cat > backend/app/pipeline/chunker.py << 'PYEOF'
import re
from dataclasses import dataclass
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.models import Section

@dataclass
class Chunk:
    id: str; section_id: str; section_title: str; text: str
    token_count: int; chunk_index: int; total_chunks: int

def chunk_sections(sections, max_tokens=500):
    chunks = []
    for sec in sections:
        if not sec.text or len(sec.text) < 50: continue
        paras = [p.strip() for p in re.split(r"\n\s*\n", sec.text) if p.strip()]
        if not paras: paras = [sec.text]
        current, cur_tok = [], 0
        for para in paras:
            pt = len(para.split()) * 4 // 3
            if cur_tok + pt > max_tokens and current:
                text = "\n\n".join(current)
                chunks.append(Chunk(id=f"{sec.id}_c{len(chunks)}", section_id=sec.id,
                    section_title=sec.title, text=text, token_count=cur_tok,
                    chunk_index=len(chunks), total_chunks=0))
                current, cur_tok = [], 0
            current.append(para); cur_tok += pt
        if current:
            text = "\n\n".join(current)
            chunks.append(Chunk(id=f"{sec.id}_c{len(chunks)}", section_id=sec.id,
                section_title=sec.title, text=text, token_count=cur_tok,
                chunk_index=len(chunks), total_chunks=0))
    for c in chunks: c.total_chunks = len(chunks)
    return chunks
PYEOF

# ── Backend: Concept Extractor (learner-focused) ───────────────────────────
cat > backend/app/pipeline/extractor.py << 'PYEOF'
import re, logging
from concurrent.futures import ThreadPoolExecutor, as_completed
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.models import ConceptResult, Concept, ConceptType
from backend.app.services.llm import chat
from backend.app.services.storage import save_training

logger = logging.getLogger(__name__)

PROMPT = """You extract what a textbook chapter is TEACHING — not every noun.

Focus: What would a student LEARN that they didn't know before?

EXTRACT: New theories, key definitions, techniques, surprising insights
SKIP: Common knowledge, meta-content, setup instructions, generic terms

Rules: 2-5 concepts, 2-6 word labels, one-sentence descriptions.
concept_type: theory/principle/definition/method/example/evidence/argument/term/framework/phenomenon
abstraction_level: 0=core theory, 1=key concept, 2=detail, 3=example
confidence: 1-10 (how central to the chapter's purpose)"""

SKIP = {"compiler","text editor","programming","software","code","variable","function",
    "file","program","computer","download","install","setup","getting started","introduction",
    "exercise","example","solution","chapter","book","author","reader","forum","website"}

def _pattern_extract(text, title=""):
    """Fast deterministic extraction — no LLM."""
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

def _llm_extract(chunk_text, title, schema):
    msg = f"""What is this section TEACHING?
Section: "{title}"

TEXT:
---
{chunk_text[:2000]}
---

Extract 2-5 key concepts a student needs to learn."""
    try:
        raw = chat([{"role":"system","content":PROMPT}, {"role":"user","content":msg}],
            json_schema=schema, temperature=0.1)
        result = ConceptResult.model_validate_json(raw)
        valid = []
        for c in result.concepts:
            if len(c.label.split()) < 1 or len(c.label.split()) > 10: continue
            if len(c.description) < 12: continue
            if c.label.lower().strip() in SKIP: continue
            if any(s in c.label for s in "∑∫∂≤≥=(){}[]<>"): continue
            c.confidence = max(1, min(10, c.confidence))
            valid.append(c)
        return valid
    except Exception as e:
        logger.error(f"LLM extraction failed: {e}")
        return []

def extract_batch(chunks, max_workers=2):
    schema = ConceptResult.model_json_schema()
    results = {}
    done = 0
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        def do(chunk):
            det = _pattern_extract(chunk.text, chunk.section_title)
            if len(det) >= 3:
                save_training(chunk.text, chunk.section_title, det)
                return chunk.id, det
            llm = _llm_extract(chunk.text, chunk.section_title, schema)
            seen = {c.label.lower() for c in det}
            for c in llm:
                if c.label.lower() not in seen: det.append(c); seen.add(c.label.lower())
            save_training(chunk.text, chunk.section_title, det)
            return chunk.id, det

        futs = {ex.submit(do, c): c for c in chunks}
        for f in as_completed(futs):
            try:
                cid, concepts = f.result()
                results[cid] = concepts
                done += 1
                if concepts: logger.info(f"  [{done}/{len(chunks)}] [{', '.join(c.label for c in concepts[:4])}]")
            except Exception as e:
                logger.error(f"Worker error: {e}")
                results[futs[f].id] = []
                done += 1
    return results
PYEOF

# ── Backend: Relationship Connector ────────────────────────────────────────
cat > backend/app/pipeline/connector.py << 'PYEOF'
import logging
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.models import RelationResult, Relation, Concept, RelationType
from backend.app.services.llm import chat

logger = logging.getLogger(__name__)

PROMPT = """Extract relationships between academic concepts.
Types: IMPLIES, REQUIRES, CONTRADICTS, EQUIVALENT, GENERALIZES, SPECIALIZES,
CAUSES, ENABLES, CONSTRAINS, ANALOGOUS_TO, PART_OF, CONTAINS,
INSTANCE_OF, DEFINED_BY, PREREQUISITE_FOR, ILLUSTRATES, EXTENDS, CONTRASTS_WITH

Rules: source_label and target_label must EXACTLY match concept labels.
5-12 relations max. Brief justification for each. Confidence 1-10."""

HEURISTICS = {
    ("definition","example"): "ILLUSTRATES", ("theory","method"): "ENABLES",
    ("theory","definition"): "CONTAINS", ("definition","term"): "DEFINED_BY",
    ("framework","theory"): "CONTAINS", ("method","example"): "ILLUSTRATES",
    ("definition","definition"): "REQUIRES", ("theory","theory"): "REQUIRES",
}

def connect_concepts(concepts, source_text="", title="", use_llm=True):
    if len(concepts) < 2: return []
    concepts = sorted(concepts, key=lambda c: c.confidence, reverse=True)[:12]
    labels = {c.label.lower(): c.label for c in concepts}

    relations = []
    if use_llm:
        clist = "\n".join(f"- {c.label}: {c.description}" for c in concepts)
        msg = f'Section: "{title}"\n\nCONCEPTS:\n{clist}\n\nSOURCE:\n{source_text[:1200]}\n\nExtract 5-12 key relationships.'
        try:
            schema = RelationResult.model_json_schema()
            raw = chat([{"role":"system","content":PROMPT},{"role":"user","content":msg}],
                json_schema=schema, temperature=0.1)
            result = RelationResult.model_validate_json(raw)
            for r in result.relations:
                if r.source_label.lower() in labels and r.target_label.lower() in labels and r.source_label.lower() != r.target_label.lower():
                    r.source_label = labels[r.source_label.lower()]
                    r.target_label = labels[r.target_label.lower()]
                    r.confidence = max(1, min(10, r.confidence))
                    relations.append(r)
        except Exception as e:
            logger.error(f"LLM relation extraction failed: {e}")

    # Add heuristic relations for pairs not covered by LLM
    existing = {(r.source_label, r.target_label) for r in relations}
    types = {c.label: c.concept_type.value for c in concepts}
    for i, a in enumerate(concepts):
        for b in concepts[i+1:]:
            if (a.label, b.label) in existing: continue
            key = (types.get(a.label,""), types.get(b.label,""))
            if key in HEURISTICS:
                try:
                    relations.append(Relation(source_label=a.label, target_label=b.label,
                        relation_type=RelationType(HEURISTICS[key]),
                        justification=f"Inferred: {key[0]} typically {HEURISTICS[key]} {key[1]}",
                        confidence=5))
                except: pass
    return relations[:20]
PYEOF

# ── Backend: Validator ─────────────────────────────────────────────────────
cat > backend/app/pipeline/validator.py << 'PYEOF'
import uuid, logging
from rapidfuzz import fuzz
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.models import GraphNode, GraphEdge, KnowledgeGraph

logger = logging.getLogger(__name__)

def validate(concepts, relations, doc_name, min_conf=3):
    # Dedup concepts
    canonical, label_map = [], {}
    for c in concepts:
        merged = False
        for e in canonical:
            if fuzz.token_sort_ratio(c.label.lower(), e.label.lower()) >= 82:
                label_map[c.label] = e.label
                if c.confidence > e.confidence: e.description = c.description; e.confidence = c.confidence
                merged = True; break
        if not merged: canonical.append(c); label_map[c.label] = c.label

    # Remap + filter
    concepts = [c for c in canonical if c.confidence >= min_conf]
    clabels = {c.label for c in concepts}
    rels = []
    seen = set()
    for r in relations:
        src = label_map.get(r.source_label, r.source_label)
        tgt = label_map.get(r.target_label, r.target_label)
        if src == tgt or src not in clabels or tgt not in clabels: continue
        if r.confidence < min_conf: continue
        key = (src, tgt, r.relation_type)
        if key in seen: continue
        seen.add(key); r.source_label = src; r.target_label = tgt; rels.append(r)

    # Build graph
    lid = {}
    nodes = []
    for c in concepts:
        nid = str(uuid.uuid4())[:12]; lid[c.label] = nid
        nodes.append(GraphNode(id=nid, label=c.label, description=c.description,
            concept_type=c.concept_type, abstraction_level=c.abstraction_level,
            confidence=c.confidence/10.0))
    edges = []
    for r in rels:
        sid, tid = lid.get(r.source_label), lid.get(r.target_label)
        if sid and tid:
            edges.append(GraphEdge(id=str(uuid.uuid4())[:12], source_id=sid, target_id=tid,
                relation_type=r.relation_type, justification=r.justification, confidence=r.confidence/10.0))

    logger.info(f"Graph: {len(nodes)} nodes, {len(edges)} edges")
    return KnowledgeGraph(document_name=doc_name, nodes=nodes, edges=edges,
        metadata={"raw_concepts": len(concepts), "raw_relations": len(relations)})
PYEOF

# ── Backend: Orchestrator ──────────────────────────────────────────────────
cat > backend/app/pipeline/orchestrator.py << 'PYEOF'
import logging
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.models import KnowledgeGraph
from backend.app.pipeline.parser import parse_pdf
from backend.app.pipeline.chunker import chunk_sections
from backend.app.pipeline.extractor import extract_batch
from backend.app.pipeline.connector import connect_concepts
from backend.app.pipeline.validator import validate

logger = logging.getLogger(__name__)

def run(filepath, max_workers=2, progress_cb=None):
    def rpt(s, p, m): logger.info(f"[{s}] {p:.0%} {m}")

    rpt("parse", 0, "Parsing PDF...")
    skeleton = parse_pdf(filepath)
    rpt("parse", 1, f"{len(skeleton.sections)} sections, {skeleton.total_pages} pages")

    rpt("chunk", 0, "Chunking...")
    chunks = chunk_sections(skeleton.sections)
    rpt("chunk", 1, f"{len(chunks)} chunks")
    if not chunks:
        return KnowledgeGraph(document_name=skeleton.filename, nodes=[], edges=[], metadata={"error": "No text"})

    rpt("extract", 0, f"Extracting from {len(chunks)} chunks...")
    chunk_concepts = extract_batch(chunks, max_workers=max_workers)

    all_concepts = []
    sec_concepts = {}
    for ch in chunks:
        cc = chunk_concepts.get(ch.id, [])
        all_concepts.extend(cc)
        sid = ch.section_id
        if sid not in sec_concepts: sec_concepts[sid] = []
        sec_concepts[sid].extend(cc)
    rpt("extract", 1, f"{len(all_concepts)} concepts")

    rpt("connect", 0, "Finding relationships...")
    all_rels = []
    sec_map = {s.id: s for s in skeleton.sections}
    for sid, concepts in sec_concepts.items():
        if len(concepts) < 2: continue
        sec = sec_map.get(sid)
        rels = connect_concepts(concepts, sec.text[:1500] if sec else "", sec.title if sec else "")
        all_rels.extend(rels)
    rpt("connect", 1, f"{len(all_rels)} relations")

    rpt("validate", 0, "Validating...")
    graph = validate(all_concepts, all_rels, skeleton.filename)
    rpt("validate", 1, f"Final: {len(graph.nodes)} nodes, {len(graph.edges)} edges")
    return graph
PYEOF

# ── Backend: main.py (single clean entry point) ────────────────────────────
cat > backend/app/main.py << 'PYEOF'
import os, sys, shutil, json, logging, asyncio
from pathlib import Path
from contextlib import asynccontextmanager

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from fastapi import FastAPI, UploadFile, File, Query, WebSocket, WebSocketDisconnect, Body
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from backend.app.config import UPLOAD_DIR
from backend.app.pipeline.orchestrator import run
from backend.app.services.storage import (
    save_map, get_maps, get_map, delete_map,
    save_correction, get_corrections_stats, get_training_stats, export_training,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("app")
ws_clients = []

@asynccontextmanager
async def lifespan(app): yield

app = FastAPI(title="Knowledge Graph", version="1.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

@app.websocket("/ws/progress")
async def ws(websocket: WebSocket):
    await websocket.accept(); ws_clients.append(websocket)
    try:
        while True: await websocket.receive_text()
    except WebSocketDisconnect:
        if websocket in ws_clients: ws_clients.remove(websocket)

@app.get("/")
async def root(): return {"status": "ok", "version": "1.0.0"}

@app.post("/api/upload")
async def upload(file: UploadFile = File(...), force: bool = Query(False)):
    if not file.filename.lower().endswith(".pdf"):
        return JSONResponse({"error": "PDF only"}, 400)
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

@app.post("/api/corrections")
async def submit_correction(body: dict = Body(...)):
    cid = save_correction(body.get("map_id",""), body.get("type","edit"),
        body.get("original"), body.get("corrected"), body.get("user_id","anonymous"),
        body.get("quality", 5))
    return {"id": cid}

@app.get("/api/stats")
async def stats():
    return {"corrections": get_corrections_stats(), "training": get_training_stats()}

@app.post("/api/export-training")
async def export():
    n = export_training()
    return {"exported": n}
PYEOF

# ── Backend: Dockerfile ────────────────────────────────────────────────────
cat > Dockerfile << 'DOCKER'
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends gcc && rm -rf /var/lib/apt/lists/*
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt httpx
COPY backend/ backend/
RUN mkdir -p uploads data
ENV PORT=8000
CMD ["python", "-m", "uvicorn", "backend.app.main:app", "--host", "0.0.0.0", "--port", "8000"]
DOCKER

cat > railway.toml << 'TOML'
[build]
builder = "DOCKERFILE"
[deploy]
startCommand = "python -m uvicorn backend.app.main:app --host 0.0.0.0 --port $PORT"
healthcheckPath = "/"
TOML

# ── Frontend: package.json ─────────────────────────────────────────────────
cat > frontend/package.json << 'EOF'
{
  "name": "knowledge-graph-frontend",
  "private": true, "version": "1.0.0", "type": "module",
  "scripts": { "dev": "vite", "build": "vite build", "preview": "vite preview" },
  "dependencies": { "react": "^18.3.1", "react-dom": "^18.3.1" },
  "devDependencies": { "@vitejs/plugin-react": "^4.3.4", "vite": "^6.0.3" }
}
EOF

cat > frontend/vite.config.js << 'EOF'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, proxy: { '/api': 'http://localhost:8000', '/ws': { target: 'ws://localhost:8000', ws: true } } }
})
EOF

cat > frontend/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"/><meta name="viewport" content="width=device-width,initial-scale=1.0"/><title>Knowledge Graph</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap" rel="stylesheet"/></head>
<body><div id="root"></div><script type="module" src="/src/main.jsx"></script></body>
</html>
EOF

cat > frontend/src/main.jsx << 'EOF'
import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import './App.css'
ReactDOM.createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>)
EOF

# ── Frontend: CSS ──────────────────────────────────────────────────────────
cat > frontend/src/App.css << 'EOF'
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap');
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: 'Inter', sans-serif; background: #0B1120; color: #E8ECF4; -webkit-font-smoothing: antialiased; }
#root { height: 100vh; display: flex; flex-direction: column; overflow: hidden; }
::selection { background: #6C5CE7; color: white; }
EOF

# ── Frontend: api.js ──────────────────────────────────────────────────────
cat > frontend/src/api.js << 'EOF'
const API = import.meta.env.VITE_API_URL || 'http://localhost:8000';
export const uploadPDF = async (file) => {
  const f = new FormData(); f.append('file', file);
  return (await fetch(`${API}/api/upload`, { method: 'POST', body: f })).json();
};
export const getMaps = async () => (await fetch(`${API}/api/maps`)).json();
export const getMap = async (id) => (await fetch(`${API}/api/maps/${id}`)).json();
export const deleteMap = async (id) => (await fetch(`${API}/api/maps/${id}`, { method: 'DELETE' })).json();
export const submitCorrection = async (data) =>
  (await fetch(`${API}/api/corrections`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) })).json();
EOF

# ── Frontend: theme ────────────────────────────────────────────────────────
cat > frontend/src/utils/theme.js << 'EOF'
export const PALETTES = {
  aurora: { name:"Aurora", bg:"#0B1120", surface:"#131B2E", border:"#1E2A45",
    nodes: { 0:{bg:"#6C5CE7",text:"#F0EDFF",label:"Core Theory"},1:{bg:"#00B8A9",text:"#E0FFF9",label:"Key Concept"},2:{bg:"#FDCB6E",text:"#3D3100",label:"Detail"},3:{bg:"#E17055",text:"#FFF0EC",label:"Example"} },
    edges: { logical:"#A29BFE",compositional:"#74B9FF",pedagogical:"#FD79A8",custom:"#55EFC4" } },
  ocean: { name:"Ocean", bg:"#0A1628", surface:"#112240", border:"#1D3461",
    nodes: { 0:{bg:"#2D3561",text:"#C8D1E8",label:"Core Theory"},1:{bg:"#1E6F89",text:"#D4F1F9",label:"Key Concept"},2:{bg:"#408E91",text:"#E8FFFE",label:"Detail"},3:{bg:"#8CB9BD",text:"#1A3A3C",label:"Example"} },
    edges: { logical:"#5B8FBE",compositional:"#7EC8CC",pedagogical:"#B8D8D8",custom:"#63CDDA" } },
  ember: { name:"Ember", bg:"#1A0A0A", surface:"#2D1515", border:"#4A2020",
    nodes: { 0:{bg:"#C0392B",text:"#FDE8E5",label:"Core Theory"},1:{bg:"#E67E22",text:"#FFF3E0",label:"Key Concept"},2:{bg:"#F1C40F",text:"#3D3100",label:"Detail"},3:{bg:"#F39C12",text:"#FFF8E1",label:"Example"} },
    edges: { logical:"#E74C3C",compositional:"#F39C12",pedagogical:"#FDD835",custom:"#FF7675" } },
  forest: { name:"Forest", bg:"#0A1A12", surface:"#132D1F", border:"#1E4D32",
    nodes: { 0:{bg:"#2D6A4F",text:"#D8F3DC",label:"Core Theory"},1:{bg:"#40916C",text:"#E8F8EE",label:"Key Concept"},2:{bg:"#74C69D",text:"#1B4332",label:"Detail"},3:{bg:"#B7E4C7",text:"#1B4332",label:"Example"} },
    edges: { logical:"#52B788",compositional:"#95D5B2",pedagogical:"#D8F3DC",custom:"#81ECEC" } },
};
export const EDGE_CATS = {
  logical:{types:["IMPLIES","REQUIRES","CONTRADICTS","EQUIVALENT","GENERALIZES","SPECIALIZES","CAUSES","ENABLES","CONSTRAINS","ANALOGOUS_TO"],dash:""},
  compositional:{types:["PART_OF","CONTAINS","INSTANCE_OF","DEFINED_BY"],dash:"8 4"},
  pedagogical:{types:["PREREQUISITE_FOR","ILLUSTRATES","EXTENDS","CONTRASTS_WITH"],dash:"4 3"},
};
export function edgeCat(type) {
  for (const [c,i] of Object.entries(EDGE_CATS)) if (i.types.includes(type)) return c;
  return "custom";
}
EOF

# ── Frontend: vercel.json ──────────────────────────────────────────────────
cat > frontend/vercel.json << 'EOF'
{ "buildCommand": "npm run build", "outputDirectory": "dist", "framework": "vite" }
EOF

# ── Convenience scripts ────────────────────────────────────────────────────
cat > start.sh << 'EOF'
#!/bin/bash
echo "Starting backend on http://localhost:8000 ..."
cd "$(dirname "$0")"
python -m uvicorn backend.app.main:app --reload --port 8000 --host 0.0.0.0
EOF
chmod +x start.sh

cat > README.md << 'EOF'
# Knowledge Graph Engine

Upload a textbook chapter → see concepts and how they connect → edit to train the AI.

## Quick Start (Local)

```bash
pip install -r backend/requirements.txt
ollama serve &
ollama pull llama3.1:8b
bash start.sh          # Terminal 1: backend
cd frontend && npm install && npm run dev  # Terminal 2: frontend
```

Open http://localhost:5173

## Deploy to Web

See LAUNCH_GUIDE.md for Railway + Vercel deployment.
EOF

echo ""
echo "✅ Clean project created!"
echo ""
echo "Files: $(find . -type f | wc -l)"
echo ""
echo "To run locally:"
echo "  pip install -r backend/requirements.txt"
echo "  bash start.sh          # Terminal 1"
echo "  cd frontend && npm install && npm run dev  # Terminal 2"
echo ""
echo "To deploy:"
echo "  1. Push to GitHub"
echo "  2. Deploy backend on Railway"
echo "  3. Deploy frontend on Vercel"
echo ""
echo "⚠️  Replace mycel and Mycel with your chosen name!"
echo ""