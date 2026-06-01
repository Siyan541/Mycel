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
