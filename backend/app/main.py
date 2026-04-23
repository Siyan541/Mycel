import os, sys, shutil, json, logging
from pathlib import Path
from contextlib import asynccontextmanager

sys.path.insert(0, str(Path(__file__).parent.parent.parent))

from fastapi import FastAPI, UploadFile, File, Query, WebSocket, WebSocketDisconnect, Body
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from backend.app.config import UPLOAD_DIR
from backend.app.pipeline.orchestrator import run
from backend.app.services.storage import (
    save_map, get_maps, get_map, delete_map, confirm_map, update_map, rename_map,
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
async def root(): return {"status": "ok", "version": "2.0.0"}

@app.post("/api/upload")
async def upload(file: UploadFile = File(...)):
    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in ALLOWED_EXT:
        return JSONResponse({"error": f"Unsupported format. Allowed: {', '.join(ALLOWED_EXT)}"}, 400)
    fp = UPLOAD_DIR / file.filename
    with open(fp, "wb") as f: shutil.copyfileobj(file.file, f)
    graph = run(str(fp))
    map_id = save_map(file.filename, graph)
    return {
        "status": "success", "map_id": map_id, "document": file.filename,
        "nodes": [n.model_dump() for n in graph.nodes],
        "edges": [e.model_dump() for e in graph.edges],
        "node_count": len(graph.nodes), "edge_count": len(graph.edges),
    }

@app.get("/api/maps")
async def list_maps(user_id: str = "anonymous"):
    return {"maps": get_maps(user_id)}

@app.get("/api/maps/{map_id}")
async def get_map_data(map_id: str):
    g = get_map(map_id)
    if not g: return JSONResponse({"error": "Not found"}, 404)
    return {"nodes": [n.model_dump() for n in g.nodes], "edges": [e.model_dump() for e in g.edges]}

@app.delete("/api/maps/{map_id}")
async def del_map(map_id: str):
    delete_map(map_id); return {"status": "deleted"}

@app.post("/api/maps/{map_id}/confirm")
async def confirm(map_id: str):
    confirm_map(map_id)
    return {"status": "confirmed", "map_id": map_id}

@app.put("/api/maps/{map_id}/rename")
async def rename(map_id: str, body: dict = Body(...)):
    rename_map(map_id, body.get("title", ""))
    return {"status": "renamed"}

@app.post("/api/corrections")
async def submit_correction(body: dict = Body(...)):
    cid = save_correction(body.get("map_id",""), body.get("type","edit"),
        body.get("original"), body.get("corrected"), body.get("user_id","anonymous"),
        body.get("quality", 5))
    return {"id": cid}

# Community endpoints
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

@app.post("/api/export-training")
async def export_train(confirmed_only: bool = True):
    n = export_training(confirmed_only=confirmed_only)
    return {"exported": n}
