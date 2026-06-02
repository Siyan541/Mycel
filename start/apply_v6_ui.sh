#!/bin/bash
# ============================================================================
# Mycel v6 — UI polish + styled library/community
#
# Fixes:
#   - Library: dark background, status badges, confirm→share flow with cancel
#   - Community: proper dark cards, upvote, domain filters, load map
#   - Text sizes: all increased for laptop readability
#   - start.sh: created if missing
#   - Consistent dark theme throughout (no white backgrounds)
#
# Run from project root: bash apply_v6_ui.sh
# ============================================================================
set -e
echo "🍄 Mycel v6 UI polish..."

# Create start.sh if missing
if [ ! -f start.sh ]; then
cat > start.sh << 'STARTEOF'
#!/bin/bash
echo "Starting backend on http://localhost:8000 ..."
cd "$(dirname "$0")"
python -m uvicorn backend.app.main:app --reload --port 8000 --host 0.0.0.0
STARTEOF
chmod +x start.sh
echo "  ✓ Created start.sh"
fi

# Ensure api.js has all needed functions
if ! grep -q "confirmMap" frontend/src/api.js 2>/dev/null; then
cat >> frontend/src/api.js << 'APIEOF'

export function confirmMap(id) {
  var API = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_API_URL) || 'http://localhost:8000';
  return fetch(API + '/api/maps/' + id + '/confirm', { method: 'POST' }).then(function(r) { return r.json(); });
}
export function renameMap(id, title) {
  var API = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_API_URL) || 'http://localhost:8000';
  return fetch(API + '/api/maps/' + id + '/rename', { method: 'PUT', headers: {'Content-Type':'application/json'}, body: JSON.stringify({title:title}) }).then(function(r) { return r.json(); });
}
export function shareMap(id, title, description, domain) {
  var API = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_API_URL) || 'http://localhost:8000';
  return fetch(API + '/api/community/share', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify({map_id:id,title:title||'',description:description||'',domain:domain||'general'}) }).then(function(r) { return r.json(); });
}
export function getCommunityMaps(domain) {
  var API = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_API_URL) || 'http://localhost:8000';
  var url = API + '/api/community';
  if (domain && domain !== 'all') url += '?domain=' + encodeURIComponent(domain);
  return fetch(url).then(function(r) { return r.json(); });
}
export function upvoteCommunityMap(id) {
  var API = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_API_URL) || 'http://localhost:8000';
  return fetch(API + '/api/community/' + id + '/upvote', { method: 'POST' }).then(function(r) { return r.json(); });
}
APIEOF
echo "  ✓ api.js updated with community functions"
fi

echo "  ✓ Shell setup complete"
echo ""
echo "  Now apply these changes to your App.jsx manually:"
echo ""
echo "  ═══════════════════════════════════════════════════════"
echo "  1. IMPORTS — at the top of App.jsx, change:"
echo ""
echo '     FROM: import { uploadPDF, getMaps, getMap, deleteMap, submitCorrection } from "./api";'
echo '     TO:   import { uploadPDF, getMaps, getMap, deleteMap, submitCorrection, confirmMap, shareMap, getCommunityMaps, upvoteCommunityMap } from "./api";'
echo ""
echo "  ═══════════════════════════════════════════════════════"
echo "  2. STATE — after the line:"
echo "     var _maps = useState([]), maps = _maps[0], setMaps = _maps[1];"
echo "     ADD these lines:"
echo ""
echo '     var _cmaps = useState([]), communityMaps = _cmaps[0], setCommunityMaps = _cmaps[1];'
echo '     var _shareModal = useState(null), shareModal = _shareModal[0], setShareModal = _shareModal[1];'
echo '     var _shareDomain = useState("general"), shareDomain = _shareDomain[0], setShareDomain = _shareDomain[1];'
echo '     var _commDomain = useState("all"), commDomain = _commDomain[0], setCommDomain = _commDomain[1];'
echo ""
echo "  ═══════════════════════════════════════════════════════"
echo "  3. LOAD COMMUNITY — after the loadMap function, ADD:"
echo ""
echo '     var loadCommunity = function(domain) {'
echo '       getCommunityMaps(domain).then(function(d) {'
echo '         setCommunityMaps(d.maps || []);'
echo '       }).catch(function() { setCommunityMaps([]); });'
echo '     };'
echo ""
echo "  ═══════════════════════════════════════════════════════"
echo "  4. VIEW EFFECT — in the useEffect that watches view,"
echo "     add after the library line:"
echo ""
echo '     if (view === "community") loadCommunity("all");'
echo ""
echo "  ═══════════════════════════════════════════════════════"
echo "  5. UPLOAD FORMAT — change the file check:"
echo ""
echo '     FROM: if (!file || !file.name.toLowerCase().endsWith(".pdf")) return;'
echo '     TO:   var ext = file.name.split(".").pop().toLowerCase();'
echo '           if (!file || ["pdf","docx","txt","md","epub"].indexOf(ext) < 0) return;'
echo ""
echo '     AND change: accept: ".pdf"'
echo '     TO:         accept: ".pdf,.docx,.txt,.md,.epub"'
echo ""
echo "  ═══════════════════════════════════════════════════════"
echo "  6. LIBRARY VIEW — REPLACE the entire library section"
echo "     (view === 'library' && ...) with the styled version below."
echo "     Copy from LIBRARY_REPLACEMENT.txt"
echo ""
echo "  ═══════════════════════════════════════════════════════"
echo "  7. COMMUNITY VIEW — REPLACE the entire community section"
echo "     (view === 'community' && ...) with the styled version below."
echo "     Copy from COMMUNITY_REPLACEMENT.txt"
echo ""
echo "  ═══════════════════════════════════════════════════════"

# Write the replacement code blocks as separate files for easy copy-paste
cat > frontend/src/LIBRARY_REPLACEMENT.txt << 'LIBEOF'
    // LIBRARY — paste this to replace your current library view
    view === 'library' && React.createElement("div", { style: { flex: 1, padding: 24, overflowY: "auto", background: P.bg } },
      React.createElement("h2", { style: { fontSize: 18, fontWeight: 600, marginBottom: 16, color: P.text } }, "Library"),
      maps.length === 0
        ? React.createElement("div", { style: { textAlign: "center", padding: 40, color: P.dim } }, "No maps yet. Upload a PDF to create one.")
        : React.createElement("div", { style: { display: "grid", gridTemplateColumns: "repeat(auto-fill,minmax(280px,1fr))", gap: 12 } },
            maps.map(function(m) {
              return React.createElement("div", { key: m.id, style: { padding: 18, background: P.surface, border: "1px solid " + P.border, borderRadius: 12, cursor: "pointer" } },
                // Title + status
                React.createElement("div", { style: { display: "flex", alignItems: "center", gap: 8, marginBottom: 8 } },
                  React.createElement("div", { style: { fontSize: 15, fontWeight: 600, color: P.text, flex: 1 } }, m.title || m.filename),
                  React.createElement("span", {
                    style: {
                      fontSize: 10, padding: "3px 10px", borderRadius: 10, fontWeight: 500,
                      background: m.status === 'confirmed' ? 'rgba(81,207,102,0.15)' : 'rgba(90,100,120,0.2)',
                      color: m.status === 'confirmed' ? '#51CF66' : P.dim,
                    }
                  }, m.status === 'confirmed' ? 'Confirmed' : 'Draft')
                ),
                // Date
                React.createElement("div", { style: { fontSize: 11, color: P.dim, marginBottom: 12 } },
                  m.created_at ? m.created_at.split('T')[0] : ''),
                // Action buttons
                React.createElement("div", { style: { display: "flex", gap: 6 } },
                  // Open
                  React.createElement("button", {
                    onClick: function(e) { e.stopPropagation(); loadMap(m.id); },
                    style: { flex: 1, padding: "7px 0", background: "rgba(162,155,254,0.1)", border: "1px solid rgba(162,155,254,0.25)", borderRadius: 6, color: "#A29BFE", fontSize: 12, fontWeight: 500, cursor: "pointer" }
                  }, "Open"),
                  // Confirm (if draft)
                  m.status !== 'confirmed' && React.createElement("button", {
                    onClick: function(e) {
                      e.stopPropagation();
                      confirmMap(m.id).then(function() { getMaps().then(function(d) { setMaps(d.maps || []); }); });
                    },
                    style: { flex: 1, padding: "7px 0", background: "rgba(81,207,102,0.1)", border: "1px solid rgba(81,207,102,0.25)", borderRadius: 6, color: "#51CF66", fontSize: 12, fontWeight: 500, cursor: "pointer" }
                  }, "Confirm"),
                  // Share (if confirmed) — opens share modal
                  m.status === 'confirmed' && React.createElement("button", {
                    onClick: function(e) {
                      e.stopPropagation();
                      setShareModal({ id: m.id, title: m.title || m.filename });
                    },
                    style: { flex: 1, padding: "7px 0", background: "rgba(162,155,254,0.1)", border: "1px solid rgba(162,155,254,0.25)", borderRadius: 6, color: "#A29BFE", fontSize: 12, fontWeight: 500, cursor: "pointer" }
                  }, "Share"),
                  // Delete
                  React.createElement("button", {
                    onClick: function(e) {
                      e.stopPropagation();
                      if (confirm('Delete "' + (m.title || m.filename) + '"?')) {
                        deleteMap(m.id).then(function() { getMaps().then(function(d) { setMaps(d.maps || []); }); });
                      }
                    },
                    style: { padding: "7px 12px", background: "rgba(255,107,107,0.1)", border: "1px solid rgba(255,107,107,0.25)", borderRadius: 6, color: "#FF6B6B", fontSize: 12, cursor: "pointer" }
                  }, "✕")
                )
              );
            })
          ),
      // Share Modal overlay
      shareModal && React.createElement("div", {
        style: { position: "fixed", inset: 0, background: "rgba(0,0,0,0.6)", display: "flex", alignItems: "center", justifyContent: "center", zIndex: 100 },
        onClick: function() { setShareModal(null); }
      },
        React.createElement("div", {
          onClick: function(e) { e.stopPropagation(); },
          style: { width: 360, background: P.surface, border: "1px solid " + P.border, borderRadius: 16, padding: 24 }
        },
          React.createElement("h3", { style: { fontSize: 16, fontWeight: 600, marginBottom: 12, color: P.text } }, "Share to Community"),
          React.createElement("div", { style: { fontSize: 13, color: P.muted, marginBottom: 16 } }, 'Share "' + shareModal.title + '" with the community?'),
          // Domain picker
          React.createElement("div", { style: { marginBottom: 16 } },
            React.createElement("div", { style: { fontSize: 12, color: P.dim, marginBottom: 6 } }, "Domain:"),
            React.createElement("div", { style: { display: "flex", gap: 4, flexWrap: "wrap" } },
              ["general", "mathematics", "physics", "cs", "biology", "chemistry", "history"].map(function(d) {
                return React.createElement("button", {
                  key: d,
                  onClick: function() { setShareDomain(d); },
                  style: {
                    padding: "4px 12px", borderRadius: 6, fontSize: 11, cursor: "pointer",
                    background: shareDomain === d ? "rgba(162,155,254,0.2)" : "transparent",
                    border: shareDomain === d ? "1px solid rgba(162,155,254,0.4)" : "1px solid " + P.border,
                    color: shareDomain === d ? "#A29BFE" : P.dim,
                  }
                }, d);
              })
            )
          ),
          // Action buttons
          React.createElement("div", { style: { display: "flex", gap: 8 } },
            React.createElement("button", {
              onClick: function() {
                shareMap(shareModal.id, shareModal.title, '', shareDomain)
                  .then(function() { setShareModal(null); alert('Shared successfully!'); })
                  .catch(function() { alert('Share failed'); });
              },
              style: { flex: 1, padding: "10px 0", background: "rgba(162,155,254,0.15)", border: "1px solid rgba(162,155,254,0.3)", borderRadius: 8, color: "#A29BFE", fontSize: 13, fontWeight: 600, cursor: "pointer" }
            }, "Share"),
            React.createElement("button", {
              onClick: function() { setShareModal(null); },
              style: { flex: 1, padding: "10px 0", background: "transparent", border: "1px solid " + P.border, borderRadius: 8, color: P.dim, fontSize: 13, cursor: "pointer" }
            }, "Cancel")
          )
        )
      )
    ),
LIBEOF
echo "  ✓ LIBRARY_REPLACEMENT.txt written"

cat > frontend/src/COMMUNITY_REPLACEMENT.txt << 'COMEOF'
    // COMMUNITY — paste this to replace your current community view
    view === 'community' && React.createElement("div", { style: { flex: 1, padding: 24, overflowY: "auto", background: P.bg } },
      React.createElement("h2", { style: { fontSize: 18, fontWeight: 600, marginBottom: 16, color: P.text } }, "Community Maps"),
      // Domain filter
      React.createElement("div", { style: { display: "flex", gap: 6, marginBottom: 20, flexWrap: "wrap" } },
        ["all", "general", "mathematics", "physics", "cs", "biology", "chemistry", "history"].map(function(d) {
          return React.createElement("button", {
            key: d,
            onClick: function() { setCommDomain(d); loadCommunity(d); },
            style: {
              padding: "6px 16px", borderRadius: 8, fontSize: 12, cursor: "pointer", fontWeight: 500,
              background: commDomain === d ? "rgba(162,155,254,0.15)" : "transparent",
              border: commDomain === d ? "1px solid rgba(162,155,254,0.3)" : "1px solid " + P.border,
              color: commDomain === d ? "#A29BFE" : P.dim,
            }
          }, d.charAt(0).toUpperCase() + d.slice(1));
        })
      ),
      // Cards
      communityMaps.length === 0
        ? React.createElement("div", { style: { textAlign: "center", padding: 40, color: P.dim } },
            "No community maps yet. Confirm and share your maps to populate this feed.")
        : React.createElement("div", { style: { display: "grid", gridTemplateColumns: "repeat(auto-fill,minmax(280px,1fr))", gap: 12 } },
            communityMaps.map(function(m) {
              return React.createElement("div", { key: m.id, style: { padding: 18, background: P.surface, border: "1px solid " + P.border, borderRadius: 12 } },
                React.createElement("div", { style: { display: "flex", alignItems: "center", gap: 8, marginBottom: 6 } },
                  React.createElement("div", { style: { fontSize: 15, fontWeight: 600, color: P.text, flex: 1 } }, m.title),
                  React.createElement("span", {
                    style: { fontSize: 10, padding: "3px 10px", borderRadius: 10, background: "rgba(162,155,254,0.15)", color: "#A29BFE" }
                  }, m.domain || 'general')
                ),
                m.description && React.createElement("div", { style: { fontSize: 12, color: P.muted, marginBottom: 8, lineHeight: 1.4 } }, m.description),
                React.createElement("div", { style: { fontSize: 11, color: P.dim, marginBottom: 10 } },
                  "by " + (m.user_id || 'anonymous') + " · " + (m.created_at ? m.created_at.split('T')[0] : '')),
                React.createElement("div", { style: { display: "flex", gap: 6 } },
                  React.createElement("button", {
                    onClick: function() { upvoteCommunityMap(m.id).then(function() { loadCommunity(commDomain); }); },
                    style: { padding: "6px 14px", background: "rgba(253,203,110,0.1)", border: "1px solid rgba(253,203,110,0.25)", borderRadius: 6, color: "#FDCB6E", fontSize: 12, cursor: "pointer", fontWeight: 500 }
                  }, "↑ " + (m.upvotes || 0)),
                  React.createElement("button", {
                    onClick: function() { loadMap(m.map_id); },
                    style: { flex: 1, padding: "6px 0", background: "rgba(94,236,213,0.1)", border: "1px solid rgba(94,236,213,0.25)", borderRadius: 6, color: "#5EECD5", fontSize: 12, cursor: "pointer", fontWeight: 500 }
                  }, "Open Map")
                )
              );
            })
          )
    ),
COMEOF
echo "  ✓ COMMUNITY_REPLACEMENT.txt written"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 v6 files ready!"
echo ""
echo "TO APPLY:"
echo "  1. Open frontend/src/App.jsx in VS Code"
echo "  2. Make the 5 small changes (imports, state, loadCommunity, effect, upload)"
echo "  3. Find your current 'view === \"library\"' block and replace it"
echo "     with the content from frontend/src/LIBRARY_REPLACEMENT.txt"
echo "  4. Find your current 'view === \"community\"' block and replace it"
echo "     with the content from frontend/src/COMMUNITY_REPLACEMENT.txt"
echo "  5. Save — Vite auto-reloads"
echo ""
echo "WHAT'S DIFFERENT:"
echo "  Library:"
echo "    - Dark background (P.bg) throughout"
echo "    - Styled action buttons with colored borders"
echo "    - Share button opens a MODAL with domain picker + Cancel"
echo "    - Delete has confirmation dialog"
echo "    - Status badges with proper dark-theme colors"
echo ""
echo "  Community:"
echo "    - Domain filter pills at top"
echo "    - Dark-themed cards matching the rest of the app"
echo "    - Upvote button with count"
echo "    - 'Open Map' loads the mindmap into graph view"
echo "    - Empty state message when no maps shared yet"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"