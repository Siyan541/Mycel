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
