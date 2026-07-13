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
