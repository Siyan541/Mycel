#!/bin/bash
set -e
echo "🍄 Mycel v12.1 — Split-screen PDF viewer..."

# Create components directory
mkdir -p frontend/src/components

# Copy PDFViewer component
# (download PDFViewer.jsx from Claude outputs and place here)
if [ -f PDFViewer.jsx ]; then
  cp PDFViewer.jsx frontend/src/components/PDFViewer.jsx
  echo "  ✓ PDFViewer.jsx copied"
elif [ -f frontend/src/components/PDFViewer.jsx ]; then
  echo "  ✓ PDFViewer.jsx already exists"
else
  echo "  ⚠ Download PDFViewer.jsx from Claude outputs and place at"
  echo "    frontend/src/components/PDFViewer.jsx"
fi

# Add pdf.js CDN to index.html
INDEX=frontend/index.html
if [ -f "$INDEX" ]; then
  if ! grep -q "pdf.min.js" "$INDEX" 2>/dev/null; then
    # Insert before </head>
    sed -i.bak 's|</head>|    <script src="https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js"></script>\n    <script>pdfjsLib.GlobalWorkerOptions.workerSrc="https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.worker.min.js";</script>\n  </head>|' "$INDEX"
    rm -f "${INDEX}.bak"
    echo "  ✓ pdf.js CDN added to index.html"
  else
    echo "  ✓ pdf.js already in index.html"
  fi
fi

# Store uploaded PDF file reference in the upload flow
# The backend needs to return a URL where the PDF can be fetched
# Add this endpoint to main.py:
MAIN=backend/app/main.py
if ! grep -q "pdf_file" "$MAIN" 2>/dev/null; then
  cat >> "$MAIN" << 'PYEOF'

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
PYEOF
  echo "  ✓ main.py: added /api/maps/{id}/pdf endpoint"
fi

# Add getPdfUrl to api.js
if ! grep -q "getPdfUrl" frontend/src/api.js 2>/dev/null; then
  cat >> frontend/src/api.js << 'APIEOF'

export function getPdfUrl(mapId) {
  var API = (typeof import.meta !== "undefined" && import.meta.env && import.meta.env.VITE_API_URL) || "http://localhost:8000";
  return API + "/api/maps/" + mapId + "/pdf";
}
APIEOF
  echo "  ✓ api.js: added getPdfUrl()"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 Mycel v12.1 — PDF Viewer ready!"
echo ""
echo "FILES:"
echo "  frontend/src/components/PDFViewer.jsx — split-screen viewer"
echo "  frontend/index.html — pdf.js CDN script tags"
echo "  backend/app/main.py — /api/maps/{id}/pdf endpoint"
echo "  frontend/src/api.js — getPdfUrl() helper"
echo ""
echo "INTEGRATION — add to your App.jsx:"
echo ""
echo "1. Add import at top:"
echo '   import PDFViewer from "./components/PDFViewer.jsx";'
echo '   import { getPdfUrl } from "./api";'
echo ""
echo "2. Add state variable after other useState calls:"
echo '   var referMode = useState(false);'
echo ""
echo "3. Add a Refer/Learn button in the graph toolbar:"
echo '   h("button",{onClick:function(){referMode[1](!referMode[0]);},style:{padding:"6px 14px",'
echo '     borderRadius:6,border:referMode[0]?"1px solid #A29BFE":"1px solid "+BRD,'
echo '     background:referMode[0]?"rgba(162,155,254,0.15)":"transparent",'
echo '     color:referMode[0]?"#A29BFE":DIM,fontSize:14,cursor:"pointer"}},"📖 Refer")'
echo ""
echo "4. In the graphView, wrap the content conditionally:"
echo '   If referMode[0] is true, render PDFViewer instead of the graph:'
echo ""
echo '   var graphView = view[0]==="graph" ? ('
echo '     referMode[0]'
echo '       ? h(PDFViewer, {'
echo '           pdfUrl: mapId[0] ? getPdfUrl(mapId[0]) : null,'
echo '           nodes: vn, edges: ve, palette: P,'
echo '           selectedId: sel[0],'
echo '           onSelectConcept: function(id) { sel[1](id); },'
echo '           onClose: function() { referMode[1](false); },'
echo '           darkMode: darkMode[0]'
echo '         })'
echo '       : h("div", {ref:cRef, ...}, /* existing graph SVG */)'
echo '   ) : null;'
echo ""
echo "HOW IT WORKS:"
echo "  1. User uploads a PDF → mindmap generated"
echo "  2. In graph view, click '📖 Refer' button"
echo "  3. Screen splits: left = PDF pages, right = concept list"
echo "  4. Click a concept → PDF scrolls to the source page"
echo "  5. Source page gets highlighted border"
echo "  6. Concept markers appear on each PDF page"
echo "  7. Click '← Back' to return to the graph view"
echo ""
echo "DEPLOY: git add -A && git commit -m 'v12.1: split-screen PDF viewer' && git push"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"