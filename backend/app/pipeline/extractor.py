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
