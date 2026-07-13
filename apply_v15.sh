#!/bin/bash
set -e
echo "🍄 Mycel v15 — Stage 0 (quality) + Stage 1 (explainable PDF splitter)"
echo "   models fix · 0–1 confidence · schema-constrained extraction · chunk overlap"
echo "   · embedding-scored provenance (fastembed) · relation-evidence fix"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── locate app + media.py ───────────────────────────────────────
if [ ! -f backend/app/main.py ]; then
  echo "  ✗ Run from repo root (backend/app/main.py not found)."; exit 1
fi
APP="backend/app"
MEDIA="$APP/services/media.py"
for sub in services routes; do
  [ -f "$APP/$sub/media.py" ] && MEDIA="$APP/$sub/media.py"
done
mkdir -p "$(dirname "$MEDIA")"
echo "  → media.py target: $MEDIA"

# ── backups ─────────────────────────────────────────────────────
BK=".v14bak"
for f in "$APP/models.py" "$APP/pipeline/extractor.py" "$APP/pipeline/chunker.py" \
         "$APP/pipeline/validator.py" "$MEDIA"; do
  [ -f "$f" ] && cp "$f" "$f$BK" && echo "  ✓ backed up $f"
done
restore() {
  echo "  ✗ compile failed — restoring backups"
  for f in "$APP/models.py" "$APP/pipeline/extractor.py" "$APP/pipeline/chunker.py" \
           "$APP/pipeline/validator.py" "$MEDIA"; do
    [ -f "$f$BK" ] && mv "$f$BK" "$f"
  done
  exit 1
}

# ════════════════════════════════════════════════════════════════
# models.py — repaired + 0–1 confidence + provenance fields
# ════════════════════════════════════════════════════════════════
cat > "$APP/models.py" << 'PYEOF'
from pydantic import BaseModel, Field
from enum import Enum
from typing import Optional

class ConceptType(str, Enum):
    theory="theory"; principle="principle"; definition="definition"
    method="method"; example="example"; evidence="evidence"
    argument="argument"; term="term"; framework="framework"
    phenomenon="phenomenon"

class RelationType(str, Enum):
    IMPLIES="IMPLIES"; REQUIRES="REQUIRES"; DEFINED_BY="DEFINED_BY"
    CONTAINS="CONTAINS"; PART_OF="PART_OF"; CAUSES="CAUSES"
    ENABLES="ENABLES"; GENERALIZES="GENERALIZES"; SPECIALIZES="SPECIALIZES"
    ILLUSTRATES="ILLUSTRATES"; EXTENDS="EXTENDS"; CONSTRAINS="CONSTRAINS"
    CONTRADICTS="CONTRADICTS"; PREREQUISITE_FOR="PREREQUISITE_FOR"
    CONTRASTS_WITH="CONTRASTS_WITH"; INSTANCE_OF="INSTANCE_OF"
    EQUIVALENT="EQUIVALENT"; ANALOGOUS_TO="ANALOGOUS_TO"

class Section(BaseModel):
    id: str; title: str; level: int; page_start: int; page_end: int
    text: str = ""; parent_id: Optional[str] = None

class Skeleton(BaseModel):
    filename: str; total_pages: int; sections: list[Section]

class Chunk(BaseModel):
    id: str; section_id: str; section_title: str; text: str

# confidence is now a 0–1 float everywhere (was 1–10 int).
class Concept(BaseModel):
    label: str; description: str; concept_type: ConceptType
    abstraction_level: int = Field(ge=0, le=3, default=1)
    confidence: float = Field(ge=0.0, le=1.0, default=0.7)
    source_quote: str = ""
    in_text: bool = True                 # False = prerequisite / not defined here

class ConceptResult(BaseModel):
    concepts: list[Concept]

# repaired: single confidence field, no stray required source/target,
# relation_type back to the enum (matches GraphEdge).
class Relation(BaseModel):
    source_label: str
    target_label: str
    relation_type: RelationType = RelationType.REQUIRES
    justification: str = ""
    confidence: float = Field(ge=0.0, le=1.0, default=0.6)
    evidence: str = ""

class RelationResult(BaseModel):
    relations: list[Relation]

class GraphNode(BaseModel):
    id: str; label: str; description: str
    concept_type: str = "term"
    abstraction_level: int = 1
    cluster: str = ""
    confidence: float = 0.7              # 0–1, UI confidence filter
    source_page: int = 0                 # media.attach_provenance
    source_quote: str = ""               # verbatim definition sentence
    source_score: float = 0.0            # provenance match strength 0–1 (explainability)
    in_text: bool = True                 # False = prerequisite/inferred
    mentions: list = Field(default_factory=list)   # all ranked source sentences

class GraphEdge(BaseModel):
    id: str; source_id: str; target_id: str
    relation_type: RelationType
    justification: str = ""
    confidence: float                    # 0–1
    page: int = 0                        # media.attach_relation_provenance
    evidence: str = ""                   # verbatim relationship sentence

class KnowledgeGraph(BaseModel):
    document_name: str; nodes: list[GraphNode]; edges: list[GraphEdge]
    metadata: dict = Field(default_factory=dict)

# ── User & Credit models ──
class UserLevel(str, Enum):
    none="none"; beginner="beginner"; experienced="experienced"
    expert="expert"; professional="professional"; organizer="organizer"

LEVEL_THRESHOLDS = {"none":0,"beginner":1,"experienced":75,
                    "expert":300,"professional":1000,"organizer":5000}

def get_level(points):
    level="none"
    for name, threshold in LEVEL_THRESHOLDS.items():
        if points >= threshold: level = name
    return level
PYEOF
echo "  ✓ wrote $APP/models.py"

# ════════════════════════════════════════════════════════════════
# extractor.py — schema-constrained, 0–1 confidence, few-shot
# ════════════════════════════════════════════════════════════════
cat > "$APP/pipeline/extractor.py" << 'PYEOF'
"""Joint concept + relation extraction (v15).
Constrained JSON (0–1 confidence), few-shot granularity anchor, fuzzy relation
endpoints, in_text flag, verbatim-quote nudge. media.py repairs quotes/pages and
does the authoritative provenance afterward."""
import re, json, logging
from concurrent.futures import ThreadPoolExecutor, as_completed
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from rapidfuzz import process, fuzz
from backend.app.models import (Concept, ConceptType, Relation, RelationType)
from backend.app.services.llm import chat
from backend.app.services.storage import save_training

logger = logging.getLogger(__name__)

_CTYPES = [t.value for t in ConceptType]
_RTYPES = [t.value for t in RelationType]

JOINT_SCHEMA = {
    "type": "object",
    "properties": {
        "concepts": {"type": "array", "items": {"type": "object", "properties": {
            "label": {"type": "string"},
            "description": {"type": "string"},
            "concept_type": {"type": "string", "enum": _CTYPES},
            "abstraction_level": {"type": "integer", "minimum": 0, "maximum": 3},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1},
            "in_text": {"type": "boolean"},
            "source_quote": {"type": "string"}},
            "required": ["label", "description", "concept_type",
                         "abstraction_level", "confidence"]}},
        "relations": {"type": "array", "items": {"type": "object", "properties": {
            "source_label": {"type": "string"},
            "target_label": {"type": "string"},
            "relation_type": {"type": "string", "enum": _RTYPES},
            "justification": {"type": "string"},
            "evidence": {"type": "string"},
            "confidence": {"type": "number", "minimum": 0, "maximum": 1}},
            "required": ["source_label", "target_label",
                         "relation_type", "confidence"]}},
    },
    "required": ["concepts", "relations"],
}

JOINT_PROMPT = """You are an expert at analyzing educational text. Extract the concepts a student would LEARN and the relationships between them. Do not extract every noun — only learnable ideas.

Rules:
- Return ONLY JSON matching the schema ("concepts" and "relations" arrays).
- Set confidence honestly as a number from 0 to 1. Drop anything you are less than 0.45 sure of.
- Return 1.5–3x more typed relations than concepts where the text supports it. Prefer: CAUSES, ENABLES, REQUIRES, PART_OF, CONTRASTS_WITH, ILLUSTRATES, DEFINED_BY.
- Each relation SHOULD include a short verbatim `evidence` sentence copied from the text.
- Do NOT invent definitions. If a concept is a prerequisite that is NOT defined in this text, set "in_text": false and leave "source_quote" empty.
- `source_quote`: copy 4–12 words EXACTLY from the text (a real substring, not a paraphrase).

concept_type: theory, principle, definition, method, example, evidence, argument, term, framework, phenomenon
relation_type: IMPLIES, REQUIRES, DEFINED_BY, CONTAINS, PART_OF, CAUSES, ENABLES, GENERALIZES, SPECIALIZES, ILLUSTRATES, EXTENDS, CONSTRAINS, CONTRADICTS, PREREQUISITE_FOR, CONTRASTS_WITH, INSTANCE_OF, EQUIVALENT, ANALOGOUS_TO
abstraction_level: 0 core theory, 1 key concept, 2 supporting detail, 3 example.

WORKED EXAMPLE
Text: "A vector space is a set of vectors closed under addition and scalar multiplication. A basis is a linearly independent set that spans the space; every vector is a unique linear combination of basis vectors."
Output:
{"concepts": [
  {"label": "Vector space", "description": "A set of vectors closed under addition and scalar multiplication.", "concept_type": "definition", "abstraction_level": 0, "confidence": 0.95, "in_text": true, "source_quote": "A vector space is a set of vectors"},
  {"label": "Basis", "description": "A linearly independent set that spans a vector space.", "concept_type": "definition", "abstraction_level": 1, "confidence": 0.9, "in_text": true, "source_quote": "A basis is a linearly independent set"},
  {"label": "Linear combination", "description": "A sum of scalar multiples of vectors.", "concept_type": "term", "abstraction_level": 2, "confidence": 0.75, "in_text": true, "source_quote": "unique linear combination of basis vectors"}
], "relations": [
  {"source_label": "Basis", "target_label": "Vector space", "relation_type": "PART_OF", "justification": "A basis belongs to a vector space.", "evidence": "A basis is a linearly independent set that spans the space", "confidence": 0.85},
  {"source_label": "Linear combination", "target_label": "Basis", "relation_type": "REQUIRES", "justification": "Formed from basis vectors.", "evidence": "every vector is a unique linear combination of basis vectors", "confidence": 0.75}
]}"""

SKIP = {"compiler","text editor","programming","software","code","variable","function",
    "file","program","computer","download","install","setup","getting started","introduction",
    "exercise","example","solution","chapter","book","author","reader","forum","website"}

def _conf(v, default=0.7):
    try:
        x = float(v)
    except Exception:
        return default
    if x > 1.0:            # model ignored the 0–1 instruction; assume 1–10 scale
        x = x / 10.0
    return min(1.0, max(0.0, x))

def _clean_json(raw):
    s = raw.strip()
    s = re.sub(r'^```(?:json)?\s*', '', s)
    s = re.sub(r'\s*```\s*$', '', s).strip()
    start = s.find('{')
    if start < 0: return None
    depth = 0; end = -1
    for i in range(start, len(s)):
        if s[i] == '{': depth += 1
        elif s[i] == '}': depth -= 1
        if depth == 0: end = i + 1; break
    if end < 0: s = s + '}' * depth; end = len(s)
    s = s[start:end]
    s = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', ' ', s)
    s = re.sub(r',\s*([}\]])', r'\1', s)
    s = re.sub(r"(?<=[{,:\[\s])'([^']*)'(?=[,}\]:\s])", r'"\1"', s)
    s = re.sub(r'(?<=[{,])\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*:', r' "\1":', s)
    last = s.rfind('}')
    if last >= 0: s = s[:last + 1]
    return s

def _parse_json_safe(raw):
    try: return json.loads(raw)
    except Exception: pass
    cleaned = _clean_json(raw)
    if cleaned:
        try: return json.loads(cleaned)
        except Exception: pass
    try:
        lines = [l.strip() for l in raw.split('\n')
                 if l.strip() and not l.strip().startswith(('//', '#'))]
        c2 = _clean_json(' '.join(lines))
        if c2: return json.loads(c2)
    except Exception: pass
    return None

def _pattern_extract(text, title=""):
    concepts = []; seen = set()
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
                    confidence=0.7, source_quote=m.group(0)[:60]))
            except Exception: pass
    return concepts

def _regex_extract(raw, title):
    concepts = []; relations = []
    labels = re.findall(r'"label"\s*:\s*"([^"]{3,50})"', raw)
    descs = re.findall(r'"description"\s*:\s*"([^"]{10,300})"', raw)
    types = re.findall(r'"concept_type"\s*:\s*"([^"]+)"', raw)
    valid = set(_CTYPES)
    for i, label in enumerate(labels):
        if label.lower() in SKIP: continue
        desc = descs[i] if i < len(descs) else f"Concept in {title}"
        ctype = types[i] if i < len(types) and types[i] in valid else "term"
        try:
            concepts.append(Concept(label=label.strip(), description=desc[:200],
                concept_type=ConceptType(ctype), abstraction_level=1,
                confidence=0.55, source_quote=""))
        except Exception: pass
    lset = {c.label.lower() for c in concepts}
    for m in re.finditer(
        r'"source_label"\s*:\s*"([^"]+)".*?"target_label"\s*:\s*"([^"]+)".*?"relation_type"\s*:\s*"([^"]+)"',
        raw, re.DOTALL):
        src, tgt, rt = m.group(1).strip(), m.group(2).strip(), m.group(3).strip()
        if src.lower() not in lset or tgt.lower() not in lset or rt not in set(_RTYPES): continue
        try:
            relations.append(Relation(source_label=src, target_label=tgt,
                relation_type=RelationType(rt), justification="", confidence=0.5))
        except Exception: pass
    return concepts, relations

def _resolve(name, labels, keys):
    k = name.lower().strip()
    if k in labels: return labels[k]
    if keys:
        m = process.extractOne(k, keys, scorer=fuzz.token_sort_ratio)
        if m and m[1] >= 85: return labels[m[0]]
    return None

def _joint_extract(chunk_text, title):
    msg = f"""Analyze this educational text. Extract the key concepts AND their relationships.
Section: "{title}"

TEXT:
---
{chunk_text[:3500]}
---

Return ONLY JSON with "concepts" and "relations" arrays."""
    try:
        raw = chat([{"role": "system", "content": JOINT_PROMPT},
                    {"role": "user", "content": msg}],
                   json_schema=JOINT_SCHEMA, temperature=0.1, max_tokens=2000)
        data = _parse_json_safe(raw)
        if data is None:
            logger.warning(f"JSON parse failed, regex fallback: {title}")
            return _regex_extract(raw, title)

        concepts = []
        for c in data.get("concepts", []):
            try:
                label = str(c.get("label", "")).strip()
                if not (1 <= len(label.split()) <= 10): continue
                if len(str(c.get("description", ""))) < 10: continue
                if label.lower() in SKIP: continue
                try: ctype = ConceptType(str(c.get("concept_type", "term")))
                except Exception: ctype = ConceptType("term")
                concepts.append(Concept(
                    label=label,
                    description=str(c.get("description", ""))[:200],
                    concept_type=ctype,
                    abstraction_level=min(3, max(0, int(c.get("abstraction_level", 1)))),
                    confidence=_conf(c.get("confidence", 0.7)),
                    source_quote=str(c.get("source_quote", ""))[:80],
                    in_text=bool(c.get("in_text", True))))
            except Exception as e:
                logger.debug(f"skip concept: {e}")

        relations = []
        labels = {c.label.lower(): c.label for c in concepts}
        keys = list(labels.keys())
        for r in data.get("relations", []):
            try:
                src = _resolve(str(r.get("source_label", "")), labels, keys)
                tgt = _resolve(str(r.get("target_label", "")), labels, keys)
                if not src or not tgt or src == tgt: continue
                try: rtype = RelationType(str(r.get("relation_type", "REQUIRES")))
                except Exception: rtype = RelationType("REQUIRES")
                relations.append(Relation(
                    source_label=src, target_label=tgt, relation_type=rtype,
                    justification=str(r.get("justification", ""))[:200],
                    evidence=str(r.get("evidence", ""))[:240],
                    confidence=_conf(r.get("confidence", 0.6), 0.6)))
            except Exception as e:
                logger.debug(f"skip relation: {e}")

        return concepts, relations
    except Exception as e:
        logger.error(f"Joint extraction failed: {e}")
        return [], []

def extract_batch(chunks, max_workers=2):
    all_concepts = {}; all_relations = []; done = 0
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        def do(chunk):
            det = _pattern_extract(chunk.text, chunk.section_title)
            llm_c, llm_r = _joint_extract(chunk.text, chunk.section_title)
            seen = {c.label.lower() for c in det}
            for c in llm_c:
                if c.label.lower() not in seen:
                    det.append(c); seen.add(c.label.lower())
            try: save_training(chunk.text, chunk.section_title, det, llm_r)
            except Exception: pass
            return chunk.id, det, llm_r
        futs = {ex.submit(do, c): c for c in chunks}
        for f in as_completed(futs):
            try:
                cid, concepts, relations = f.result()
                all_concepts[cid] = concepts; all_relations.extend(relations); done += 1
                if concepts:
                    lab = ', '.join(c.label for c in concepts[:4])
                    logger.info(f"  [{done}/{len(chunks)}] [{lab}] + {len(relations)} rels")
                else:
                    logger.info(f"  [{done}/{len(chunks)}] (no concepts)")
            except Exception as e:
                logger.error(f"Worker error: {e}")
                all_concepts[futs[f].id] = []; done += 1
    return all_concepts, all_relations
PYEOF
echo "  ✓ wrote $APP/pipeline/extractor.py"

# ════════════════════════════════════════════════════════════════
# chunker.py — one-paragraph overlap
# ════════════════════════════════════════════════════════════════
cat > "$APP/pipeline/chunker.py" << 'PYEOF'
"""Section chunker (v15) — one-paragraph overlap between adjacent chunks so
boundary concepts survive. Overlap duplicates are removed by validator dedup."""
import re
from dataclasses import dataclass
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.models import Section

@dataclass
class Chunk:
    id: str; section_id: str; section_title: str; text: str
    token_count: int; chunk_index: int; total_chunks: int

def _tok(p): return len(p.split()) * 4 // 3

def chunk_sections(sections, max_tokens=500):
    chunks = []
    for sec in sections:
        if not sec.text or len(sec.text) < 50: continue
        paras = [p.strip() for p in re.split(r"\n\s*\n", sec.text) if p.strip()]
        if not paras: paras = [sec.text]
        current, cur_tok = [], 0
        for para in paras:
            pt = _tok(para)
            if cur_tok + pt > max_tokens and current:
                chunks.append(Chunk(id=f"{sec.id}_c{len(chunks)}", section_id=sec.id,
                    section_title=sec.title, text="\n\n".join(current), token_count=cur_tok,
                    chunk_index=len(chunks), total_chunks=0))
                if len(current) > 1:
                    keep = current[-1]; current, cur_tok = [keep], _tok(keep)
                else:
                    current, cur_tok = [], 0
            current.append(para); cur_tok += pt
        if current:
            chunks.append(Chunk(id=f"{sec.id}_c{len(chunks)}", section_id=sec.id,
                section_title=sec.title, text="\n\n".join(current), token_count=cur_tok,
                chunk_index=len(chunks), total_chunks=0))
    for c in chunks: c.total_chunks = len(chunks)
    return chunks
PYEOF
echo "  ✓ wrote $APP/pipeline/chunker.py"

# ════════════════════════════════════════════════════════════════
# validator.py — no /10 rescale, 0.45 threshold, carry provenance
# ════════════════════════════════════════════════════════════════
cat > "$APP/pipeline/validator.py" << 'PYEOF'
"""Validator (v15) — confidence is already 0–1 (no /10 rescale). Dedup at 82%
fuzzy, filter at 0.45, carry in_text/source_quote to nodes and evidence to edges."""
import uuid, logging
from rapidfuzz import fuzz
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', '..'))
from backend.app.models import GraphNode, GraphEdge, KnowledgeGraph

logger = logging.getLogger(__name__)

def _ctype(c):
    ct = getattr(c, "concept_type", "term")
    return getattr(ct, "value", str(ct))

def validate(concepts, relations, doc_name, min_conf=0.45):
    canonical, label_map = [], {}
    for c in concepts:
        merged = False
        for e in canonical:
            if fuzz.token_sort_ratio(c.label.lower(), e.label.lower()) >= 82:
                label_map[c.label] = e.label
                if c.confidence > e.confidence:
                    e.description = c.description; e.confidence = c.confidence
                    if getattr(c, "source_quote", ""): e.source_quote = c.source_quote
                merged = True; break
        if not merged:
            canonical.append(c); label_map[c.label] = c.label

    concepts = [c for c in canonical if c.confidence >= min_conf]
    clabels = {c.label for c in concepts}
    rels = []; seen = set()
    for r in relations:
        src = label_map.get(r.source_label, r.source_label)
        tgt = label_map.get(r.target_label, r.target_label)
        if src == tgt or src not in clabels or tgt not in clabels: continue
        if r.confidence < min_conf: continue
        key = (src, tgt, r.relation_type)
        if key in seen: continue
        seen.add(key); r.source_label = src; r.target_label = tgt; rels.append(r)

    lid = {}; nodes = []
    for c in concepts:
        nid = str(uuid.uuid4())[:12]; lid[c.label] = nid
        nodes.append(GraphNode(id=nid, label=c.label, description=c.description,
            concept_type=_ctype(c), abstraction_level=c.abstraction_level,
            confidence=c.confidence,
            source_quote=getattr(c, "source_quote", ""),
            in_text=getattr(c, "in_text", True)))
    edges = []
    for r in rels:
        sid, tid = lid.get(r.source_label), lid.get(r.target_label)
        if sid and tid:
            edges.append(GraphEdge(id=str(uuid.uuid4())[:12], source_id=sid, target_id=tid,
                relation_type=r.relation_type, justification=r.justification,
                confidence=r.confidence, evidence=getattr(r, "evidence", "")))

    logger.info(f"Graph: {len(nodes)} nodes, {len(edges)} edges")
    return KnowledgeGraph(document_name=doc_name, nodes=nodes, edges=edges,
        metadata={"raw_concepts": len(concepts), "raw_relations": len(relations)})
PYEOF
echo "  ✓ wrote $APP/pipeline/validator.py"

# ════════════════════════════════════════════════════════════════
# media.py — embedding-scored explainable provenance
# ════════════════════════════════════════════════════════════════
cat > "$MEDIA" << 'PYEOF'
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
PYEOF
echo "  ✓ wrote $MEDIA"

# ── requirements ────────────────────────────────────────────────
REQ="requirements.txt"; [ -f "$REQ" ] || REQ="backend/requirements.txt"
if [ -f "$REQ" ]; then
  grep -qi '^fastembed' "$REQ" || echo "fastembed"  >> "$REQ"
  grep -qi '^numpy'     "$REQ" || echo "numpy"       >> "$REQ"
  grep -qi '^PyMuPDF'   "$REQ" || echo "PyMuPDF"     >> "$REQ"
  grep -qi '^pdfplumber' "$REQ" || echo "pdfplumber" >> "$REQ"
  echo "  ✓ ensured fastembed, numpy, PyMuPDF, pdfplumber in $REQ"
else
  echo "  ⚠ no requirements.txt found — add: fastembed numpy PyMuPDF pdfplumber"
fi

# ── compile check (rollback on failure) ─────────────────────────
if command -v python3 >/dev/null 2>&1; then
  python3 -m py_compile "$APP/models.py" "$APP/pipeline/extractor.py" \
    "$APP/pipeline/chunker.py" "$APP/pipeline/validator.py" "$MEDIA" \
    && echo "  ✓ py_compile passed" || restore
fi
# drop the backups on success
for f in "$APP/models.py" "$APP/pipeline/extractor.py" "$APP/pipeline/chunker.py" \
         "$APP/pipeline/validator.py" "$MEDIA"; do rm -f "$f$BK"; done

cat <<'NOTE'
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
v15 applied. NO manual edits needed (whole files were rewritten).

STAGE 0 (quality):
  • confidence is now 0–1 everywhere (models + extractor + validator; /10 removed)
  • extraction is schema-constrained JSON with a few-shot example
  • relation endpoints fuzzy-match (>=85) before being dropped
  • in_text / verbatim-quote / denser-relations prompt rules added
  • chunker overlaps one paragraph between chunks

STAGE 1 (explainable splitter):
  • media.py matches concepts to source sentences by EMBEDDING similarity
    (paraphrase-robust), not token overlap
  • each node gets source_score (0–1) + up to 5 ranked `mentions`
  • relation evidence now lands on GraphEdge (page/evidence fields added)
  • fastembed downloads BAAI/bge-small-en-v1.5 (384-dim) on first run;
    override with EMBED_MODEL. No embedding backend => token-overlap fallback.

FRONTEND FOLLOW-UP (not in this script): surface node.source_score as a
  match badge and node.mentions in the "ref k/N" stepper. Backend now sends them.

VERIFY:
  • re-upload a PDF; logs show "embeddings: fastembed ..." once, then
    more "+ N rels" per chunk and no "JSON parse failed" warnings.
  • click a concept -> the highlighted sentence should be the real definition
    even when the label is paraphrased in the text.

ROLLBACK:  git checkout -- backend/app/models.py backend/app/pipeline/ <media path>
DEPLOY:    git add -A && git commit -m "v15: 0–1 confidence + explainable embedding provenance" && git push
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NOTE
echo "✓ done."