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
            "concept_type": {"type": "string", "enum": ["theory","principle","definition","method","example","evidence","argument","term","framework","phenomenon"]},
            "abstraction_level": {"type": "integer"}, "confidence": {"type": "integer"}, "source_quote": {"type": "string"}
        }, "required": ["label","description","concept_type","confidence"]}},
        "relations": {"type": "array", "items": {"type": "object", "properties": {
            "source_label": {"type": "string"}, "target_label": {"type": "string"},
            "relation_type": {"type": "string", "enum": ["IMPLIES","REQUIRES","DEFINED_BY","CONTAINS","PART_OF","CAUSES","ENABLES","GENERALIZES","SPECIALIZES","ILLUSTRATES","EXTENDS","CONSTRAINS","CONTRADICTS","PREREQUISITE_FOR","CONTRASTS_WITH","INSTANCE_OF","EQUIVALENT","ANALOGOUS_TO"]},
            "justification": {"type": "string"}, "confidence": {"type": "integer"}
        }, "required": ["source_label","target_label","relation_type"]}}
    }, "required": ["concepts","relations"]
}

PROMPT = """You are an expert knowledge extractor for educational textbooks. Given a section of text, you MUST extract important concepts and their relationships.

CRITICAL RULES:
1. Extract at least 4 concepts and at least 3 relations
2. NEVER return empty arrays
3. Each concept label should be 2-6 words (not single words, not sentences)
4. Each description must be a complete sentence explaining the concept
5. Every source_label and target_label in relations must EXACTLY match a concept label
6. concept_type must be one of: theory, principle, definition, method, example, evidence, argument, term, framework, phenomenon
7. relation_type must be one of: IMPLIES, REQUIRES, DEFINED_BY, CONTAINS, PART_OF, CAUSES, ENABLES, GENERALIZES, SPECIALIZES, ILLUSTRATES, EXTENDS, CONSTRAINS, CONTRADICTS, PREREQUISITE_FOR

Example of GOOD output:
{"concepts":[{"label":"Natural Selection","description":"The process where organisms with favorable traits survive and reproduce more","concept_type":"theory","abstraction_level":0,"confidence":9,"source_quote":"natural selection"},{"label":"Genetic Variation","description":"Differences in DNA sequences among individuals in a population","concept_type":"definition","abstraction_level":1,"confidence":8,"source_quote":"genetic variation"},{"label":"Adaptation","description":"A trait that increases an organism fitness in its environment","concept_type":"definition","abstraction_level":1,"confidence":8,"source_quote":"adaptation"},{"label":"Survival of the Fittest","description":"Organisms best suited to their environment are most likely to survive","concept_type":"principle","abstraction_level":0,"confidence":9,"source_quote":"survival"}],"relations":[{"source_label":"Natural Selection","target_label":"Genetic Variation","relation_type":"REQUIRES","justification":"Natural selection acts on existing genetic variation","confidence":9},{"source_label":"Natural Selection","target_label":"Adaptation","relation_type":"CAUSES","justification":"Selection pressure leads to adaptations over generations","confidence":8},{"source_label":"Survival of the Fittest","target_label":"Natural Selection","relation_type":"ILLUSTRATES","justification":"Survival of the fittest is the core principle of natural selection","confidence":9}]}
confidence 1-10, abstraction_level 0=core 1=key 2=detail 3=example."""

SKIP = {"compiler","text editor","programming","software","code","variable","function",
    "file","program","computer","download","install","setup","getting started","introduction",
    "exercise","example","solution","chapter","book","author","reader","forum","website"}

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
    msg = f"""Carefully read this educational text and extract ALL important concepts and how they relate to each other.

Section title: "{title}"

TEXT TO ANALYZE:
---
{text[:3000]}
---

Extract at least 4 concepts (key terms, theories, definitions, methods) and at least 3 relations between them. Each relation must connect two concepts by their exact label. Return valid JSON with "concepts" and "relations" arrays. Do NOT return empty arrays."""
    try:
        raw = chat([{"role":"system","content":PROMPT},{"role":"user","content":msg}],
                   json_schema=JOINT_SCHEMA, temperature=0.1, max_tokens=2000)
        data = json.loads(raw)
        concepts = []
        for c in data.get("concepts", []):
            try:
                label = str(c.get("label","")).strip()
                if not label or len(label.split()) > 10 or label.lower() in SKIP: continue
                if len(str(c.get("description",""))) < 10: continue
                try: ct = ConceptType(c.get("concept_type","term"))
                except: ct = ConceptType("term")
                concepts.append(Concept(label=label, description=str(c.get("description",""))[:200],
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
