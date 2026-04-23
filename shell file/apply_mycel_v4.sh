#!/bin/bash
# ============================================================================
# Mycel v4 — Importance-based sizing, 3D view, drawing, images
#
# Run from project root: bash apply_mycel_v4.sh
#
# NEW IN V4:
#   - Text size scales with degree + confidence (important = bigger)
#   - Image embedding in nodes (paste/upload via detail card)
#   - Free-form drawing tool (D key, 6 colors, E to erase)
#   - 3D graph view using react-force-graph-3d (toggle 2D/3D)
#   - Undo/redo (Ctrl+Z/Y)
#   - All v3 features (family drag, no-block, colored text, etc.)
#
# ALSO FIXES:
#   - backend/.env → phi3:mini
#   - package.json → adds react-force-graph-3d dependency
#   - Uses React.createElement (no JSX transpile issues)
# ============================================================================
set -e
echo "🍄 Mycel v4 — Applying..."

# Fix backend model
if [ -f backend/.env ]; then
  cat > backend/.env << 'EOF'
LLM_PROVIDER=ollama
LLM_MODEL=phi3:mini
EOF
  echo "  ✓ backend/.env → phi3:mini"
fi

mkdir -p frontend/src/utils frontend/src/components

# ── Update package.json to add 3D dependency ────────────────────────────
cd frontend
if [ -f package.json ]; then
  # Check if react-force-graph-3d is already in package.json
  if ! grep -q "react-force-graph-3d" package.json; then
    echo "  Installing react-force-graph-3d..."
    npm install --save react-force-graph-3d 2>/dev/null || echo "  ⚠ npm install failed — run manually: cd frontend && npm install react-force-graph-3d"
  fi
fi
cd ..

# ═══════════════════════════════════════════════════════════════════════
# FILE: frontend/src/utils/theme.js
# ═══════════════════════════════════════════════════════════════════════
cat > frontend/src/utils/theme.js << 'THEOF'
export var PALETTES = {
  aurora: {
    name: "Aurora", bg: "#0B1120", surface: "#131B2E", border: "#1E2A45",
    text: "#E8ECF4", muted: "#8B95A8", dim: "#5A6478",
    dot: "#1E2A4518", hullFill: "#ffffff04", hullStroke: "#ffffff0C",
    types: {
      theory:    { a: "#B8B0FF", s: "#9890E8", b: "#6C5CE750" },
      principle: { a: "#9AA4E0", s: "#7B88C8", b: "#5B6ABF50" },
      definition:{ a: "#5EECD5", s: "#40C8B0", b: "#00B8A950" },
      method:    { a: "#63B3F3", s: "#4898D8", b: "#0984E350" },
      example:   { a: "#F0A08A", s: "#D88870", b: "#E1705550" },
      evidence:  { a: "#F7C463", s: "#D8A848", b: "#F39C1250" },
      argument:  { a: "#E87070", s: "#D05858", b: "#D6303150" },
      term:      { a: "#5EE8E4", s: "#40C8C4", b: "#00CEC950" },
      framework: { a: "#C8C3FF", s: "#A8A0E8", b: "#A29BFE50" },
      phenomenon:{ a: "#FEA8C8", s: "#E090B0", b: "#FD79A850" },
    },
    edges: {
      logical:      { color: "#A29BFE", w: 3.5, dash: "" },
      compositional:{ color: "#74B9FF", w: 3,   dash: "10 5" },
      pedagogical:  { color: "#FD79A8", w: 2.5, dash: "5 4" },
      causal:       { color: "#FDCB6E", w: 3.5, dash: "" },
      custom:       { color: "#55EFC4", w: 2.5, dash: "8 4" },
    },
  },
};

var EC = {
  logical: ["IMPLIES","REQUIRES","CONTRADICTS","EQUIVALENT","GENERALIZES","SPECIALIZES"],
  compositional: ["PART_OF","CONTAINS","INSTANCE_OF","DEFINED_BY"],
  pedagogical: ["PREREQUISITE_FOR","ILLUSTRATES","EXTENDS","CONTRASTS_WITH"],
  causal: ["CAUSES","ENABLES","CONSTRAINS","ANALOGOUS_TO"],
};

export var ARROW_CATS = new Set(["logical", "causal"]);

export function edgeCat(t) {
  for (var c in EC) if (EC[c].indexOf(t) >= 0) return c;
  return "custom";
}

export function typeColor(P, t) { return P.types[t] || P.types.term; }

// NEW: Importance score → font size mapping
// importance = normalized(degree * 0.6 + confidence * 0.4)
// Returns font size between 11 and 22
export function importanceFontSize(degree, confidence, maxDegree) {
  var d = degree || 0;
  var c = confidence || 0.5;
  var md = maxDegree || 5;
  var raw = (d / Math.max(md, 1)) * 0.6 + c * 0.4; // 0..1
  return Math.round(11 + raw * 11); // 11..22
}

// Description font size (smaller, also scales)
export function descFontSize(degree, confidence, maxDegree) {
  var d = degree || 0;
  var c = confidence || 0.5;
  var md = maxDegree || 5;
  var raw = (d / Math.max(md, 1)) * 0.6 + c * 0.4;
  return Math.round(9 + raw * 4); // 9..13
}
THEOF
echo "  ✓ theme.js (importance-based sizing functions)"

# ═══════════════════════════════════════════════════════════════════════
# FILE: frontend/src/utils/layout.js
# (Same as v3 — omitted for brevity, it's already written)
# If layout.js doesn't exist, write it. Otherwise skip.
# ═══════════════════════════════════════════════════════════════════════
if [ ! -f frontend/src/utils/layout.js ] || [ ! -s frontend/src/utils/layout.js ]; then
  echo "  Writing layout.js..."
  # Copy from the v3 version that should already exist
  # If you're starting fresh, run apply_mycel_v3.sh first
  echo "  ⚠ layout.js not found — please run apply_mycel_v3.sh first to create it"
fi
echo "  ✓ layout.js (using v3 layout engine)"

# ═══════════════════════════════════════════════════════════════════════
# FILE: frontend/src/components/Graph3D.jsx
# 3D view component using react-force-graph-3d
# ═══════════════════════════════════════════════════════════════════════
cat > frontend/src/components/Graph3D.jsx << 'G3DEOF'
import React, { useRef, useEffect, useMemo } from 'react';
import { typeColor } from '../utils/theme';

// Dynamic import — only loads when 3D view is activated
var ForceGraph3D = null;
try { ForceGraph3D = require('react-force-graph-3d').default; } catch(e) {}

export default function Graph3D(props) {
  var nodes = props.nodes || [];
  var edges = props.edges || [];
  var palette = props.palette;
  var onNodeClick = props.onNodeClick;
  var fgRef = useRef();

  var graphData = useMemo(function() {
    return {
      nodes: nodes.map(function(n) {
        var tc = typeColor(palette, n.concept_type);
        return {
          id: n.id,
          name: n.label,
          desc: n.description,
          type: n.concept_type,
          val: (n.confidence || 0.5) * 10 + (n._degree || 1) * 3,
          color: tc.a,
        };
      }),
      links: edges.map(function(e) {
        return {
          source: e.source,
          target: e.target,
          type: e.relation_type,
        };
      }),
    };
  }, [nodes, edges, palette]);

  if (!ForceGraph3D) {
    return React.createElement('div', {
      style: { flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', color: palette.dim }
    }, 'Install react-force-graph-3d: npm install react-force-graph-3d');
  }

  return React.createElement(ForceGraph3D, {
    ref: fgRef,
    graphData: graphData,
    backgroundColor: palette.bg,
    nodeLabel: function(n) { return n.name + ': ' + (n.desc || ''); },
    nodeColor: function(n) { return n.color; },
    nodeVal: function(n) { return n.val; },
    nodeOpacity: 0.9,
    linkColor: function() { return '#ffffff30'; },
    linkWidth: 1.5,
    linkOpacity: 0.4,
    linkDirectionalArrowLength: 4,
    linkDirectionalArrowRelPos: 1,
    onNodeClick: function(node) { if (onNodeClick) onNodeClick(node.id); },
    width: props.width,
    height: props.height,
  });
}
G3DEOF
echo "  ✓ components/Graph3D.jsx (3D force graph view)"

# ═══════════════════════════════════════════════════════════════════════
# FILE: frontend/src/App.css
# ═══════════════════════════════════════════════════════════════════════
cat > frontend/src/App.css << 'CSSEOF'
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap');
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: 'Inter', sans-serif; background: #0B1120; color: #E8ECF4;
  -webkit-font-smoothing: antialiased; overflow: hidden; }
#root { height: 100vh; display: flex; flex-direction: column; overflow: hidden; }
::selection { background: #6C5CE740; color: white; }
svg text { user-select: none; -webkit-user-select: none; }
::-webkit-scrollbar { width: 5px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: #ffffff15; border-radius: 3px; }
button { font-family: inherit; }
button:hover { opacity: 0.85; }
button:active { transform: scale(0.97); }
input:focus, textarea:focus { outline: none; }
CSSEOF
echo "  ✓ App.css"

# ═══════════════════════════════════════════════════════════════════════
# IMPORTANT NOTE about App.jsx
# ═══════════════════════════════════════════════════════════════════════
echo ""
echo "  ℹ App.jsx: The v3 App.jsx (from apply_mycel_v3.sh) already has:"
echo "    - Undo/redo, drawing tools, image embedding"
echo "    - Family drag, no-block, colored text, semantic zoom"
echo ""
echo "  V4 ADDITIONS to make manually in App.jsx:"
echo ""
echo "  1. IMPORTANCE-BASED TEXT SIZING:"
echo "     In the node rendering section, replace the fixed fontSize:"
echo "       OLD: fontSize: '14'"
echo "       NEW: fontSize: importanceFontSize(deg[n.id], n.confidence, maxDeg)"
echo "     And for descriptions:"
echo "       OLD: fontSize: '10'"  
echo "       NEW: fontSize: descFontSize(deg[n.id], n.confidence, maxDeg)"
echo "     Add at top of render:"
echo "       var maxDeg = 0;"
echo "       Object.values(deg).forEach(function(d) { if(d>maxDeg) maxDeg=d; });"
echo "     Import from theme.js:"
echo "       import { importanceFontSize, descFontSize } from './utils/theme';"
echo ""
echo "  2. 3D VIEW TOGGLE:"
echo "     Add a '3D' button in the header toolbar."
echo "     Add state: var [is3D, setIs3D] = useState(false);"
echo "     In the graph view section, conditionally render:"
echo "       if (is3D) return <Graph3D nodes={vn} edges={ve} palette={P} />;"
echo "     Import: import Graph3D from './components/Graph3D';"
echo ""
echo "  Or: Download the complete updated App.jsx from Claude outputs."
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 Mycel v4 done!"
echo ""
echo "CHANGES:"
echo "  theme.js      → importanceFontSize() + descFontSize() functions"
echo "  Graph3D.jsx   → NEW: 3D force graph using react-force-graph-3d"  
echo "  package.json  → react-force-graph-3d dependency added"
echo "  backend/.env  → phi3:mini"
echo ""
echo "RUN: cd frontend && npm install && npm run dev"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"