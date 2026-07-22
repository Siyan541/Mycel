from backend.app.services.media import enrich
from backend.app.routes.socratic import router as socratic_router
import os, shutil, json, logging
from contextlib import asynccontextmanager
from fastapi import FastAPI, UploadFile, File, Header, Body, Query
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, Response
from backend.app.config import UPLOAD_DIR, DATA_DIR
from backend.app.pipeline.orchestrator import run
from backend.app.services.storage import *
from backend.app.services.media import extract_media, attach_provenance
from backend.app.services.storage import update_map_state

logging.basicConfig(level=logging.INFO)
ADMIN_KEY = os.getenv("ADMIN_KEY", "mycel_admin_2026")

@asynccontextmanager
async def lifespan(app): yield

app = FastAPI(title="Mycel", version="3.1.0", lifespan=lifespan)
app.include_router(socratic_router)
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])
ALLOWED_EXT = {'.pdf','.docx','.txt','.md','.markdown','.rst','.tex','.epub', '.py'}
def _uid(h): return h or "anonymous"

@app.get("/")
async def root(): return {"status":"ok","version":"3.1.0"}

@app.put("/api/maps/{map_id}/graph")
async def save_graph(map_id: str, body: dict = Body(...)):
    return {"status": "saved" if update_map_state(map_id, body) else "not_found"}

@app.put("/api/maps/{map_id}/visibility")
async def set_visibility(map_id: str, body: dict = Body(...)):
    vis = "public" if body.get("visibility") == "public" else "private"
    g = get_map(map_id)
    if not g:
        return JSONResponse({"error": "Not found"}, status_code=404)
    meta = dict(getattr(g, "metadata", None) or {}); meta["visibility"] = vis
    g.metadata = meta
    conn = sqlite3.connect(DATA_DIR)
    conn.execute("UPDATE maps SET graph_json=? WHERE id=?", (g.model_dump_json(), map_id))
    conn.commit(); conn.close(); return {"status": "ok", "visibility": vis}

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
async def upload(file: UploadFile = File(...), force: bool = Query(False),
                 text_only: bool = Query(False), mode: str = Query("concept")):
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in (".pdf", ".docx", ".txt", ".md", ".markdown", ".rst", ".tex", ".epub", ".py"):
        return JSONResponse({"error": "Unsupported format: " + ext}, 400)
    fp = UPLOAD_DIR / file.filename
    with open(fp, "wb") as f:
        shutil.copyfileobj(file.file, f)

    if ext == ".py":
        from backend.app.pipeline.code_parser import build_code_graph
        graph = build_code_graph(str(fp))
    else:
        graph = run(str(fp))

    # (a) make the PDF split-view scroll + highlight work: exact page + verbatim quote
    try:
        attach_provenance(graph.nodes, str(fp))
    except Exception:
        pass

    # (b) scrape images / tables / formulas (skipped when the user picks "Text only")
    figures = enrich(graph, str(fp), text_only=text_only) 
    graph.metadata = dict(graph.metadata or {})
    graph.metadata["figures"] = figures

    map_id = save_map(file.filename, graph)
    return {
        "status": "success", "map_id": map_id, "document": file.filename,
        "nodes": [n.model_dump() for n in graph.nodes],
        "edges": [e.model_dump() for e in graph.edges],
        "figures": figures,                       # <-- frontend turns these into blocks
        "node_count": len(graph.nodes), "edge_count": len(graph.edges),
    }

@app.get("/api/maps")
async def list_maps(x_user_id: str = Header(None)): return {"maps": get_maps(_uid(x_user_id))}

@app.get("/api/maps/{map_id}")
async def get_map_data(map_id: str):
    g = get_map(map_id)
    if not g:
        return JSONResponse({"error": "Not found"}, 404)
    meta = g.metadata or {}
    st = meta.get("state")
    base = {"figures": meta.get("figures", []), "visibility": meta.get("visibility", "private")}
    if st:
        base.update({"nodes": st.get("nodes", []), "edges": st.get("edges", []),
                     "drawings": st.get("drawings", []), "cards": st.get("cards", []),
                     "pdfAnn": st.get("pdfAnn", []), "groups": st.get("groups", {})})
    else:
        base.update({"nodes": [n.model_dump() for n in g.nodes],
                     "edges": [e.model_dump() for e in g.edges]})
    return base

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

# Serve uploaded PDF for the split-screen viewer
from fastapi.responses import FileResponse
@app.get("/api/maps/{map_id}/pdf")
async def get_pdf(map_id: str):
    """Return the original PDF for the split-screen viewer."""
    from backend.app.services.storage import _conn
    c = _conn()
    row = c.execute("SELECT filename FROM maps WHERE id=?", (map_id,)).fetchone()
    c.close()
    if not row: return JSONResponse({"error": "Not found"}, 404)
    from backend.app.config import UPLOAD_DIR
    filepath = UPLOAD_DIR / row[0]
    if not filepath.exists(): return JSONResponse({"error": "PDF not found on disk"}, 404)
    return FileResponse(str(filepath), media_type="application/pdf")
