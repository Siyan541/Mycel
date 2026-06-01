import logging
from backend.app.models import KnowledgeGraph
from backend.app.pipeline.parser import parse_file
from backend.app.pipeline.chunker import chunk_sections
from backend.app.pipeline.extractor import extract_batch
from backend.app.pipeline.validator import validate

logger = logging.getLogger(__name__)

def run(filepath, max_workers=2, progress_cb=None):
    logger.info("[parse] Parsing document...")
    skeleton = parse_file(filepath)
    logger.info(f"[parse] {len(skeleton.sections)} sections")

    logger.info("[chunk] Chunking...")
    chunks = chunk_sections(skeleton.sections)
    logger.info(f"[chunk] {len(chunks)} chunks")
    if not chunks:
        return KnowledgeGraph(document_name=skeleton.filename, nodes=[], edges=[], metadata={"error": "No text"})

    logger.info(f"[extract] Extracting from {len(chunks)} chunks...")
    chunk_concepts, all_relations = extract_batch(chunks, max_workers=max_workers)
    all_concepts = []
    for ch in chunks:
        all_concepts.extend(chunk_concepts.get(ch.id, []))
    logger.info(f"[extract] {len(all_concepts)} concepts, {len(all_relations)} relations")

    logger.info("[validate] Validating...")
    graph = validate(all_concepts, all_relations, skeleton.filename)
    logger.info(f"[validate] Final: {len(graph.nodes)} nodes, {len(graph.edges)} edges")
    return graph
