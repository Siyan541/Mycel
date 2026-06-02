import re, json, logging
from concurrent.futures import ThreadPoolExecutor, as_completed
from backend.app.models import Concept, ConceptType, Relation, RelationType
from backend.app.services.llm import chat
from backend.app.services.storage import save_training

logger = logging.getLogger(__name__)

JOINT_SCHEMA = {
    "type": "object",
    "properties": {
        "concepts": {"type": "array", "items": {"type": "object", "properties": {
            "label": {"type": "string"}, "description": {"type": "string"},
            "concept_type": {"type": "string"},
            "abstraction_level": {"type": "integer"}, "confidence": {"type": "integer"},
            "source_quote": {"type": "string"}
        }, "required": ["label","description","concept_type","confidence"]}},
        "relations": {"type": "array", "items": {"type": "object", "properties": {
            "source_label": {"type": "string"}, "target_label": {"type": "string"},
            "relation_type": {"type": "string"},
            "justification": {"type": "string"}, "confidence": {"type": "integer"}
        }, "required": ["source_label","target_label","relation_type"]}}
    }, "required": ["concepts","relations"]
}

PROMPT = """You are an expert knowledge extractor. You MUST return a JSON object with "concepts" and "relations" arrays.

EVERY concept must have ALL these fields:
- "label": 2-6 word name (NOT single words)
- "description": one full sentence explaining what it is
- "concept_type": one of theory/principle/definition/method/example/evidence/argument/term/framework/phenomenon
- "abstraction_level": 0 for core ideas, 1 for key concepts, 2 for details, 3 for examples
- "confidence": 1-10
- "source_quote": brief phrase from the text

EVERY relation must have ALL these fields:
- "source_label": exact label of a concept you listed
- "target_label": exact label of a DIFFERENT concept you listed
- "relation_type": one of IMPLIES/REQUIRES/DEFINED_BY/CONTAINS/PART_OF/CAUSES/ENABLES/GENERALIZES/SPECIALIZES/ILLUSTRATES/EXTENDS/CONSTRAINS/CONTRADICTS/PREREQUISITE_FOR
- "justification": one sentence explaining the connection
- "confidence": 1-10

EXAMPLE output:
{"concepts":[{"label":"Cellular Respiration","description":"The metabolic process converting glucose and oxygen into ATP energy","concept_type":"definition","abstraction_level":0,"confidence":9,"source_quote":"cellular respiration"},{"label":"Glycolysis Pathway","description":"First stage breaking glucose into pyruvate molecules","concept_type":"method","abstraction_level":1,"confidence":8,"source_quote":"glycolysis"},{"label":"ATP Molecule","description":"Adenosine triphosphate is the primary energy currency of cells","concept_type":"definition","abstraction_level":1,"confidence":9,"source_quote":"ATP"},{"label":"Krebs Cycle","description":"Chemical reactions in mitochondria generating electron carriers","concept_type":"method","abstraction_level":1,"confidence":8,"source_quote":"Krebs cycle"}],"relations":[{"source_label":"Cellular Respiration","target_label":"Glycolysis Pathway","relation_type":"CONTAINS","justification":"Glycolysis is the first step of respiration","confidence":9},{"source_label":"Glycolysis Pathway","target_label":"Krebs Cycle","relation_type":"PREREQUISITE_FOR","justification":"Pyruvate from glycolysis feeds into Krebs cycle","confidence":9},{"source_label":"Krebs Cycle","target_label":"ATP Molecule","relation_type":"CAUSES","justification":"Krebs cycle contributes to ATP production","confidence":8}]}

Extract at least 5 concepts and 4 relations. Return ONLY the JSON object, no markdown fences, no explanation."""

SKIP = {"compiler","text editor","programming","software","code","variable","function",
    "file","program","computer","download","install","setup","getting started","introduction",
    "exercise","example","solution","chapter","book","author","reader","forum","website"}

def _clean_json(raw):
    s = raw.strip()
    if s.startswith('```'):
        s = s.split('\n', 1)[1] if '\n' in s else s[3:]
    if s.endswith('```'):
        s = s[:-3]
    s = s.strip()
    start = s.find('{')
    if start < 0: return '{}'
    depth = 0
    end = len(s)
    for i in range(start, len(s)):
        if s[i] == '{': depth += 1
        elif s[i] == '}': depth -= 1
        if depth == 0: end = i + 1; break
    result = s[start:end]
    result = re.sub(r',\s*([}\]])', r'\1', result)
    return result

def _pattern_extract(text, title=""):
    concepts = []
    seen = set()
    for pat, ctype, level in [
        (r"(?:^|\.\s+)([A-Z][\w\s]{2,35})\s+(?:is defined as|is a|refers to|means)\s+(.{15,200}?)(?:\.|$)", "definition", 1),
        (r"(?:called|known as|termed)\s+(?:the\s+)?([a-zA-Z][\w\s]{2,25}?)(?:\s*[,.])", "term", 2),
    ]:
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

def _joint_extract(text, title):
    msg = f"""Read this educational text and extract ALL key concepts and how they relate.

Section: "{title}"

TEXT:
---
{text[:3000]}
---

Return ONLY a JSON object with "concepts" (at least 5) and "relations" (at least 4). Use multi-word labels, full sentence descriptions, and connect concepts with meaningful relations. No markdown, no explanation, just JSON."""
    try:
        raw = chat([{"role":"system","content":PROMPT},{"role":"user","content":msg}],
                   json_schema=JOINT_SCHEMA, temperature=0.05, max_tokens=3000)
        cleaned = _clean_json(raw)
        data = json.loads(cleaned)
        concepts = []
        for c in data.get("concepts", []):
            try:
                label = str(c.get("label","")).strip()
                if not label or len(label) < 3 or label.lower() in SKIP: continue
                desc = str(c.get("description",""))
                if len(desc) < 10: continue
                try: ct = ConceptType(c.get("concept_type","term"))
                except: ct = ConceptType("term")
                concepts.append(Concept(label=label, description=desc[:200],
                    concept_type=ct, abstraction_level=min(3,max(0,int(c.get("abstraction_level",1)))),
                    confidence=min(10,max(1,int(c.get("confidence",5)))),
                    source_quote=str(c.get("source_quote",""))[:60]))
            except: pass
        relations = []
        labels = {c.label.lower(): c.label for c in concepts}
        for r in data.get("relations", []):
            try:
                src = str(r.get("source_label","")).strip()
                tgt = str(r.get("target_label","")).strip()
                if src.lower() not in labels or tgt.lower() not in labels or src.lower()==tgt.lower(): continue
                try: rt = RelationType(r.get("relation_type","REQUIRES"))
                except: rt = RelationType("REQUIRES")
                relations.append(Relation(source_label=labels.get(src.lower(),src), target_label=labels.get(tgt.lower(),tgt),
                    relation_type=rt, justification=str(r.get("justification",""))[:200],
                    confidence=min(10,max(1,int(r.get("confidence",5))))))
            except: pass
        return concepts, relations
    except Exception as e:
        logger.error(f"Joint extraction failed: {e}")
        return [], []

def extract_batch(chunks, max_workers=2):
    all_concepts, all_relations, done = {}, [], 0
    with ThreadPoolExecutor(max_workers=max_workers) as ex:
        def do(chunk):
            det = _pattern_extract(chunk.text, chunk.section_title)
            llm_c, llm_r = _joint_extract(chunk.text, chunk.section_title)
            seen = {c.label.lower() for c in det}
            for c in llm_c:
                if c.label.lower() not in seen: det.append(c); seen.add(c.label.lower())
            try: save_training(chunk.text, chunk.section_title, det, llm_r)
            except: pass
            return chunk.id, det, llm_r
        futs = {ex.submit(do, c): c for c in chunks}
        for f in as_completed(futs):
            try:
                cid, concepts, relations = f.result()
                all_concepts[cid] = concepts; all_relations.extend(relations); done += 1
                if concepts: logger.info(f"  [{done}/{len(chunks)}] [{', '.join(c.label for c in concepts[:4])}] + {len(relations)} rels")
            except Exception as e:
                logger.error(f"Worker error: {e}"); all_concepts[futs[f].id] = []; done += 1
    return all_concepts, all_relations