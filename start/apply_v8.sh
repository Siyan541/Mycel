#!/bin/bash
# ============================================================================
# Mycel v8 — Fix deployment + clean backend imports
#
# THE PROBLEM: Your backend Python files have sys.path.insert() hacks
# that work locally but BREAK inside Docker containers. When Railway
# runs the app, the first real request triggers an import chain that
# crashes because the paths don't resolve.
#
# THE FIX: Remove ALL sys.path hacks. Use environment variables directly
# instead of .env files. Make every import work from the WORKDIR /app.
#
# Run from project root: bash apply_v8.sh
# ============================================================================
set -e
echo "🍄 Mycel v8 — Deployment-safe backend..."

# ═══════════════════════════════════════════════════════════════════════════
# 1. Clean config.py — no .env file dependency, pure env vars
# ═══════════════════════════════════════════════════════════════════════════
cat > backend/app/config.py << 'PYEOF'
import os
from pathlib import Path

# Try loading .env for local dev (silently skip if missing)
try:
    from dotenv import load_dotenv
    env_path = Path(__file__).parent.parent / ".env"
    if env_path.exists():
        load_dotenv(env_path)
except ImportError:
    pass

LLM_PROVIDER = os.getenv("LLM_PROVIDER", "ollama")
LLM_MODEL = os.getenv("LLM_MODEL", "qwen2.5:3b")
TOGETHER_API_KEY = os.getenv("TOGETHER_API_KEY", "")
TOGETHER_MODEL = os.getenv("TOGETHER_MODEL", "Qwen/Qwen2.5-7B-Instruct-Turbo")

# Data directory — works both locally and in Docker
DATA_DIR = Path(os.getenv("DATA_DIR", str(Path(__file__).parent.parent.parent / "data")))
DATA_DIR.mkdir(parents=True, exist_ok=True)

UPLOAD_DIR = Path(os.getenv("UPLOAD_DIR", str(Path(__file__).parent.parent.parent / "uploads")))
UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
PYEOF
echo "  ✓ config.py — no .env dependency, env vars only"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Clean llm.py — no sys.path hacks
# ═══════════════════════════════════════════════════════════════════════════
cat > backend/app/services/llm.py << 'PYEOF'
import os, json, logging, httpx
from backend.app.config import LLM_PROVIDER, LLM_MODEL, TOGETHER_API_KEY, TOGETHER_MODEL

logger = logging.getLogger(__name__)

def chat(messages, json_schema=None, temperature=0.1, max_tokens=1500):
    if LLM_PROVIDER == "together":
        return _together(messages, json_schema, temperature, max_tokens)
    return _ollama(messages, json_schema, temperature, max_tokens)

def _ollama(messages, schema, temp, max_tok):
    import ollama as ol
    kw = {"model": LLM_MODEL, "messages": messages,
          "options": {"temperature": temp, "num_ctx": 4096, "num_predict": max_tok}}
    if schema:
        kw["format"] = schema
    return ol.chat(**kw).message.content

def _together(messages, schema, temp, max_tok):
    body = {"model": TOGETHER_MODEL, "messages": messages,
            "temperature": temp, "max_tokens": max_tok}
    if schema:
        body["response_format"] = {"type": "json_schema",
            "json_schema": {"name": "extraction", "schema": schema}}
    with httpx.Client(timeout=120) as c:
        r = c.post("https://api.together.xyz/v1/chat/completions",
            headers={"Authorization": f"Bearer {TOGETHER_API_KEY}"},
            json=body)
        r.raise_for_status()
        return r.json()["choices"][0]["message"]["content"]
PYEOF
echo "  ✓ llm.py — clean imports"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Clean storage.py — no sys.path hacks, no _db_migrate
# ═══════════════════════════════════════════════════════════════════════════
cat > backend/app/services/storage.py << 'PYEOF'
import json, sqlite3, uuid, logging
from pathlib import Path
from datetime import datetime
from backend.app.config import DATA_DIR

logger = logging.getLogger(__name__)
DB = DATA_DIR / "app.db"

def _conn():
    DB.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(str(DB))
    c.executescript("""
        CREATE TABLE IF NOT EXISTS maps (
            id TEXT PRIMARY KEY, user_id TEXT DEFAULT 'anonymous',
            filename TEXT, title TEXT, graph_json TEXT,
            status TEXT DEFAULT 'draft',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP, updated_at TEXT);
        CREATE TABLE IF NOT EXISTS corrections (
            id TEXT PRIMARY KEY, map_id TEXT, user_id TEXT DEFAULT 'anonymous',
            correction_type TEXT, original_json TEXT, corrected_json TEXT,
            quality_score INTEGER DEFAULT 0,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS training (
            id TEXT PRIMARY KEY, input_text TEXT, section_title TEXT,
            concepts_json TEXT, relations_json TEXT, domain TEXT DEFAULT 'general',
            validated INTEGER DEFAULT 0, created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS community_maps (
            id TEXT PRIMARY KEY, map_id TEXT, user_id TEXT,
            title TEXT, description TEXT, domain TEXT DEFAULT 'general',
            upvotes INTEGER DEFAULT 0, status TEXT DEFAULT 'shared',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP);
    """)
    # Migrate: add status column if missing (for old databases)
    try:
        cols = [r[1] for r in c.execute("PRAGMA table_info(maps)").fetchall()]
        if 'status' not in cols:
            c.execute("ALTER TABLE maps ADD COLUMN status TEXT DEFAULT 'draft'")
    except:
        pass
    c.commit()
    return c

def save_map(filename, graph, user_id="anonymous", title=None):
    c = _conn()
    mid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO maps (id,user_id,filename,title,graph_json,status,updated_at) VALUES (?,?,?,?,?,?,?)",
        (mid, user_id, filename, title or filename, graph.model_dump_json(), 'draft', datetime.now().isoformat()))
    c.commit(); c.close()
    return mid

def get_maps(user_id=None):
    c = _conn()
    if user_id:
        rows = c.execute("SELECT id,filename,title,status,created_at FROM maps WHERE user_id=? ORDER BY created_at DESC", (user_id,)).fetchall()
    else:
        rows = c.execute("SELECT id,filename,title,status,created_at FROM maps ORDER BY created_at DESC").fetchall()
    c.close()
    return [{"id":r[0],"filename":r[1],"title":r[2],"status":r[3],"created_at":r[4]} for r in rows]

def get_map(map_id):
    from backend.app.models import KnowledgeGraph
    c = _conn()
    row = c.execute("SELECT graph_json FROM maps WHERE id=?", (map_id,)).fetchone()
    c.close()
    return KnowledgeGraph.model_validate_json(row[0]) if row else None

def delete_map(map_id):
    c = _conn(); c.execute("DELETE FROM maps WHERE id=?", (map_id,)); c.commit(); c.close()

def confirm_map(map_id):
    c = _conn()
    c.execute("UPDATE maps SET status='confirmed', updated_at=? WHERE id=?", (datetime.now().isoformat(), map_id))
    c.commit(); c.close()

def save_correction(map_id, ctype, original, corrected, user_id="anonymous", quality=0):
    c = _conn()
    cid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO corrections (id,map_id,user_id,correction_type,original_json,corrected_json,quality_score) VALUES (?,?,?,?,?,?,?)",
        (cid, map_id, user_id, ctype, json.dumps(original) if original else '{}', json.dumps(corrected) if corrected else '{}', quality))
    c.commit(); c.close()
    return cid

def get_corrections_stats():
    c = _conn()
    total = c.execute("SELECT COUNT(*) FROM corrections").fetchone()[0]
    c.close()
    return {"total": total}

def share_to_community(map_id, user_id, title, description="", domain="general"):
    c = _conn()
    cid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO community_maps (id,map_id,user_id,title,description,domain) VALUES (?,?,?,?,?,?)",
        (cid, map_id, user_id, title, description, domain))
    c.commit(); c.close()
    return cid

def get_community_maps(domain=None, limit=50):
    c = _conn()
    if domain:
        rows = c.execute("SELECT id,title,description,domain,upvotes,user_id,created_at,map_id FROM community_maps WHERE domain=? ORDER BY upvotes DESC LIMIT ?", (domain, limit)).fetchall()
    else:
        rows = c.execute("SELECT id,title,description,domain,upvotes,user_id,created_at,map_id FROM community_maps ORDER BY upvotes DESC LIMIT ?", (limit,)).fetchall()
    c.close()
    return [{"id":r[0],"title":r[1],"description":r[2],"domain":r[3],"upvotes":r[4],"user_id":r[5],"created_at":r[6],"map_id":r[7]} for r in rows]

def upvote_community_map(community_id):
    c = _conn()
    c.execute("UPDATE community_maps SET upvotes=upvotes+1 WHERE id=?", (community_id,))
    c.commit(); c.close()

def save_training(input_text, section_title, concepts, relations=None, domain="general"):
    c = _conn()
    tid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO training (id,input_text,section_title,concepts_json,relations_json,domain) VALUES (?,?,?,?,?,?)",
        (tid, input_text[:5000], section_title,
         json.dumps([x if isinstance(x,dict) else x.model_dump() for x in concepts]),
         json.dumps([x if isinstance(x,dict) else x.model_dump() for x in (relations or [])]), domain))
    c.commit(); c.close()

def get_training_stats():
    c = _conn()
    total = c.execute("SELECT COUNT(*) FROM training").fetchone()[0]
    confirmed = c.execute("SELECT COUNT(*) FROM maps WHERE status='confirmed'").fetchone()[0]
    c.close()
    return {"total_training": total, "confirmed_maps": confirmed}

def export_training(path=None, confirmed_only=True):
    if path is None:
        path = str(DATA_DIR / "training_chat.jsonl")
    c = _conn()
    rows = c.execute("SELECT input_text,section_title,concepts_json,relations_json FROM training").fetchall()
    c.close()
    Path(path).parent.mkdir(exist_ok=True)
    with open(path, 'w') as f:
        for text, title, cj, rj in rows:
            f.write(json.dumps({"messages": [
                {"role": "system", "content": "Extract concepts and relationships from academic text. Return JSON."},
                {"role": "user", "content": f'Section: "{title}"\n\n{text[:1500]}'},
                {"role": "assistant", "content": json.dumps({"concepts": json.loads(cj), "relations": json.loads(rj)})},
            ]}) + "\n")
    return len(rows)
PYEOF
echo "  ✓ storage.py — clean imports, auto-migration"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Clean extractor.py — no sys.path hacks
# ═══════════════════════════════════════════════════════════════════════════
cat > backend/app/pipeline/extractor.py << 'PYEOF'
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

PROMPT = """Extract key concepts AND relationships from educational text.
Rules: 2-8 concepts, 3-12 relations per section. Labels 2-6 words. Descriptions one sentence.
source_label and target_label must exactly match a concept label.
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
    msg = f'Analyze this text. Section: "{title}"\n\nTEXT:\n---\n{text[:2500]}\n---\n\nExtract 2-8 concepts and their relations.'
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
PYEOF
echo "  ✓ extractor.py — clean imports, json_schema passed"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Clean orchestrator.py
# ═══════════════════════════════════════════════════════════════════════════
cat > backend/app/pipeline/orchestrator.py << 'PYEOF'
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
PYEOF
echo "  ✓ orchestrator.py — clean imports"

# ═══════════════════════════════════════════════════════════════════════════
# 6. Clean main.py
# ═══════════════════════════════════════════════════════════════════════════
cat > backend/app/main.py << 'PYEOF'
import os, shutil, logging
from pathlib import Path
from contextlib import asynccontextmanager

from fastapi import FastAPI, UploadFile, File, Query, Body
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from backend.app.config import UPLOAD_DIR
from backend.app.pipeline.orchestrator import run
from backend.app.services.storage import (
    save_map, get_maps, get_map, delete_map, confirm_map,
    save_correction, get_corrections_stats, get_training_stats, export_training,
    share_to_community, get_community_maps, upvote_community_map,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("app")

@asynccontextmanager
async def lifespan(app): yield

app = FastAPI(title="Mycel", version="2.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

ALLOWED_EXT = {'.pdf', '.docx', '.txt', '.md', '.markdown', '.rst', '.tex', '.epub'}

@app.get("/")
async def root():
    return {"status": "ok", "version": "2.0.0"}

@app.post("/api/upload")
async def upload(file: UploadFile = File(...)):
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in ALLOWED_EXT:
        return JSONResponse({"error": f"Unsupported format. Use: {', '.join(ALLOWED_EXT)}"}, 400)
    fp = UPLOAD_DIR / file.filename
    with open(fp, "wb") as f:
        shutil.copyfileobj(file.file, f)
    graph = run(str(fp))
    map_id = save_map(file.filename, graph)
    return {"status": "success", "map_id": map_id, "document": file.filename,
            "nodes": [n.model_dump() for n in graph.nodes],
            "edges": [e.model_dump() for e in graph.edges],
            "node_count": len(graph.nodes), "edge_count": len(graph.edges)}

@app.get("/api/maps")
async def list_maps(user_id: str = None):
    return {"maps": get_maps(user_id)}

@app.get("/api/maps/{map_id}")
async def get_map_data(map_id: str):
    g = get_map(map_id)
    if not g: return JSONResponse({"error": "Not found"}, 404)
    return {"nodes": [n.model_dump() for n in g.nodes], "edges": [e.model_dump() for e in g.edges]}

@app.delete("/api/maps/{map_id}")
async def del_map(map_id: str):
    delete_map(map_id)
    return {"status": "deleted"}

@app.post("/api/maps/{map_id}/confirm")
async def confirm(map_id: str):
    confirm_map(map_id)
    return {"status": "confirmed"}

@app.post("/api/maps/{map_id}/unconfirm")
async def unconfirm(map_id: str):
    from backend.app.services.storage import _conn
    from datetime import datetime
    c = _conn()
    c.execute("UPDATE maps SET status='draft', updated_at=? WHERE id=?", (datetime.now().isoformat(), map_id))
    c.commit(); c.close()
    return {"status": "draft"}

@app.post("/api/corrections")
async def submit_correction(body: dict = Body(...)):
    cid = save_correction(body.get("map_id",""), body.get("type","edit"),
        body.get("original"), body.get("corrected"))
    return {"id": cid}

@app.post("/api/community/share")
async def share(body: dict = Body(...)):
    cid = share_to_community(body["map_id"], body.get("user_id","anonymous"),
        body["title"], body.get("description",""), body.get("domain","general"))
    return {"id": cid}

@app.get("/api/community")
async def community(domain: str = None, limit: int = 50):
    return {"maps": get_community_maps(domain, limit)}

@app.post("/api/community/{community_id}/upvote")
async def upvote(community_id: str):
    upvote_community_map(community_id)
    return {"status": "upvoted"}

@app.get("/api/stats")
async def stats():
    return {"corrections": get_corrections_stats(), "training": get_training_stats()}
PYEOF
echo "  ✓ main.py — clean, all endpoints"

# ═══════════════════════════════════════════════════════════════════════════
# 7. Clean parser.py — remove sys.path hack
# ═══════════════════════════════════════════════════════════════════════════
if [ -f backend/app/pipeline/parser.py ]; then
    # Remove all sys.path.insert lines
    sed -i.bak '/sys\.path\.insert/d' backend/app/pipeline/parser.py
    # Fix imports: remove "backend.app." prefix if importing from same package
    sed -i.bak 's/from backend\.app\.models/from backend.app.models/' backend/app/pipeline/parser.py
    rm -f backend/app/pipeline/parser.py.bak
    echo "  ✓ parser.py — cleaned sys.path"
fi

# ═══════════════════════════════════════════════════════════════════════════
# 8. Clean other files that might have sys.path hacks
# ═══════════════════════════════════════════════════════════════════════════
for f in backend/app/pipeline/chunker.py backend/app/pipeline/validator.py backend/app/training/collector.py; do
    if [ -f "$f" ]; then
        sed -i.bak '/sys\.path\.insert/d' "$f"
        sed -i.bak '/^import sys/d' "$f"
        rm -f "${f}.bak"
    fi
done
echo "  ✓ Cleaned sys.path from all pipeline files"

# ═══════════════════════════════════════════════════════════════════════════
# 9. Remove _db_migrate.py if it exists (migration is now in storage.py)
# ═══════════════════════════════════════════════════════════════════════════
rm -f backend/app/services/_db_migrate.py
echo "  ✓ Removed _db_migrate.py (migration now inline)"

# ═══════════════════════════════════════════════════════════════════════════
# 10. Ensure all __init__.py files exist
# ═══════════════════════════════════════════════════════════════════════════
for d in backend backend/app backend/app/pipeline backend/app/services backend/app/training; do
    mkdir -p "$d"
    touch "$d/__init__.py"
done
echo "  ✓ All __init__.py files present"

# ═══════════════════════════════════════════════════════════════════════════
# 11. Update requirements.txt
# ═══════════════════════════════════════════════════════════════════════════
cat > backend/requirements.txt << 'EOF'
fastapi==0.115.6
uvicorn[standard]==0.34.0
python-multipart==0.0.20
PyMuPDF==1.25.3
pydantic==2.10.4
rapidfuzz==3.11.0
python-dotenv==1.0.1
httpx==0.28.1
ollama==0.4.7
python-docx==1.1.0
EOF
echo "  ✓ requirements.txt updated"

# ═══════════════════════════════════════════════════════════════════════════
# 12. Dockerfile + entrypoint (known working config)
# ═══════════════════════════════════════════════════════════════════════════
cat > entrypoint.sh << 'EOF'
#!/bin/sh
exec python -m uvicorn backend.app.main:app --host 0.0.0.0 --port ${PORT:-8000}
EOF
chmod +x entrypoint.sh

cat > Dockerfile << 'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY backend/ backend/
COPY entrypoint.sh .
RUN mkdir -p uploads data
RUN touch backend/__init__.py backend/app/__init__.py backend/app/pipeline/__init__.py backend/app/services/__init__.py backend/app/training/__init__.py
RUN chmod +x entrypoint.sh
CMD ["./entrypoint.sh"]
EOF

cat > railway.toml << 'EOF'
[build]
builder = "DOCKERFILE"
dockerfilePath = "Dockerfile"

[deploy]
healthcheckPath = "/"
EOF

echo "  ✓ Dockerfile + entrypoint.sh + railway.toml"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 Mycel v8 applied!"
echo ""
echo "WHAT CHANGED:"
echo "  • Removed ALL sys.path.insert() hacks from every Python file"
echo "  • config.py works without .env file (uses env vars directly)"
echo "  • storage.py has inline DB migration (no _db_migrate.py)"
echo "  • All imports use 'from backend.app.xxx' (works from /app WORKDIR)"
echo "  • extractor.py passes json_schema for constrained JSON output"
echo "  • main.py has all endpoints (upload, community, confirm, etc.)"
echo "  • entrypoint.sh handles Railway \$PORT expansion"
echo ""
echo "DEPLOY:"
echo "  git add -A && git commit -m 'v8: fix deployment imports' && git push"
echo ""
echo "Railway will auto-rebuild. This time it should work because:"
echo "  1. No sys.path hacks → imports work from Docker's /app directory"
echo "  2. No .env dependency → env vars come from Railway dashboard"
echo "  3. entrypoint.sh → proper \$PORT expansion"
echo "  4. Inline DB migration → no import chain failures"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"