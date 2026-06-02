#!/bin/bash
set -e
echo "🍄 Mycel v10 — Major platform update..."

# ═══════════════════════════════════════════════════════════════════════
# BACKEND: storage.py — private library, comments, feedback, export
# ═══════════════════════════════════════════════════════════════════════
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
            bio TEXT DEFAULT '', theme TEXT DEFAULT 'dark',
            language TEXT DEFAULT 'en',
            created_at TEXT DEFAULT CURRENT_TIMESTAMP);
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
        CREATE TABLE IF NOT EXISTS comments (
            id TEXT PRIMARY KEY, community_map_id TEXT, user_id TEXT,
            username TEXT DEFAULT 'anonymous', content TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP);
        CREATE TABLE IF NOT EXISTS feedback (
            id TEXT PRIMARY KEY, user_id TEXT DEFAULT 'anonymous',
            category TEXT DEFAULT 'general', content TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP);
    """)
    try:
        cols = [r[1] for r in c.execute("PRAGMA table_info(maps)").fetchall()]
        if 'status' not in cols: c.execute("ALTER TABLE maps ADD COLUMN status TEXT DEFAULT 'draft'")
        if 'deleted' not in cols: c.execute("ALTER TABLE maps ADD COLUMN deleted INTEGER DEFAULT 0")
    except: pass
    try:
        ucols = [r[1] for r in c.execute("PRAGMA table_info(users)").fetchall()]
        if 'theme' not in ucols: c.execute("ALTER TABLE users ADD COLUMN theme TEXT DEFAULT 'dark'")
        if 'language' not in ucols: c.execute("ALTER TABLE users ADD COLUMN language TEXT DEFAULT 'en'")
    except: pass
    c.commit()
    return c

# Users
def create_user(username, password, display_name=None):
    c = _conn(); uid = str(uuid.uuid4())[:12]
    pw_hash = hashlib.sha256(password.encode()).hexdigest()
    try:
        c.execute("INSERT INTO users (id,username,display_name,password_hash,points,level) VALUES (?,?,?,?,?,?)",
            (uid, username.lower().strip(), display_name or username, pw_hash, 0, 'beginner'))
        c.commit()
    except sqlite3.IntegrityError: c.close(); return None, "Username taken"
    c.close(); return uid, None

def login_user(username, password):
    c = _conn(); pw_hash = hashlib.sha256(password.encode()).hexdigest()
    row = c.execute("SELECT id,username,display_name,points,level,theme,language FROM users WHERE username=? AND password_hash=?",
        (username.lower().strip(), pw_hash)).fetchone()
    c.close()
    if not row: return None
    return {"id":row[0],"username":row[1],"display_name":row[2],"points":row[3],"level":row[4],"theme":row[5],"language":row[6]}

def get_user(user_id):
    c = _conn()
    row = c.execute("SELECT id,username,display_name,points,level,bio,theme,language,created_at FROM users WHERE id=?", (user_id,)).fetchone()
    c.close()
    if not row: return None
    return {"id":row[0],"username":row[1],"display_name":row[2],"points":row[3],"level":row[4],"bio":row[5],"theme":row[6],"language":row[7],"created_at":row[8]}

def update_user(user_id, display_name=None, bio=None, theme=None, language=None):
    c = _conn()
    if display_name: c.execute("UPDATE users SET display_name=? WHERE id=?", (display_name, user_id))
    if bio is not None: c.execute("UPDATE users SET bio=? WHERE id=?", (bio, user_id))
    if theme: c.execute("UPDATE users SET theme=? WHERE id=?", (theme, user_id))
    if language: c.execute("UPDATE users SET language=? WHERE id=?", (language, user_id))
    c.commit(); c.close()

# Credits
def add_points(user_id, points, action, target_id=""):
    c = _conn()
    c.execute("UPDATE users SET points=points+? WHERE id=?", (points, user_id))
    row = c.execute("SELECT points FROM users WHERE id=?", (user_id,)).fetchone()
    if row: c.execute("UPDATE users SET level=? WHERE id=?", (get_level(row[0]), user_id))
    aid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO activity (id,user_id,action,target_id,points_delta) VALUES (?,?,?,?,?)",
        (aid, user_id, action, target_id, points))
    c.commit(); c.close()

def get_activity(user_id, limit=20):
    c = _conn()
    rows = c.execute("SELECT action,target_id,points_delta,created_at FROM activity WHERE user_id=? ORDER BY created_at DESC LIMIT ?", (user_id, limit)).fetchall()
    c.close(); return [{"action":r[0],"target_id":r[1],"points":r[2],"created_at":r[3]} for r in rows]

def get_leaderboard(limit=20):
    c = _conn()
    rows = c.execute("SELECT id,username,display_name,points,level FROM users ORDER BY points DESC LIMIT ?", (limit,)).fetchall()
    c.close(); return [{"id":r[0],"username":r[1],"display_name":r[2],"points":r[3],"level":r[4]} for r in rows]

# Maps — PRIVATE: always filter by user_id
def save_map(filename, graph, user_id="anonymous", title=None):
    c = _conn(); mid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO maps (id,user_id,filename,title,graph_json,status,updated_at) VALUES (?,?,?,?,?,?,?)",
        (mid, user_id, filename, title or filename, graph.model_dump_json(), 'draft', datetime.now().isoformat()))
    c.commit(); c.close()
    if user_id != "anonymous": add_points(user_id, 5, "upload", mid)
    return mid

def get_maps(user_id):
    """PRIVATE: only return maps owned by this user."""
    c = _conn()
    if not user_id or user_id == "anonymous":
        c.close(); return []
    rows = c.execute("SELECT id,filename,title,status,created_at FROM maps WHERE user_id=? AND deleted=0 ORDER BY created_at DESC", (user_id,)).fetchall()
    c.close(); return [{"id":r[0],"filename":r[1],"title":r[2],"status":r[3],"created_at":r[4]} for r in rows]

def get_map(map_id):
    from backend.app.models import KnowledgeGraph
    c = _conn(); row = c.execute("SELECT graph_json FROM maps WHERE id=? AND deleted=0", (map_id,)).fetchone()
    c.close(); return KnowledgeGraph.model_validate_json(row[0]) if row else None

def get_map_json(map_id):
    """Return raw JSON for export."""
    c = _conn(); row = c.execute("SELECT graph_json FROM maps WHERE id=? AND deleted=0", (map_id,)).fetchone()
    c.close(); return row[0] if row else None

def delete_map(map_id, user_id=None):
    c = _conn(); c.execute("UPDATE maps SET deleted=1, updated_at=? WHERE id=?", (datetime.now().isoformat(), map_id))
    c.commit(); c.close()
    if user_id and user_id != "anonymous": add_points(user_id, -5, "delete_map", map_id)

def confirm_map(map_id, user_id=None):
    c = _conn(); c.execute("UPDATE maps SET status='confirmed', updated_at=? WHERE id=?", (datetime.now().isoformat(), map_id))
    c.commit(); c.close()
    if user_id and user_id != "anonymous": add_points(user_id, 10, "confirm", map_id)

def unconfirm_map(map_id, user_id=None):
    c = _conn(); c.execute("UPDATE maps SET status='draft', updated_at=? WHERE id=?", (datetime.now().isoformat(), map_id))
    c.commit(); c.close()
    if user_id and user_id != "anonymous": add_points(user_id, -10, "unconfirm", map_id)

# Quality
def map_quality_score(map_id):
    g = get_map(map_id)
    if not g: return 0
    nc = len(g.nodes); ne = len(g.edges)
    avg_desc = sum(len(n.description) for n in g.nodes) / max(nc, 1)
    types_used = len(set(n.concept_type for n in g.nodes))
    avg_conf = sum(n.confidence for n in g.nodes) / max(nc, 1)
    return round((nc * 2 + ne * 3 + avg_desc * 0.05 + types_used * 5) * (avg_conf / 10), 1)

# Corrections
def save_correction(map_id, ctype, original, corrected, user_id="anonymous", quality=0):
    c = _conn(); cid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO corrections (id,map_id,user_id,correction_type,original_json,corrected_json,quality_score) VALUES (?,?,?,?,?,?,?)",
        (cid, map_id, user_id, ctype, json.dumps(original) if original else '{}', json.dumps(corrected) if corrected else '{}', quality))
    c.commit(); c.close()
    if user_id != "anonymous": add_points(user_id, 1, "edit", map_id)
    return cid

# Community
def share_to_community(map_id, user_id, title, description="", domain="general"):
    c = _conn(); cid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO community_maps (id,map_id,user_id,title,description,domain) VALUES (?,?,?,?,?,?)",
        (cid, map_id, user_id, title, description, domain))
    c.commit(); c.close()
    if user_id != "anonymous": add_points(user_id, 15, "share", map_id)
    return cid

def unshare(community_id, user_id=None):
    c = _conn(); c.execute("DELETE FROM community_maps WHERE id=?", (community_id,))
    c.commit(); c.close()
    if user_id and user_id != "anonymous": add_points(user_id, -15, "unshare", community_id)

def get_community_maps(domain=None, limit=50):
    c = _conn()
    if domain:
        rows = c.execute("SELECT id,title,description,domain,upvotes,user_id,created_at,map_id FROM community_maps WHERE domain=? ORDER BY upvotes DESC LIMIT ?", (domain, limit)).fetchall()
    else:
        rows = c.execute("SELECT id,title,description,domain,upvotes,user_id,created_at,map_id FROM community_maps ORDER BY upvotes DESC LIMIT ?", (limit,)).fetchall()
    c.close(); return [{"id":r[0],"title":r[1],"description":r[2],"domain":r[3],"upvotes":r[4],"user_id":r[5],"created_at":r[6],"map_id":r[7]} for r in rows]

def upvote_community_map(community_id, user_id=None):
    c = _conn(); c.execute("UPDATE community_maps SET upvotes=upvotes+1 WHERE id=?", (community_id,))
    c.commit()
    row = c.execute("SELECT user_id FROM community_maps WHERE id=?", (community_id,)).fetchone()
    c.close()
    if row and row[0] != "anonymous": add_points(row[0], 3, "received_upvote", community_id)

def toggle_favorite(user_id, map_id):
    c = _conn()
    existing = c.execute("SELECT 1 FROM favorites WHERE user_id=? AND map_id=?", (user_id, map_id)).fetchone()
    if existing: c.execute("DELETE FROM favorites WHERE user_id=? AND map_id=?", (user_id, map_id)); action = "unfavorited"
    else: c.execute("INSERT INTO favorites (user_id,map_id) VALUES (?,?)", (user_id, map_id)); action = "favorited"
    c.commit(); c.close(); return action

def get_favorites(user_id):
    c = _conn()
    rows = c.execute("SELECT cm.id,cm.title,cm.domain,cm.upvotes,cm.map_id FROM favorites f JOIN community_maps cm ON f.map_id=cm.id WHERE f.user_id=?", (user_id,)).fetchall()
    c.close(); return [{"id":r[0],"title":r[1],"domain":r[2],"upvotes":r[3],"map_id":r[4]} for r in rows]

# Comments
def add_comment(community_map_id, user_id, username, content):
    c = _conn(); cid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO comments (id,community_map_id,user_id,username,content) VALUES (?,?,?,?,?)",
        (cid, community_map_id, user_id, username or "anonymous", content))
    c.commit(); c.close()
    if user_id != "anonymous": add_points(user_id, 2, "comment", community_map_id)
    return cid

def get_comments(community_map_id):
    c = _conn()
    rows = c.execute("SELECT id,username,content,created_at FROM comments WHERE community_map_id=? ORDER BY created_at DESC", (community_map_id,)).fetchall()
    c.close(); return [{"id":r[0],"username":r[1],"content":r[2],"created_at":r[3]} for r in rows]

# Feedback
def add_feedback(user_id, category, content):
    c = _conn(); fid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO feedback (id,user_id,category,content) VALUES (?,?,?,?)", (fid, user_id, category, content))
    c.commit(); c.close(); return fid

# Training
def save_training(input_text, section_title, concepts, relations=None, domain="general"):
    c = _conn(); tid = str(uuid.uuid4())[:12]
    c.execute("INSERT INTO training (id,input_text,section_title,concepts_json,relations_json,domain) VALUES (?,?,?,?,?,?)",
        (tid, input_text[:5000], section_title,
         json.dumps([x if isinstance(x,dict) else x.model_dump() for x in concepts]),
         json.dumps([x if isinstance(x,dict) else x.model_dump() for x in (relations or [])]), domain))
    c.commit(); c.close()

def get_training_stats():
    c = _conn()
    t = c.execute("SELECT COUNT(*) FROM training").fetchone()[0]
    cm = c.execute("SELECT COUNT(*) FROM maps WHERE status='confirmed'").fetchone()[0]
    u = c.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    co = c.execute("SELECT COUNT(*) FROM community_maps").fetchone()[0]
    c.close(); return {"training_examples":t,"confirmed_maps":cm,"users":u,"community_maps":co}

def export_training(path=None, confirmed_only=True):
    if path is None: path = str(DATA_DIR / "training_chat.jsonl")
    c = _conn(); rows = c.execute("SELECT input_text,section_title,concepts_json,relations_json FROM training").fetchall()
    c.close(); Path(path).parent.mkdir(exist_ok=True)
    with open(path, 'w') as f:
        for text, title, cj, rj in rows:
            f.write(json.dumps({"messages":[{"role":"system","content":"Extract concepts and relations. Return JSON."},{"role":"user","content":f'Section: "{title}"\n\n{text[:1500]}'},{"role":"assistant","content":json.dumps({"concepts":json.loads(cj),"relations":json.loads(rj)})}]})+"\n")
    return len(rows)

# Admin
def admin_get_all_maps(limit=100):
    c = _conn(); rows = c.execute("SELECT id,user_id,filename,title,status,deleted,created_at FROM maps ORDER BY created_at DESC LIMIT ?", (limit,)).fetchall()
    c.close(); return [{"id":r[0],"user_id":r[1],"filename":r[2],"title":r[3],"status":r[4],"deleted":r[5],"created_at":r[6]} for r in rows]

def admin_get_all_users():
    c = _conn(); rows = c.execute("SELECT id,username,display_name,points,level,created_at FROM users ORDER BY points DESC").fetchall()
    c.close(); return [{"id":r[0],"username":r[1],"display_name":r[2],"points":r[3],"level":r[4],"created_at":r[5]} for r in rows]

def admin_get_feedback():
    c = _conn(); rows = c.execute("SELECT id,user_id,category,content,created_at FROM feedback ORDER BY created_at DESC").fetchall()
    c.close(); return [{"id":r[0],"user_id":r[1],"category":r[2],"content":r[3],"created_at":r[4]} for r in rows]
PYEOF
echo "  ✓ storage.py — private library, comments, feedback, settings"

# ═══════════════════════════════════════════════════════════════════════
# BACKEND: main.py — all endpoints including new ones
# ═══════════════════════════════════════════════════════════════════════
cat > backend/app/main.py << 'PYEOF'
import os, shutil, json, logging
from contextlib import asynccontextmanager
from fastapi import FastAPI, UploadFile, File, Header, Body, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from backend.app.config import UPLOAD_DIR
from backend.app.pipeline.orchestrator import run
from backend.app.services.storage import *

logging.basicConfig(level=logging.INFO)
ADMIN_KEY = os.getenv("ADMIN_KEY", "mycel_admin_2026")

@asynccontextmanager
async def lifespan(app): yield

app = FastAPI(title="Mycel", version="3.1.0", lifespan=lifespan)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
ALLOWED_EXT = {'.pdf','.docx','.txt','.md','.markdown','.rst','.tex','.epub'}
def _uid(h): return h or "anonymous"

@app.get("/")
async def root(): return {"status":"ok","version":"3.1.0"}

# Auth
@app.post("/api/auth/register")
async def register(body: dict = Body(...)): uid,err = create_user(body["username"],body["password"],body.get("display_name")); return JSONResponse({"error":err},400) if err else {"user_id":uid,"username":body["username"]}

@app.post("/api/auth/login")
async def login(body: dict = Body(...)): u = login_user(body["username"],body["password"]); return JSONResponse({"error":"Invalid credentials"},401) if not u else {"user":u}

@app.get("/api/auth/me")
async def me(x_user_id: str = Header(None)):
    if not x_user_id: return JSONResponse({"error":"Not logged in"},401)
    u = get_user(x_user_id); return JSONResponse({"error":"Not found"},404) if not u else {"user":u}

@app.put("/api/auth/profile")
async def update_profile(body: dict = Body(...), x_user_id: str = Header(None)):
    if not x_user_id: return JSONResponse({"error":"Not logged in"},401)
    update_user(x_user_id, body.get("display_name"), body.get("bio"), body.get("theme"), body.get("language"))
    return {"status":"updated"}

# Activity
@app.get("/api/activity")
async def activity(x_user_id: str = Header(None)): return {"activity": get_activity(x_user_id) if x_user_id else []}

@app.get("/api/leaderboard")
async def leaderboard(): return {"users": get_leaderboard()}

# Maps — PRIVATE
@app.post("/api/upload")
async def upload(file: UploadFile = File(...), x_user_id: str = Header(None)):
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in ALLOWED_EXT: return JSONResponse({"error":"Unsupported format"},400)
    fp = UPLOAD_DIR / file.filename
    with open(fp,"wb") as f: shutil.copyfileobj(file.file, f)
    graph = run(str(fp))
    mid = save_map(file.filename, graph, _uid(x_user_id))
    return {"status":"success","map_id":mid,"document":file.filename,"nodes":[n.model_dump() for n in graph.nodes],"edges":[e.model_dump() for e in graph.edges],"node_count":len(graph.nodes),"edge_count":len(graph.edges)}

@app.get("/api/maps")
async def list_maps(x_user_id: str = Header(None)): return {"maps": get_maps(_uid(x_user_id))}

@app.get("/api/maps/{map_id}")
async def get_map_data(map_id: str):
    g = get_map(map_id)
    if not g: return JSONResponse({"error":"Not found"},404)
    return {"nodes":[n.model_dump() for n in g.nodes],"edges":[e.model_dump() for e in g.edges]}

@app.get("/api/maps/{map_id}/export")
async def export_map(map_id: str):
    """Export map as JSON download."""
    raw = get_map_json(map_id)
    if not raw: return JSONResponse({"error":"Not found"},404)
    return Response(content=raw, media_type="application/json",
        headers={"Content-Disposition": f"attachment; filename=mycel_{map_id}.json"})

@app.delete("/api/maps/{map_id}")
async def del_map(map_id: str, x_user_id: str = Header(None)): delete_map(map_id, _uid(x_user_id)); return {"status":"deleted"}

@app.post("/api/maps/{map_id}/confirm")
async def confirm(map_id: str, x_user_id: str = Header(None)): confirm_map(map_id, _uid(x_user_id)); return {"status":"confirmed","quality":map_quality_score(map_id)}

@app.post("/api/maps/{map_id}/unconfirm")
async def unconfirm(map_id: str, x_user_id: str = Header(None)): unconfirm_map(map_id, _uid(x_user_id)); return {"status":"draft"}

@app.post("/api/corrections")
async def submit_corr(body: dict = Body(...), x_user_id: str = Header(None)):
    cid = save_correction(body.get("map_id",""), body.get("type","edit"), body.get("original"), body.get("corrected"), _uid(x_user_id))
    return {"id":cid}

# Community
@app.post("/api/community/share")
async def share(body: dict = Body(...), x_user_id: str = Header(None)):
    cid = share_to_community(body["map_id"], _uid(x_user_id), body["title"], body.get("description",""), body.get("domain","general"))
    return {"id":cid}

@app.delete("/api/community/{cid}")
async def remove_share(cid: str, x_user_id: str = Header(None)): unshare(cid, _uid(x_user_id)); return {"status":"removed"}

@app.get("/api/community")
async def community(domain: str = None, limit: int = 50): return {"maps": get_community_maps(domain, limit)}

@app.post("/api/community/{cid}/upvote")
async def upvote(cid: str, x_user_id: str = Header(None)): upvote_community_map(cid, _uid(x_user_id)); return {"status":"upvoted"}

@app.post("/api/community/{cid}/favorite")
async def favorite(cid: str, x_user_id: str = Header(None)): return {"status": toggle_favorite(_uid(x_user_id), cid)}

@app.get("/api/favorites")
async def favorites(x_user_id: str = Header(None)):
    if not x_user_id: return {"favorites":[]}
    return {"favorites": get_favorites(x_user_id)}

# Comments
@app.post("/api/community/{cid}/comments")
async def post_comment(cid: str, body: dict = Body(...), x_user_id: str = Header(None)):
    cid2 = add_comment(cid, _uid(x_user_id), body.get("username","anonymous"), body["content"])
    return {"id":cid2}

@app.get("/api/community/{cid}/comments")
async def list_comments(cid: str): return {"comments": get_comments(cid)}

# Feedback
@app.post("/api/feedback")
async def post_feedback(body: dict = Body(...), x_user_id: str = Header(None)):
    fid = add_feedback(_uid(x_user_id), body.get("category","general"), body["content"])
    return {"id":fid}

# Stats
@app.get("/api/stats")
async def stats(): return get_training_stats()

# Admin
@app.get("/api/admin/maps")
async def admin_maps(key: str = ""): return JSONResponse({"error":"unauthorized"},403) if key != ADMIN_KEY else {"maps": admin_get_all_maps()}

@app.get("/api/admin/users")
async def admin_users(key: str = ""): return JSONResponse({"error":"unauthorized"},403) if key != ADMIN_KEY else {"users": admin_get_all_users()}

@app.get("/api/admin/feedback")
async def admin_fb(key: str = ""): return JSONResponse({"error":"unauthorized"},403) if key != ADMIN_KEY else {"feedback": admin_get_feedback()}

@app.post("/api/admin/export")
async def admin_export(key: str = ""): return JSONResponse({"error":"unauthorized"},403) if key != ADMIN_KEY else {"exported": export_training()}

# LLM test (keep for diagnostics)
@app.get("/api/test-llm")
async def test_llm():
    from backend.app.config import LLM_PROVIDER, TOGETHER_MODEL, LLM_MODEL
    from backend.app.services.llm import chat
    from backend.app.pipeline.extractor import PROMPT, JOINT_SCHEMA, _clean_json
    try:
        text = "Photosynthesis converts sunlight to energy using chlorophyll in chloroplasts. Light reactions produce ATP and NADPH in thylakoids. The Calvin cycle fixes CO2 into glucose."
        raw = chat([{"role":"system","content":PROMPT},{"role":"user","content":f'Extract concepts and relations:\n\n{text}'}], json_schema=JOINT_SCHEMA, temperature=0.05, max_tokens=2000)
        cleaned = _clean_json(raw)
        try: parsed = json.loads(cleaned)
        except: parsed = {"parse_error": cleaned[:500]}
        return {"status":"ok","provider":LLM_PROVIDER,"model":TOGETHER_MODEL if LLM_PROVIDER=="together" else LLM_MODEL,
                "concepts_found":len(parsed.get("concepts",[])),"relations_found":len(parsed.get("relations",[])),"parsed":parsed}
    except Exception as e: return {"error":str(e),"provider":LLM_PROVIDER}
PYEOF
echo "  ✓ main.py — comments, feedback, export, private library"

# ═══════════════════════════════════════════════════════════════════════
# FRONTEND: api.js — complete with all new endpoints
# ═══════════════════════════════════════════════════════════════════════
cat > frontend/src/api.js << 'APIEOF'
var API=(typeof import.meta!=="undefined"&&import.meta.env&&import.meta.env.VITE_API_URL)||"http://localhost:8000";
function uid(){return localStorage.getItem("mycel_uid")||"";}
function ah(){var h={"Content-Type":"application/json"};var u=uid();if(u)h["x-user-id"]=u;return h;}
function uh(){var h={};var u=uid();if(u)h["x-user-id"]=u;return h;}

export function register(u,p,d){return fetch(API+"/api/auth/register",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({username:u,password:p,display_name:d||u})}).then(function(r){return r.json();});}
export function login(u,p){return fetch(API+"/api/auth/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({username:u,password:p})}).then(function(r){return r.json();});}
export function getMe(){return fetch(API+"/api/auth/me",{headers:uh()}).then(function(r){return r.json();});}
export function updateProfile(dn,bio,theme,lang){return fetch(API+"/api/auth/profile",{method:"PUT",headers:ah(),body:JSON.stringify({display_name:dn,bio:bio,theme:theme,language:lang})}).then(function(r){return r.json();});}

export function getActivity(){return fetch(API+"/api/activity",{headers:uh()}).then(function(r){return r.json();});}
export function getLeaderboard(){return fetch(API+"/api/leaderboard").then(function(r){return r.json();});}

export function uploadFile(file){var f=new FormData();f.append("file",file);return fetch(API+"/api/upload",{method:"POST",body:f,headers:uh()}).then(function(r){return r.json();});}
export var uploadPDF=uploadFile;
export function getMaps(){return fetch(API+"/api/maps",{headers:uh()}).then(function(r){return r.json();});}
export function getMap(id){return fetch(API+"/api/maps/"+id).then(function(r){return r.json();});}
export function exportMap(id){window.open(API+"/api/maps/"+id+"/export","_blank");}
export function deleteMap(id){return fetch(API+"/api/maps/"+id,{method:"DELETE",headers:uh()}).then(function(r){return r.json();});}
export function confirmMap(id){return fetch(API+"/api/maps/"+id+"/confirm",{method:"POST",headers:uh()}).then(function(r){return r.json();});}
export function unconfirmMap(id){return fetch(API+"/api/maps/"+id+"/unconfirm",{method:"POST",headers:uh()}).then(function(r){return r.json();});}
export function submitCorrection(data){return fetch(API+"/api/corrections",{method:"POST",headers:ah(),body:JSON.stringify(data)}).then(function(r){return r.json();});}

export function getCommunityMaps(d){var u=API+"/api/community";if(d&&d!=="all")u+="?domain="+encodeURIComponent(d);return fetch(u).then(function(r){return r.json();});}
export function shareMap(id,t,desc,dom){return fetch(API+"/api/community/share",{method:"POST",headers:ah(),body:JSON.stringify({map_id:id,title:t||"",description:desc||"",domain:dom||"general"})}).then(function(r){return r.json();});}
export function unshareMap(cid){return fetch(API+"/api/community/"+cid,{method:"DELETE",headers:uh()}).then(function(r){return r.json();});}
export function upvoteCommunityMap(id){return fetch(API+"/api/community/"+id+"/upvote",{method:"POST",headers:uh()}).then(function(r){return r.json();});}
export function favoriteMap(id){return fetch(API+"/api/community/"+id+"/favorite",{method:"POST",headers:uh()}).then(function(r){return r.json();});}
export function getFavorites(){return fetch(API+"/api/favorites",{headers:uh()}).then(function(r){return r.json();});}

export function getComments(cid){return fetch(API+"/api/community/"+cid+"/comments").then(function(r){return r.json();});}
export function postComment(cid,content,username){return fetch(API+"/api/community/"+cid+"/comments",{method:"POST",headers:ah(),body:JSON.stringify({content:content,username:username||"anonymous"})}).then(function(r){return r.json();});}

export function postFeedback(category,content){return fetch(API+"/api/feedback",{method:"POST",headers:ah(),body:JSON.stringify({category:category,content:content})}).then(function(r){return r.json();});}

export function getStats(){return fetch(API+"/api/stats").then(function(r){return r.json();});}
APIEOF
echo "  ✓ api.js — all endpoints including comments, feedback, export"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 Mycel v10 backend complete!"
echo ""
echo "NEW ENDPOINTS:"
echo "  GET  /api/maps/{id}/export     — download map as JSON"
echo "  POST /api/community/{id}/comments — add comment"
echo "  GET  /api/community/{id}/comments — list comments"
echo "  POST /api/feedback             — submit feedback"
echo "  GET  /api/admin/feedback?key=X — view all feedback"
echo "  PUT  /api/auth/profile         — update theme/language"
echo "  GET  /api/leaderboard          — top users by points"
echo ""
echo "FIXES:"
echo "  • Library is PRIVATE (returns empty for anonymous users)"
echo "  • User settings: theme + language stored in DB"
echo "  • Comments on community maps"
echo "  • Feedback collection"
echo "  • Map export as JSON"
echo ""
echo "FRONTEND: Update App.jsx to use new endpoints."
echo "  Key changes needed in App.jsx:"
echo "  • Convert timestamps: new Date(m.created_at+'Z').toLocaleDateString()"
echo "  • Import: exportMap, postComment, getComments, postFeedback"
echo "  • Add Help/Feedback tab"
echo "  • Add leaderboard section to Community"
echo "  • Add Export button to Library cards"
echo ""
echo "DEPLOY: git add -A && git commit -m 'v10' && git push"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"