#!/bin/bash
set -e
echo "🍄 Mycel v7 — Deploy-ready prototype..."

# Deployment files
cat > start.sh << 'EOF'
#!/bin/bash
cd "$(dirname "$0")"
python -m uvicorn backend.app.main:app --reload --port 8000 --host 0.0.0.0
EOF
chmod +x start.sh

cat > Dockerfile << 'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt httpx ollama
COPY backend/ backend/
RUN mkdir -p uploads data
RUN touch backend/__init__.py backend/app/__init__.py backend/app/pipeline/__init__.py backend/app/services/__init__.py
ENV PORT=8000
CMD ["python", "-m", "uvicorn", "backend.app.main:app", "--host", "0.0.0.0", "--port", "8000"]
EOF

cat > railway.toml << 'EOF'
[build]
builder = "DOCKERFILE"
dockerfilePath = "Dockerfile"
[deploy]
healthcheckPath = "/"
EOF

mkdir -p frontend
cat > frontend/vercel.json << 'EOF'
{"buildCommand":"npm run build","outputDirectory":"dist","framework":"vite"}
EOF

# Complete api.js
cat > frontend/src/api.js << 'EOF'
var API = (typeof import.meta !== "undefined" && import.meta.env && import.meta.env.VITE_API_URL) || "http://localhost:8000";
export function uploadFile(file) { var f = new FormData(); f.append("file", file); return fetch(API + "/api/upload", { method: "POST", body: f }).then(function(r) { return r.json(); }); }
export var uploadPDF = uploadFile;
export function getMaps() { return fetch(API + "/api/maps").then(function(r) { return r.json(); }); }
export function getMap(id) { return fetch(API + "/api/maps/" + id).then(function(r) { return r.json(); }); }
export function deleteMap(id) { return fetch(API + "/api/maps/" + id, { method: "DELETE" }).then(function(r) { return r.json(); }); }
export function confirmMap(id) { return fetch(API + "/api/maps/" + id + "/confirm", { method: "POST" }).then(function(r) { return r.json(); }); }
export function unconfirmMap(id) { return fetch(API + "/api/maps/" + id + "/unconfirm", { method: "POST" }).then(function(r) { return r.json(); }); }
export function renameMap(id, title) { return fetch(API + "/api/maps/" + id + "/rename", { method: "PUT", headers: {"Content-Type": "application/json"}, body: JSON.stringify({title: title}) }).then(function(r) { return r.json(); }); }
export function submitCorrection(data) { return fetch(API + "/api/corrections", { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(data) }).then(function(r) { return r.json(); }); }
export function getCommunityMaps(domain) { var url = API + "/api/community"; if (domain && domain !== "all") url += "?domain=" + encodeURIComponent(domain); return fetch(url).then(function(r) { return r.json(); }); }
export function shareMap(id, title, desc, domain) { return fetch(API + "/api/community/share", { method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({map_id: id, title: title || "", description: desc || "", domain: domain || "general"}) }).then(function(r) { return r.json(); }); }
export function upvoteCommunityMap(id) { return fetch(API + "/api/community/" + id + "/upvote", { method: "POST" }).then(function(r) { return r.json(); }); }
export function getStats() { return fetch(API + "/api/stats").then(function(r) { return r.json(); }); }
EOF

# CSS with dark theme enforced
cat > frontend/src/App.css << 'EOF'
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap');
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Inter',sans-serif;background:#0B1120;color:#E8ECF4;-webkit-font-smoothing:antialiased;overflow:hidden}
#root{height:100vh;display:flex;flex-direction:column;overflow:hidden}
::selection{background:#6C5CE740;color:white}
svg text{user-select:none;-webkit-user-select:none}
::-webkit-scrollbar{width:6px}
::-webkit-scrollbar-track{background:transparent}
::-webkit-scrollbar-thumb{background:#ffffff20;border-radius:3px}
button{font-family:inherit;transition:opacity 0.15s}
button:hover{opacity:0.85}
button:active{transform:scale(0.97)}
input:focus,textarea:focus{outline:none}
EOF

# Backend: add missing endpoints
MAIN=backend/app/main.py
if [ -f "$MAIN" ] && ! grep -q "unconfirm" "$MAIN" 2>/dev/null; then
  cat >> "$MAIN" << 'PYEOF'

@app.post("/api/maps/{map_id}/unconfirm")
async def unconfirm(map_id: str):
    from backend.app.services.storage import _conn
    from datetime import datetime
    c = _conn()
    c.execute("UPDATE maps SET status='draft', updated_at=? WHERE id=?", (datetime.now().isoformat(), map_id))
    c.commit(); c.close()
    return {"status": "draft"}
PYEOF
  echo "  ✓ main.py: added unconfirm endpoint"
fi

echo ""
echo "✓ All v7 files created!"
echo ""
echo "DEPLOY: git add -A && git commit -m 'v7' && git push"
echo "Then: Railway (backend) + Vercel (frontend)"