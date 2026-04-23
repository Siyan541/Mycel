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
