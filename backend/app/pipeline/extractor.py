"""
Joint concept + relation extraction with STRUCTURED OUTPUT.

THE KEY FIX: We now pass a JSON schema to chat(), which Ollama uses for
constrained decoding. This means the model CANNOT produce invalid JSON —
every token is checked against the schema at generation time.

Before: chat(messages, temperature=0.1)  ← no schema, model free-forms JSON
After:  chat(messages, json_schema=JOINT_SCHEMA, temperature=0.1)  ← constrained
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

# ── The JSON Schema for Ollama structured output ─────────────────────────
# This is what gets passed as format= to ollama.chat()
# Ollama constrains EVERY token to match this schema
JOINT_SCHEMA = {
    "type": "object",
    "properties": {
        "concepts": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "label": {"type": "string"},
                    "description": {"type": "string"},
                    "concept_type": {"type": "string",
                        "enum": ["theory","principle","definition","method",
                                 "example","evidence","argument","term",
                                 "framework","phenomenon"]},
                    "abstraction_level": {"type": "integer"},
                    "confidence": {"type": "integer"},
                    "source_quote": {"type": "string"}
                },
                "required": ["label", "description", "concept_type", "confidence"]
            }
        },
        "relations": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "source_label": {"type": "string"},
                    "target_label": {"type": "string"},
                    "relation_type": {"type": "string",
                        "enum": ["IMPLIES","REQUIRES","DEFINED_BY","CONTAINS",
                                 "PART_OF","CAUSES","ENABLES","GENERALIZES",
                                 "SPECIALIZES","ILLUSTRATES","EXTENDS",
                                 "CONSTRAINS","CONTRADICTS","PREREQUISITE_FOR",
                                 "CONTRASTS_WITH","INSTANCE_OF","EQUIVALENT",
                                 "ANALOGOUS_TO"]},
                    "justification": {"type": "string"},
                    "confidence": {"type": "integer"}
                },
                "required": ["source_label", "target_label", "relation_type"]
            }
        }
    },
    "required": ["concepts", "relations"]
}

JOINT_PROMPT = """You are an expert at analyzing educational text. Extract BOTH concepts AND relationships simultaneously.

Focus on what a student would LEARN — not every noun.

Rules:
- 2-8 concepts per section
- 3-12 relations per section
- Labels should be 2-6 words
- Descriptions should be one clear sentence
- source_label and target_label must EXACTLY match a concept label
- confidence: 1-10 (how central to the chapter)
- abstraction_level: 0=core theory, 1=key concept, 2=detail, 3=example"""

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

def _joint_extract(chunk_text, title):
    """Single LLM call with STRUCTURED OUTPUT schema."""
    msg = f"""Analyze this educational text. Extract key concepts AND their relationships.
Section: "{title}"

TEXT:
---
{chunk_text[:2500]}
---

Extract 2-8 concepts and 3-12 relations between them."""

    try:
        # THIS IS THE KEY FIX: json_schema=JOINT_SCHEMA
        # This gets passed to ollama as format=JOINT_SCHEMA
        # Ollama constrains every output token to match this schema
        raw = chat(
            [{"role": "system", "content": JOINT_PROMPT},
             {"role": "user", "content": msg}],
            json_schema=JOINT_SCHEMA,  # ← THE FIX
            temperature=0.1,
            max_tokens=2000
        )

        data = json.loads(raw)

        concepts = []
        for c in data.get("concepts", []):
            try:
                label = str(c.get("label", "")).strip()
                if len(label.split()) < 1 or len(label.split()) > 10: continue
                if len(str(c.get("description", ""))) < 10: continue
                if label.lower().strip() in SKIP: continue
                ctype_str = str(c.get("concept_type", "term"))
                try:
                    ctype = ConceptType(ctype_str)
                except:
                    ctype = ConceptType("term")
                concepts.append(Concept(
                    label=label,
                    description=str(c.get("description", ""))[:200],
                    concept_type=ctype,
                    abstraction_level=min(3, max(0, int(c.get("abstraction_level", 1)))),
                    confidence=min(10, max(1, int(c.get("confidence", 5)))),
                    source_quote=str(c.get("source_quote", ""))[:60]
                ))
            except Exception as e:
                logger.debug(f"Skipping concept: {e}")

        relations = []
        labels = {c.label.lower(): c.label for c in concepts}
        for r in data.get("relations", []):
            try:
                src = str(r.get("source_label", "")).strip()
                tgt = str(r.get("target_label", "")).strip()
                if src.lower() not in labels or tgt.lower() not in labels: continue
                if src.lower() == tgt.lower(): continue
                rtype_str = str(r.get("relation_type", "REQUIRES"))
                try:
                    rtype = RelationType(rtype_str)
                except:
                    rtype = RelationType("REQUIRES")
                relations.append(Relation(
                    source_label=labels.get(src.lower(), src),
                    target_label=labels.get(tgt.lower(), tgt),
                    relation_type=rtype,
                    justification=str(r.get("justification", ""))[:200],
                    confidence=min(10, max(1, int(r.get("confidence", 5))))
                ))
            except Exception as e:
                logger.debug(f"Skipping relation: {e}")

        return concepts, relations
    except Exception as e:
        logger.error(f"Joint extraction failed: {e}")
        return [], []

def extract_batch(chunks, max_workers=2):
    """Extract concepts AND relations jointly from all chunks."""
    all_concepts = {}
    all_relations = []
    done = 0

    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        def do(chunk):
            det = _pattern_extract(chunk.text, chunk.section_title)
            llm_concepts, llm_relations = _joint_extract(chunk.text, chunk.section_title)
            seen = {c.label.lower() for c in det}
            for c in llm_concepts:
                if c.label.lower() not in seen:
                    det.append(c)
                    seen.add(c.label.lower())
            try:
                save_training(chunk.text, chunk.section_title, det, llm_relations)
            except: pass
            return chunk.id, det, llm_relations

        futs = {ex.submit(do, c): c for c in chunks}
        for f in as_completed(futs):
            try:
                cid, concepts, relations = f.result()
                all_concepts[cid] = concepts
                all_relations.extend(relations)
                done += 1
                if concepts:
                    labels = ', '.join(c.label for c in concepts[:4])
                    logger.info(f"  [{done}/{len(chunks)}] [{labels}] + {len(relations)} rels")
                else:
                    logger.info(f"  [{done}/{len(chunks)}] (no concepts)")
            except Exception as e:
                logger.error(f"Worker error: {e}")
                all_concepts[futs[f].id] = []
                done += 1

    return all_concepts, all_relations