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
