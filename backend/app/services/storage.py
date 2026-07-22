import json, sqlite3, uuid, hashlib, logging
from pathlib import Path
from datetime import datetime
from backend.app.config import DATA_DIR
from backend.app.models import get_level
import sqlite3, time

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

# Effective level considers: points, confirmed maps, upvotes, time, quality
def get_effective_level(user_id):
    """Level based on multiple factors, not just points."""
    c = _conn()
    row = c.execute("SELECT points FROM users WHERE id=?", (user_id,)).fetchone()
    if not row: c.close(); return "none"
    points = row[0]
    
    # Count confirmed maps
    confirmed = c.execute("SELECT COUNT(*) FROM maps WHERE user_id=? AND status='confirmed'", (user_id,)).fetchone()[0]
    
    # Count total upvotes received on community maps
    upvotes = c.execute("SELECT COALESCE(SUM(cm.upvotes),0) FROM community_maps cm WHERE cm.user_id=?", (user_id,)).fetchone()[0]
    
    # Count edits (corrections)
    edits = c.execute("SELECT COUNT(*) FROM corrections WHERE user_id=?", (user_id,)).fetchone()[0]
    
    # Days on platform
    created = c.execute("SELECT created_at FROM users WHERE id=?", (user_id,)).fetchone()
    days = 0
    if created and created[0]:
        try:
            from datetime import datetime
            created_date = datetime.fromisoformat(created[0].replace('Z',''))
            days = (datetime.now() - created_date).days
        except: pass
    
    c.close()
    
    # Composite score
    # Points are the base, but top levels need more
    score = points
    
    # Level determination with multi-factor requirements
    level = "none"
    if score >= 1:
        level = "beginner"
    if score >= 75 and confirmed >= 1:
        level = "experienced"
    if score >= 300 and confirmed >= 5 and upvotes >= 10:
        level = "expert"
    if score >= 1000 and confirmed >= 10 and upvotes >= 50 and edits >= 20 and days >= 14:
        level = "professional"  
    if score >= 5000 and confirmed >= 25 and upvotes >= 200 and edits >= 100 and days >= 60:
        level = "organizer"
    
    return level

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

def update_map_state(map_id, state):
    """state = {nodes, edges, drawings, cards, pdfAnn, groups} sent by the frontend."""
    from backend.app.services.storage import get_map  # reuse existing loader
    g = get_map(map_id)
    if not g:
        return False
    meta = dict(getattr(g, "metadata", None) or {})
    meta["state"] = state
    g.metadata = meta
    conn = sqlite3.connect(str(DATA_DIR / "app.db"))
    conn.execute(
        "UPDATE maps SET graph_json=?, updated_at=? WHERE id=?",
        (g.model_dump_json(), int(time.time()), map_id),
    )
    conn.commit()
    conn.close()
    return True

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
