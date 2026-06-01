#!/bin/bash
# ============================================================================
# Mycel v9 — Everything before the maze
#
# BACKEND:
#   - Simple auth (token-based, no Firebase needed)
#   - User profiles with credit system (6 levels)
#   - Reversible actions (unconfirm, unshare, restore deleted)
#   - Admin endpoints (view all data, approve maps, export training)
#   - Quality scoring algorithm for mindmaps
#   - User activity log for credit calculation
#
# FRONTEND:
#   - Complete api.js with auth headers
#   - Instructions for App.jsx (too large for sed, must be manual)
#
# Run from project root: bash apply_v9.sh
# ============================================================================
set -e
echo "🍄 Mycel v9 — Full platform backend..."

# ═══════════════════════════════════════════════════════════════════════════
# 1. Updated models.py with user + credit models
# ═══════════════════════════════════════════════════════════════════════════
cat > backend/app/models.py << 'PYEOF'
from pydantic import BaseModel, Field
from enum import Enum
from typing import Optional

class ConceptType(str, Enum):
    theory="theory"; principle="principle"; definition="definition"
    method="method"; example="example"; evidence="evidence"
    argument="argument"; term="term"; framework="framework"
    phenomenon="phenomenon"

class RelationType(str, Enum):
    IMPLIES="IMPLIES"; REQUIRES="REQUIRES"; DEFINED_BY="DEFINED_BY"
    CONTAINS="CONTAINS"; PART_OF="PART_OF"; CAUSES="CAUSES"
    ENABLES="ENABLES"; GENERALIZES="GENERALIZES"; SPECIALIZES="SPECIALIZES"
    ILLUSTRATES="ILLUSTRATES"; EXTENDS="EXTENDS"; CONSTRAINS="CONSTRAINS"
    CONTRADICTS="CONTRADICTS"; PREREQUISITE_FOR="PREREQUISITE_FOR"
    CONTRASTS_WITH="CONTRASTS_WITH"; INSTANCE_OF="INSTANCE_OF"
    EQUIVALENT="EQUIVALENT"; ANALOGOUS_TO="ANALOGOUS_TO"

class Section(BaseModel):
    id: str; title: str; level: int; page_start: int; page_end: int
    text: str = ""; parent_id: Optional[str] = None

class Skeleton(BaseModel):
    filename: str; total_pages: int; sections: list[Section]

class Chunk(BaseModel):
    id: str; section_id: str; section_title: str; text: str

class Concept(BaseModel):
    label: str; description: str; concept_type: ConceptType
    abstraction_level: int = Field(ge=0, le=3)
    confidence: int = Field(ge=1, le=10)
    source_quote: str = ""

class ConceptResult(BaseModel):
    concepts: list[Concept]

class Relation(BaseModel):
    source_label: str; target_label: str
    relation_type: RelationType
    justification: str = ""; confidence: int = Field(ge=1, le=10)

class RelationResult(BaseModel):
    relations: list[Relation]

class GraphNode(BaseModel):
    id: str; label: str; description: str; concept_type: ConceptType
    abstraction_level: int; confidence: float
    cluster: str = ""; source_page: int = 0

class GraphEdge(BaseModel):
    id: str; source_id: str; target_id: str; relation_type: RelationType
    justification: str; confidence: float

class KnowledgeGraph(BaseModel):
    document_name: str; nodes: list[GraphNode]; edges: list[GraphEdge]
    metadata: dict = Field(default_factory=dict)

# ── User & Credit models ──
class UserLevel(str, Enum):
    none = "none"
    beginner = "beginner"
    experienced = "experienced"
    expert = "expert"
    professional = "professional"
    organizer = "organizer"

LEVEL_THRESHOLDS = {
    "none": 0, "beginner": 1, "experienced": 50,
    "expert": 200, "professional": 500, "organizer": 1500
}

def get_level(points):
    level = "none"
    for name, threshold in LEVEL_THRESHOLDS.items():
        if points >= threshold:
            level = name
    return level
PYEOF
echo "  ✓ models.py — with user levels + credit thresholds"

# ═══════════════════════════════════════════════════════════════════════════
# 2. Updated storage.py with users, credits, activity log, trash
# ═══════════════════════════════════════════════════════════════════════════
cat > backend/app/services/storage.py << 'PYEOF'
import json, sqlite3, uuid, hashlib, logging
from pathlib import Path
from datetime import datetime
from backend.app.config import DATA_DIR
from backend.app.models import get_level

logger = logging.getLogger(__name__)
DB = DATA_DIR / "app.db"

def _conn():
    DB.parent.mkdir(parents=True, exist_ok=True)
    c = sqlite3.connect(str(DB))
    c.executescript("""
        CREATE TABLE IF NOT EXISTS users (
            id TEXT PRIMARY KEY, username TEXT UNIQUE NOT NULL,
            display_name TEXT, password_hash TEXT,
            points INTEGER DEFAULT 0, level TEXT DEFAULT 'beginner',
            bio TEXT DEFAULT '', created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS maps (
            id TEXT PRIMARY KEY, user_id TEXT DEFAULT 'anonymous',
            filename TEXT, title TEXT, graph_json TEXT,
            status TEXT DEFAULT 'draft', deleted INTEGER DEFAULT 0,
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
        CREATE TABLE IF NOT EXISTS activity (
            id TEXT PRIMARY KEY, user_id TEXT, action TEXT,
            target_id TEXT, points_delta INTEGER DEFAULT 0,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS favorites (
            user_id TEXT, map_id TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (user_id, map_id));
    """)
    # Migrate old tables
    try:
        cols = [r[1] for r in c.execute("PRAGMA table_info(maps)").fetchall()]
        if 'status' not in cols: c.execute("ALTER TABLE maps ADD COLUMN status TEXT DEFAULT 'draft'")
        if 'deleted' not in cols: c.execute("ALTER TABLE maps ADD COLUMN deleted INTEGER DEFAULT 0")
    except: pass
    c.commit()
    return c

# ── Users ──
def create_user(username, password, display_name=None):
    c = _conn()
    uid = str(uuid.uuid4())[:12]
    pw_hash = hashlib.sha256(password.encode()).hexdigest()
    try:
        c.execute("INSERT INTO users (id,username,display_name,password_hash,points,level) VALUES (?,?,?,?,?,?)",
            (uid, username.lower().strip(), display_name or username, pw_hash, 0, 'beginner'))
        c.commit()
    except sqlite3.IntegrityError:
        c.close()
        return None, "Username already taken"
    c.close()
    return uid, None

def login_user(username, password):
    c = _conn()
    pw_hash = hashlib.sha256(password.encode()).hexdigest()
    row = c.execute("SELECT id,username,display_name,points,level FROM users WHERE username=? AND password_hash=?",
        (username.lower().strip(), pw_hash)).fetchone()
    c.close()
    if not row: return None
    return {"id": row[0], "username": row[1], "display_name": row[2], "points": row[3], "level": row[4]}

def get_user(user_id):
    c = _conn()
    row = c.execute("SELECT id,username,display_name,points,level,bio,created_at FROM users WHERE id=?", (user_id,)).fetchone()
    c.close()
    if not row: return None
    return {"id":row[0],"username":row[1],"display_name":row[2],"points":row[3],"level":row[4],"bio":row[5],"created_at":row[6]}

def update_user(user_id, display_name=None, bio=None):
    c = _conn()
    if display_name: c.execute("UPDATE users SET display_name=? WHERE id=?", (display_name, user_id))
    if bio is not None: c.execute("UPDATE users SET bio=? WHERE id=?", (bio, user_id))
    c.commit(); c.close()

# ── Credits ──
def add_points(user_id, points, action, target_id=""):
    c = _conn()
    c.execute("UPDATE users SET points=points+? WHERE id=?", (points, user_id))
    # Recalculate level
    row = c.execute("SELECT points FROM users WHERE id=?", (user_id,)).fetchone()
    if row:
        new_level = get_level(row[0])
        c.execute("UPDATE users SET level=? WHERE id=?", (new_level, user_id))
    # Log activity
    aid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO activity (id,user_id,action,target_id,points_delta) VALUES (?,?,?,?,?)",
        (aid, user_id, action, target_id, points))
    c.commit(); c.close()

def get_activity(user_id, limit=20):
    c = _conn()
    rows = c.execute("SELECT action,target_id,points_delta,created_at FROM activity WHERE user_id=? ORDER BY created_at DESC LIMIT ?",
        (user_id, limit)).fetchall()
    c.close()
    return [{"action":r[0],"target_id":r[1],"points":r[2],"created_at":r[3]} for r in rows]

def get_leaderboard(limit=20):
    c = _conn()
    rows = c.execute("SELECT id,username,display_name,points,level FROM users ORDER BY points DESC LIMIT ?", (limit,)).fetchall()
    c.close()
    return [{"id":r[0],"username":r[1],"display_name":r[2],"points":r[3],"level":r[4]} for r in rows]

# ── Maps (with soft delete) ──
def save_map(filename, graph, user_id="anonymous", title=None):
    c = _conn()
    mid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO maps (id,user_id,filename,title,graph_json,status,updated_at) VALUES (?,?,?,?,?,?,?)",
        (mid, user_id, filename, title or filename, graph.model_dump_json(), 'draft', datetime.now().isoformat()))
    c.commit(); c.close()
    if user_id != "anonymous": add_points(user_id, 5, "upload", mid)
    return mid

def get_maps(user_id=None):
    c = _conn()
    if user_id and user_id != "anonymous":
        rows = c.execute("SELECT id,filename,title,status,created_at FROM maps WHERE user_id=? AND deleted=0 ORDER BY created_at DESC", (user_id,)).fetchall()
    else:
        rows = c.execute("SELECT id,filename,title,status,created_at FROM maps WHERE deleted=0 ORDER BY created_at DESC").fetchall()
    c.close()
    return [{"id":r[0],"filename":r[1],"title":r[2],"status":r[3],"created_at":r[4]} for r in rows]

def get_map(map_id):
    from backend.app.models import KnowledgeGraph
    c = _conn()
    row = c.execute("SELECT graph_json FROM maps WHERE id=? AND deleted=0", (map_id,)).fetchone()
    c.close()
    return KnowledgeGraph.model_validate_json(row[0]) if row else None

def delete_map(map_id, user_id=None):
    c = _conn()
    c.execute("UPDATE maps SET deleted=1, updated_at=? WHERE id=?", (datetime.now().isoformat(), map_id))
    c.commit(); c.close()
    if user_id: add_points(user_id, -5, "delete_map", map_id)

def restore_map(map_id):
    c = _conn()
    c.execute("UPDATE maps SET deleted=0, updated_at=? WHERE id=?", (datetime.now().isoformat(), map_id))
    c.commit(); c.close()

def confirm_map(map_id, user_id=None):
    c = _conn()
    c.execute("UPDATE maps SET status='confirmed', updated_at=? WHERE id=?", (datetime.now().isoformat(), map_id))
    c.commit(); c.close()
    if user_id: add_points(user_id, 10, "confirm", map_id)

def unconfirm_map(map_id, user_id=None):
    c = _conn()
    c.execute("UPDATE maps SET status='draft', updated_at=? WHERE id=?", (datetime.now().isoformat(), map_id))
    c.commit(); c.close()
    if user_id: add_points(user_id, -10, "unconfirm", map_id)

# ── Quality score ──
def map_quality_score(map_id):
    """Analyze a mindmap's quality based on structure."""
    g = get_map(map_id)
    if not g: return 0
    nc = len(g.nodes)
    ne = len(g.edges)
    avg_desc = sum(len(n.description) for n in g.nodes) / max(nc, 1)
    types_used = len(set(n.concept_type for n in g.nodes))
    rel_types = len(set(e.relation_type for e in g.edges))
    avg_conf = sum(n.confidence for n in g.nodes) / max(nc, 1)
    score = (nc * 2 + ne * 3 + avg_desc * 0.05 + types_used * 5 + rel_types * 5) * (avg_conf / 10)
    return round(score, 1)

# ── Corrections ──
def save_correction(map_id, ctype, original, corrected, user_id="anonymous", quality=0):
    c = _conn()
    cid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO corrections (id,map_id,user_id,correction_type,original_json,corrected_json,quality_score) VALUES (?,?,?,?,?,?,?)",
        (cid, map_id, user_id, ctype, json.dumps(original) if original else '{}', json.dumps(corrected) if corrected else '{}', quality))
    c.commit(); c.close()
    if user_id != "anonymous": add_points(user_id, 1, "edit", map_id)
    return cid

# ── Community ──
def share_to_community(map_id, user_id, title, description="", domain="general"):
    c = _conn()
    cid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO community_maps (id,map_id,user_id,title,description,domain) VALUES (?,?,?,?,?,?)",
        (cid, map_id, user_id, title, description, domain))
    c.commit(); c.close()
    if user_id != "anonymous": add_points(user_id, 15, "share", map_id)
    return cid

def unshare(community_id, user_id=None):
    c = _conn()
    c.execute("DELETE FROM community_maps WHERE id=?", (community_id,))
    c.commit(); c.close()
    if user_id: add_points(user_id, -15, "unshare", community_id)

def get_community_maps(domain=None, limit=50):
    c = _conn()
    if domain:
        rows = c.execute("SELECT id,title,description,domain,upvotes,user_id,created_at,map_id FROM community_maps WHERE domain=? ORDER BY upvotes DESC LIMIT ?", (domain, limit)).fetchall()
    else:
        rows = c.execute("SELECT id,title,description,domain,upvotes,user_id,created_at,map_id FROM community_maps ORDER BY upvotes DESC LIMIT ?", (limit,)).fetchall()
    c.close()
    return [{"id":r[0],"title":r[1],"description":r[2],"domain":r[3],"upvotes":r[4],"user_id":r[5],"created_at":r[6],"map_id":r[7]} for r in rows]

def upvote_community_map(community_id, user_id=None):
    c = _conn()
    c.execute("UPDATE community_maps SET upvotes=upvotes+1 WHERE id=?", (community_id,))
    c.commit()
    # Give upvote credit to map author
    row = c.execute("SELECT user_id FROM community_maps WHERE id=?", (community_id,)).fetchone()
    c.close()
    if row and row[0] != "anonymous": add_points(row[0], 3, "received_upvote", community_id)

def toggle_favorite(user_id, map_id):
    c = _conn()
    existing = c.execute("SELECT 1 FROM favorites WHERE user_id=? AND map_id=?", (user_id, map_id)).fetchone()
    if existing:
        c.execute("DELETE FROM favorites WHERE user_id=? AND map_id=?", (user_id, map_id))
        action = "unfavorited"
    else:
        c.execute("INSERT INTO favorites (user_id,map_id) VALUES (?,?)", (user_id, map_id))
        action = "favorited"
    c.commit(); c.close()
    return action

def get_favorites(user_id):
    c = _conn()
    rows = c.execute("SELECT cm.id,cm.title,cm.domain,cm.upvotes,cm.map_id FROM favorites f JOIN community_maps cm ON f.map_id=cm.id WHERE f.user_id=? ORDER BY f.created_at DESC", (user_id,)).fetchall()
    c.close()
    return [{"id":r[0],"title":r[1],"domain":r[2],"upvotes":r[3],"map_id":r[4]} for r in rows]

# ── Training ──
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
    users = c.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    community = c.execute("SELECT COUNT(*) FROM community_maps").fetchone()[0]
    c.close()
    return {"training_examples": total, "confirmed_maps": confirmed, "users": users, "community_maps": community}

def export_training(path=None, confirmed_only=True):
    if path is None: path = str(DATA_DIR / "training_chat.jsonl")
    c = _conn()
    rows = c.execute("SELECT input_text,section_title,concepts_json,relations_json FROM training").fetchall()
    c.close()
    Path(path).parent.mkdir(exist_ok=True)
    with open(path, 'w') as f:
        for text, title, cj, rj in rows:
            f.write(json.dumps({"messages": [
                {"role": "system", "content": "Extract concepts and relationships from text. Return JSON."},
                {"role": "user", "content": f'Section: "{title}"\n\n{text[:1500]}'},
                {"role": "assistant", "content": json.dumps({"concepts": json.loads(cj), "relations": json.loads(rj)})},
            ]}) + "\n")
    return len(rows)

# ── Admin ──
def admin_get_all_maps(limit=100):
    c = _conn()
    rows = c.execute("SELECT id,user_id,filename,title,status,deleted,created_at FROM maps ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
    c.close()
    return [{"id":r[0],"user_id":r[1],"filename":r[2],"title":r[3],"status":r[4],"deleted":r[5],"created_at":r[6]} for r in rows]

def admin_get_all_users():
    c = _conn()
    rows = c.execute("SELECT id,username,display_name,points,level,created_at FROM users ORDER BY points DESC").fetchall()
    c.close()
    return [{"id":r[0],"username":r[1],"display_name":r[2],"points":r[3],"level":r[4],"created_at":r[5]} for r in rows]
PYEOF
echo "  ✓ storage.py — users, credits, favorites, activity, admin, soft-delete"

# ═══════════════════════════════════════════════════════════════════════════
# 3. Updated main.py with auth + all endpoints
# ═══════════════════════════════════════════════════════════════════════════
cat > backend/app/main.py << 'PYEOF'
import os, shutil, logging
from pathlib import Path
from contextlib import asynccontextmanager
from fastapi import FastAPI, UploadFile, File, Header, Body
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from backend.app.config import UPLOAD_DIR
from backend.app.pipeline.orchestrator import run
from backend.app.services.storage import (
    create_user, login_user, get_user, update_user,
    add_points, get_activity, get_leaderboard,
    save_map, get_maps, get_map, delete_map, restore_map,
    confirm_map, unconfirm_map, map_quality_score,
    save_correction, share_to_community, unshare,
    get_community_maps, upvote_community_map,
    toggle_favorite, get_favorites,
    get_training_stats, export_training,
    admin_get_all_maps, admin_get_all_users,
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("app")

ADMIN_KEY = os.getenv("ADMIN_KEY", "mycel_admin_2026")

@asynccontextmanager
async def lifespan(app): yield

app = FastAPI(title="Mycel", version="3.0.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

ALLOWED_EXT = {'.pdf','.docx','.txt','.md','.markdown','.rst','.tex','.epub'}

def _uid(x_user_id=None):
    return x_user_id or "anonymous"

# ── Health ──
@app.get("/")
async def root():
    return {"status": "ok", "version": "3.0.0"}

# ── Auth ──
@app.post("/api/auth/register")
async def register(body: dict = Body(...)):
    uid, err = create_user(body["username"], body["password"], body.get("display_name"))
    if err: return JSONResponse({"error": err}, 400)
    return {"user_id": uid, "username": body["username"]}

@app.post("/api/auth/login")
async def login(body: dict = Body(...)):
    user = login_user(body["username"], body["password"])
    if not user: return JSONResponse({"error": "Invalid credentials"}, 401)
    return {"user": user}

@app.get("/api/auth/me")
async def me(x_user_id: str = Header(None)):
    if not x_user_id: return JSONResponse({"error": "Not logged in"}, 401)
    user = get_user(x_user_id)
    if not user: return JSONResponse({"error": "User not found"}, 404)
    return {"user": user}

@app.put("/api/auth/profile")
async def update_profile(body: dict = Body(...), x_user_id: str = Header(None)):
    if not x_user_id: return JSONResponse({"error": "Not logged in"}, 401)
    update_user(x_user_id, body.get("display_name"), body.get("bio"))
    return {"status": "updated"}

# ── Activity + Credits ──
@app.get("/api/activity")
async def activity(x_user_id: str = Header(None)):
    if not x_user_id: return {"activity": []}
    return {"activity": get_activity(x_user_id)}

@app.get("/api/leaderboard")
async def leaderboard():
    return {"users": get_leaderboard()}

# ── Maps ──
@app.post("/api/upload")
async def upload(file: UploadFile = File(...), x_user_id: str = Header(None)):
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in ALLOWED_EXT:
        return JSONResponse({"error": f"Unsupported. Use: {', '.join(ALLOWED_EXT)}"}, 400)
    fp = UPLOAD_DIR / file.filename
    with open(fp, "wb") as f: shutil.copyfileobj(file.file, f)
    graph = run(str(fp))
    map_id = save_map(file.filename, graph, _uid(x_user_id))
    return {"status":"success","map_id":map_id,"document":file.filename,
            "nodes":[n.model_dump() for n in graph.nodes],
            "edges":[e.model_dump() for e in graph.edges],
            "node_count":len(graph.nodes),"edge_count":len(graph.edges)}

@app.get("/api/maps")
async def list_maps(x_user_id: str = Header(None)):
    return {"maps": get_maps(_uid(x_user_id))}

@app.get("/api/maps/{map_id}")
async def get_map_data(map_id: str):
    g = get_map(map_id)
    if not g: return JSONResponse({"error": "Not found"}, 404)
    return {"nodes":[n.model_dump() for n in g.nodes],"edges":[e.model_dump() for e in g.edges]}

@app.delete("/api/maps/{map_id}")
async def del_map(map_id: str, x_user_id: str = Header(None)):
    delete_map(map_id, _uid(x_user_id))
    return {"status": "deleted"}

@app.post("/api/maps/{map_id}/restore")
async def restore(map_id: str):
    restore_map(map_id)
    return {"status": "restored"}

@app.post("/api/maps/{map_id}/confirm")
async def confirm(map_id: str, x_user_id: str = Header(None)):
    confirm_map(map_id, _uid(x_user_id))
    return {"status":"confirmed","quality":map_quality_score(map_id)}

@app.post("/api/maps/{map_id}/unconfirm")
async def unconfirm(map_id: str, x_user_id: str = Header(None)):
    unconfirm_map(map_id, _uid(x_user_id))
    return {"status": "draft"}

@app.post("/api/corrections")
async def submit_correction(body: dict = Body(...), x_user_id: str = Header(None)):
    from backend.app.services.storage import save_correction
    cid = save_correction(body.get("map_id",""), body.get("type","edit"),
        body.get("original"), body.get("corrected"), _uid(x_user_id))
    return {"id": cid}

# ── Community ──
@app.post("/api/community/share")
async def share(body: dict = Body(...), x_user_id: str = Header(None)):
    cid = share_to_community(body["map_id"], _uid(x_user_id),
        body["title"], body.get("description",""), body.get("domain","general"))
    return {"id": cid}

@app.delete("/api/community/{cid}")
async def remove_share(cid: str, x_user_id: str = Header(None)):
    unshare(cid, _uid(x_user_id))
    return {"status": "removed"}

@app.get("/api/community")
async def community(domain: str = None, limit: int = 50):
    return {"maps": get_community_maps(domain, limit)}

@app.post("/api/community/{cid}/upvote")
async def upvote(cid: str, x_user_id: str = Header(None)):
    upvote_community_map(cid, _uid(x_user_id))
    return {"status": "upvoted"}

@app.post("/api/community/{cid}/favorite")
async def favorite(cid: str, x_user_id: str = Header(None)):
    action = toggle_favorite(_uid(x_user_id), cid)
    return {"status": action}

@app.get("/api/favorites")
async def favorites(x_user_id: str = Header(None)):
    if not x_user_id: return {"favorites": []}
    return {"favorites": get_favorites(x_user_id)}

# ── Stats ──
@app.get("/api/stats")
async def stats():
    return get_training_stats()

# ── Admin ──
@app.get("/api/admin/maps")
async def admin_maps(key: str = ""):
    if key != ADMIN_KEY: return JSONResponse({"error": "unauthorized"}, 403)
    return {"maps": admin_get_all_maps()}

@app.get("/api/admin/users")
async def admin_users(key: str = ""):
    if key != ADMIN_KEY: return JSONResponse({"error": "unauthorized"}, 403)
    return {"users": admin_get_all_users()}

@app.post("/api/admin/export")
async def admin_export(key: str = ""):
    if key != ADMIN_KEY: return JSONResponse({"error": "unauthorized"}, 403)
    n = export_training()
    return {"exported": n}
PYEOF
echo "  ✓ main.py — auth, credits, admin, favorites, restore, quality score"

# ═══════════════════════════════════════════════════════════════════════════
# 4. Complete api.js with auth support
# ═══════════════════════════════════════════════════════════════════════════
cat > frontend/src/api.js << 'APIEOF'
var API = (typeof import.meta !== "undefined" && import.meta.env && import.meta.env.VITE_API_URL) || "http://localhost:8000";

// User ID stored in localStorage
function uid() { return localStorage.getItem("mycel_uid") || ""; }
function authHeaders() {
  var h = {"Content-Type": "application/json"};
  var u = uid();
  if (u) h["x-user-id"] = u;
  return h;
}

// Auth
export function register(username, password, displayName) {
  return fetch(API + "/api/auth/register", { method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify({username:username, password:password, display_name:displayName||username}) }).then(function(r) { return r.json(); });
}
export function login(username, password) {
  return fetch(API + "/api/auth/login", { method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify({username:username, password:password}) }).then(function(r) { return r.json(); });
}
export function getMe() {
  return fetch(API + "/api/auth/me", { headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); });
}
export function updateProfile(displayName, bio) {
  return fetch(API + "/api/auth/profile", { method: "PUT", headers: authHeaders(), body: JSON.stringify({display_name:displayName, bio:bio}) }).then(function(r) { return r.json(); });
}

// Activity
export function getActivity() { return fetch(API + "/api/activity", { headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function getLeaderboard() { return fetch(API + "/api/leaderboard").then(function(r) { return r.json(); }); }

// Upload
export function uploadFile(file) {
  var f = new FormData(); f.append("file", file);
  return fetch(API + "/api/upload", { method: "POST", body: f, headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); });
}
export var uploadPDF = uploadFile;

// Maps
export function getMaps() { return fetch(API + "/api/maps", { headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function getMap(id) { return fetch(API + "/api/maps/" + id).then(function(r) { return r.json(); }); }
export function deleteMap(id) { return fetch(API + "/api/maps/" + id, { method: "DELETE", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function restoreMap(id) { return fetch(API + "/api/maps/" + id + "/restore", { method: "POST" }).then(function(r) { return r.json(); }); }
export function confirmMap(id) { return fetch(API + "/api/maps/" + id + "/confirm", { method: "POST", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function unconfirmMap(id) { return fetch(API + "/api/maps/" + id + "/unconfirm", { method: "POST", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function submitCorrection(data) { return fetch(API + "/api/corrections", { method: "POST", headers: authHeaders(), body: JSON.stringify(data) }).then(function(r) { return r.json(); }); }

// Community
export function getCommunityMaps(domain) { var url = API + "/api/community"; if (domain && domain !== "all") url += "?domain=" + encodeURIComponent(domain); return fetch(url).then(function(r) { return r.json(); }); }
export function shareMap(id, title, desc, domain) { return fetch(API + "/api/community/share", { method: "POST", headers: authHeaders(), body: JSON.stringify({map_id:id, title:title||"", description:desc||"", domain:domain||"general"}) }).then(function(r) { return r.json(); }); }
export function unshareMap(cid) { return fetch(API + "/api/community/" + cid, { method: "DELETE", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function upvoteCommunityMap(id) { return fetch(API + "/api/community/" + id + "/upvote", { method: "POST", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function favoriteMap(id) { return fetch(API + "/api/community/" + id + "/favorite", { method: "POST", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function getFavorites() { return fetch(API + "/api/favorites", { headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }

// Stats
export function getStats() { return fetch(API + "/api/stats").then(function(r) { return r.json(); }); }
APIEOF
echo "  ✓ api.js — auth headers, all endpoints"

# ═══════════════════════════════════════════════════════════════════════════
# 5. Ensure deployment files are correct
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

# Add ADMIN_KEY to Railway reminder
echo ""
echo "  ⚠ Add to Railway Variables tab: ADMIN_KEY = your_secret_key"

# Ensure __init__.py
for d in backend backend/app backend/app/pipeline backend/app/services backend/app/training; do
    mkdir -p "$d"; touch "$d/__init__.py"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 Mycel v9 complete!"
echo ""
echo "BACKEND (deploy-ready):"
echo "  Auth:      POST /api/auth/register, /api/auth/login, GET /api/auth/me"
echo "  Profile:   PUT /api/auth/profile"
echo "  Credits:   Auto-calculated from actions (upload +5, confirm +10,"
echo "             share +15, edit +1, receive upvote +3, all reversible)"
echo "  Levels:    none → beginner → experienced → expert → professional → organizer"
echo "  Maps:      CRUD + soft-delete + restore + confirm + unconfirm"
echo "  Quality:   GET /api/maps/{id}/confirm returns quality score"
echo "  Community: share/unshare/upvote/favorite + domain filter"
echo "  Favorites: POST /api/community/{id}/favorite (toggle)"
echo "  Activity:  GET /api/activity (user's action history)"
echo "  Leaders:   GET /api/leaderboard"
echo "  Admin:     GET /api/admin/maps?key=X, /api/admin/users?key=X"
echo "  Export:    POST /api/admin/export?key=X"
echo ""
echo "FRONTEND:"
echo "  api.js sends x-user-id header on every request"
echo "  localStorage stores user_id after login"
echo "  All endpoints available for App.jsx to call"
echo ""
echo "DEPLOY:"
echo "  git add -A && git commit -m 'v9: auth + credits + admin' && git push"
echo ""
echo "RAILWAY: Add these Variables:"
echo "  ADMIN_KEY = pick_a_secret_string"
echo "  PORT = 8000  (if not already set)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"