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

@app.get("/api/test-llm")
async def test_llm():
    """Diagnostic: test what the LLM actually returns."""
    from backend.app.config import LLM_PROVIDER, LLM_MODEL, TOGETHER_MODEL
    from backend.app.services.llm import chat
    try:
        test_text = "Photosynthesis is the process by which plants convert sunlight into energy. Chlorophyll in the leaves absorbs light. The light reactions produce ATP. The Calvin cycle fixes carbon dioxide into glucose."
        result = chat(
            [{"role": "system", "content": "Extract concepts and relations from this text. Return JSON with concepts and relations arrays. Extract at least 3 concepts and 2 relations."},
             {"role": "user", "content": test_text}],
            json_schema={"type": "object", "properties": {"concepts": {"type": "array"}, "relations": {"type": "array"}}, "required": ["concepts", "relations"]},
            temperature=0.05, max_tokens=2000
        )
        return {
            "provider": LLM_PROVIDER,
            "model": TOGETHER_MODEL if LLM_PROVIDER == "together" else LLM_MODEL,
            "raw_response": result,
            "response_length": len(result)
        }
    except Exception as e:
        return {"error": str(e), "provider": LLM_PROVIDER}
    
@app.post("/api/admin/export")
async def admin_export(key: str = ""):
    if key != ADMIN_KEY: return JSONResponse({"error": "unauthorized"}, 403)
    n = export_training()
    return {"exported": n}
