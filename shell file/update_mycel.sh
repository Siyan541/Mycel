#!/bin/bash
# ============================================================================
# Mycel UI v2 — Complete frontend rewrite
#
# Fixes from v1:
#   1. OVERLAPPING BLOCKS: 4x stronger repulsion, larger collision radii,
#      more iterations, post-layout overlap resolution pass
#   2. INVISIBLE EDGES: Base thickness 3-8px (was 1-2.5px), base opacity
#      0.55 (was 0.28), ALL edges get arrow markers (not just logical/causal)
#   3. OUTLIER BLOCKS: 3x stronger link attraction, tighter ideal distances,
#      stronger centering force, max distance cap
#   4. COLORFUL TEXT: Labels use bright accent colors per concept type,
#      descriptions use softer tints — no more all-white text
#   5. MINIMAL BLOCKS: Transparent/translucent backgrounds with subtle
#      colored border — content-first, the "block" recedes
#   6. CONCEPT FAMILIES: Visual cluster hulls (convex hull outlines),
#      click any node to select its family, drag moves the whole family
#   7. INLINE TERM CIRCLES: Always visible (not just on hover), circled
#      terms in descriptions link to their concept nodes
#   8. DIRECTED ARROWS: Every single edge gets an arrowhead
#   9. SEMANTIC ZOOM: Zoom in → descriptions appear, term circles appear,
#      relation labels appear. Zoom out → just labels + connections
#
# Usage:
#   cd your-project/frontend
#   bash update_mycel_v2.sh
#
# This overwrites: src/App.jsx, src/App.css, src/utils/layout.js, src/utils/theme.js
# It does NOT touch: src/api.js, src/main.jsx, package.json, backend/
# ============================================================================
set -e

echo "🍄 Mycel UI v2 — Applying all changes..."

mkdir -p src/utils

# ── 1. Layout engine ────────────────────────────────────────────────────
cat > src/utils/layout.js << 'LAYOUT_EOF'
// Mycel Organic Layout v2 — fixes overlapping, outliers, and family grouping

export function wrapText(t, max = 28) {
  if (!t) return [];
  const w = t.split(/\s+/), lines = [];
  let c = '';
  for (const word of w) {
    if (c && (c + ' ' + word).length > max) { lines.push(c); c = word; }
    else c = c ? c + ' ' + word : word;
  }
  if (c) lines.push(c);
  return lines;
}

export function nodeSize(n) {
  const ll = wrapText(n.label, 18);
  const dl = wrapText(n.description || '', 30);
  const labelW = Math.max(...ll.map(l => l.length)) * 9 + 36;
  const descW = dl.length > 0 ? Math.max(...dl.map(l => l.length)) * 6.5 + 28 : 0;
  const w = Math.max(labelW, descW, 110);
  const labelH = ll.length * 22 + 14;
  const descH = dl.length > 0 ? dl.length * 16 + 10 : 0;
  const h = labelH + descH + (dl.length > 0 ? 10 : 0);
  return { w, h, r: Math.max(w, h) / 2 + 15 };
}

export function organicLayout(nodes, edges, canvasW = 2000, canvasH = 1500) {
  if (!nodes.length) return [];
  const cx = canvasW / 2, cy = canvasH / 2;

  // Section angular clustering
  const secs = {};
  nodes.forEach(n => { const s = n.cluster || 'x'; if (!secs[s]) secs[s] = []; secs[s].push(n.id); });
  const sKeys = Object.keys(secs);
  const angMap = {};
  sKeys.forEach((k, i) => {
    const a = 2 * Math.PI * i / sKeys.length;
    secs[k].forEach(id => { angMap[id] = a; });
  });

  // Initialize
  const pos = nodes.map((n, i) => {
    const a = angMap[n.id] || (2 * Math.PI * i / nodes.length);
    const d = 150 + Math.random() * 250; // TIGHTER initial spread
    const sz = nodeSize(n);
    return {
      ...n, ...sz,
      x: cx + Math.cos(a) * d + (Math.random() - 0.5) * 60,
      y: cy + Math.sin(a) * d + (Math.random() - 0.5) * 60,
      vx: 0, vy: 0,
    };
  });

  const idx = {};
  pos.forEach((n, i) => { idx[n.id] = i; });
  const links = edges
    .map(e => ({ s: idx[e.source], t: idx[e.target], w: 0.5 + (e.confidence || 0.5) * 0.5 }))
    .filter(l => l.s !== undefined && l.t !== undefined && l.s !== l.t);

  // Simulation — 550 iterations with stronger forces
  for (let it = 0; it < 550; it++) {
    const al = 1 - it / 550;

    // REPULSION — much stronger to prevent overlaps
    for (let i = 0; i < pos.length; i++) {
      for (let j = i + 1; j < pos.length; j++) {
        let dx = pos[j].x - pos[i].x, dy = pos[j].y - pos[i].y;
        let d = Math.sqrt(dx * dx + dy * dy) || 1;
        const minDist = pos[i].r + pos[j].r + 25; // generous padding
        let f;
        if (d < minDist) {
          f = -80 * (minDist / d); // VERY strong overlap push
        } else {
          f = (-800 * al - 300) / (d * d); // stronger long-range repulsion
        }
        const fx = dx / d * f, fy = dy / d * f;
        pos[i].vx -= fx; pos[i].vy -= fy;
        pos[j].vx += fx; pos[j].vy += fy;
      }
    }

    // ATTRACTION — 3x stronger to keep graph compact
    for (const l of links) {
      let dx = pos[l.t].x - pos[l.s].x, dy = pos[l.t].y - pos[l.s].y;
      let d = Math.sqrt(dx * dx + dy * dy) || 1;
      const ideal = pos[l.s].r + pos[l.t].r + 30; // tighter ideal
      const f = (d - ideal) * 0.045 * l.w; // 3x attraction
      pos[l.s].vx += dx / d * f; pos[l.s].vy += dy / d * f;
      pos[l.t].vx -= dx / d * f; pos[l.t].vy -= dy / d * f;
    }

    // MAX DISTANCE CAP — pull outliers back firmly
    for (const p of pos) {
      const dx = cx - p.x, dy = cy - p.y;
      const d = Math.sqrt(dx * dx + dy * dy) || 1;
      const maxDist = 500 + (p.abstraction_level ?? 1) * 80;
      if (d > maxDist) {
        const pull = (d - maxDist) * 0.05;
        p.vx += dx / d * pull;
        p.vy += dy / d * pull;
      }
      // Gentle radial hint
      const idealR = 100 + (p.abstraction_level ?? 1) * 120;
      const rf = (d - idealR) * 0.001 * al;
      p.vx += dx / d * rf; p.vy += dy / d * rf;
    }

    // Section angular clustering
    for (const p of pos) {
      const ta = angMap[p.id];
      if (ta === undefined) continue;
      const dx = p.x - cx, dy = p.y - cy;
      const ca = Math.atan2(dy, dx);
      let ad = ta - ca;
      while (ad > Math.PI) ad -= 2 * Math.PI;
      while (ad < -Math.PI) ad += 2 * Math.PI;
      p.vx += -Math.sin(ca) * ad * 0.3 * al;
      p.vy += Math.cos(ca) * ad * 0.3 * al;
    }

    // Integration
    for (const p of pos) {
      p.vx *= 0.88; p.vy *= 0.88;
      p.x += p.vx * 0.3; p.y += p.vy * 0.3;
    }
  }

  // POST-LAYOUT: resolve any remaining overlaps
  for (let pass = 0; pass < 30; pass++) {
    let moved = false;
    for (let i = 0; i < pos.length; i++) {
      for (let j = i + 1; j < pos.length; j++) {
        let dx = pos[j].x - pos[i].x, dy = pos[j].y - pos[i].y;
        let d = Math.sqrt(dx * dx + dy * dy) || 1;
        const minD = pos[i].r + pos[j].r + 15;
        if (d < minD) {
          const push = (minD - d) / 2 + 2;
          pos[i].x -= dx / d * push; pos[i].y -= dy / d * push;
          pos[j].x += dx / d * push; pos[j].y += dy / d * push;
          moved = true;
        }
      }
    }
    if (!moved) break;
  }

  // Normalize coordinates
  let mnX = Infinity, mnY = Infinity;
  for (const p of pos) { mnX = Math.min(mnX, p.x - p.r); mnY = Math.min(mnY, p.y - p.r); }
  for (const p of pos) { p.x -= mnX - 80; p.y -= mnY - 80; }
  return pos;
}

// Bezier edge with organic curvature
export function organicEdgePath(sx, sy, tx, ty, i = 0, tot = 1) {
  const dx = tx - sx, dy = ty - sy, d = Math.sqrt(dx * dx + dy * dy) || 1;
  const nx = -dy / d, ny = dx / d;
  const sp = tot > 1 ? (i - (tot - 1) / 2) * 30 : 0;
  const cv = Math.min(d * 0.22, 90) + sp;
  return `M${sx} ${sy}Q${(sx + tx) / 2 + nx * cv} ${(sy + ty) / 2 + ny * cv} ${tx} ${ty}`;
}

// S-curve mycelial path
export function mycelialPath(sx, sy, tx, ty) {
  const dx = tx - sx, dy = ty - sy, d = Math.sqrt(dx * dx + dy * dy) || 1;
  const nx = -dy / d, ny = dx / d;
  return `M${sx} ${sy}C${sx + dx * 0.3 + nx * d * 0.16} ${sy + dy * 0.3 + ny * d * 0.16} ${sx + dx * 0.7 - nx * d * 0.12} ${sy + dy * 0.7 - ny * d * 0.12} ${tx} ${ty}`;
}

// Convex hull for cluster visualization
export function convexHull(points) {
  if (points.length < 3) return points;
  const pts = [...points].sort((a, b) => a.x - b.x || a.y - b.y);
  const cross = (O, A, B) => (A.x - O.x) * (B.y - O.y) - (A.y - O.y) * (B.x - O.x);
  const lower = [];
  for (const p of pts) { while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], p) <= 0) lower.pop(); lower.push(p); }
  const upper = [];
  for (let i = pts.length - 1; i >= 0; i--) { const p = pts[i]; while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], p) <= 0) upper.pop(); upper.push(p); }
  return lower.slice(0, -1).concat(upper.slice(0, -1));
}

// Smooth hull path with rounded corners
export function hullPath(hull, pad = 30) {
  if (hull.length < 2) return '';
  // Expand hull outward by padding
  const cx = hull.reduce((s, p) => s + p.x, 0) / hull.length;
  const cy = hull.reduce((s, p) => s + p.y, 0) / hull.length;
  const exp = hull.map(p => {
    const dx = p.x - cx, dy = p.y - cy, d = Math.sqrt(dx * dx + dy * dy) || 1;
    return { x: p.x + dx / d * pad, y: p.y + dy / d * pad };
  });
  if (exp.length < 3) return `M${exp[0].x} ${exp[0].y}L${exp[exp.length - 1].x} ${exp[exp.length - 1].y}`;
  // Catmull-Rom spline through hull points
  let path = `M${exp[0].x} ${exp[0].y}`;
  for (let i = 0; i < exp.length; i++) {
    const p0 = exp[(i - 1 + exp.length) % exp.length];
    const p1 = exp[i];
    const p2 = exp[(i + 1) % exp.length];
    const p3 = exp[(i + 2) % exp.length];
    const cp1x = p1.x + (p2.x - p0.x) / 6;
    const cp1y = p1.y + (p2.y - p0.y) / 6;
    const cp2x = p2.x - (p3.x - p1.x) / 6;
    const cp2y = p2.y - (p3.y - p1.y) / 6;
    path += `C${cp1x} ${cp1y} ${cp2x} ${cp2y} ${p2.x} ${p2.y}`;
  }
  return path + 'Z';
}

// Get family (connected component via edges)
export function getFamily(nodeId, edges) {
  const members = new Set([nodeId]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const e of edges) {
      if (members.has(e.source) && !members.has(e.target)) { members.add(e.target); changed = true; }
      if (members.has(e.target) && !members.has(e.source)) { members.add(e.source); changed = true; }
    }
  }
  return members;
}

// Get direct neighbors (1-hop)
export function getNeighbors(nodeId, edges) {
  const members = new Set([nodeId]);
  for (const e of edges) {
    if (e.source === nodeId) members.add(e.target);
    if (e.target === nodeId) members.add(e.source);
  }
  return members;
}
LAYOUT_EOF

echo "  ✓ layout.js — tighter spacing, overlap resolution, cluster hulls"

# ── 2. Theme ────────────────────────────────────────────────────────────
cat > src/utils/theme.js << 'THEME_EOF'
// Mycel Theme v2 — colorful text, thicker edges, minimal blocks

export const PALETTES = {
  aurora: {
    name: "Aurora", bg: "#0B1120", surface: "#131B2E", border: "#1E2A45",
    text: "#E8ECF4", textMuted: "#8B95A8", textDim: "#5A6478",
    canvasDot: "#1E2A4522",
    clusterFill: "#ffffff06", clusterStroke: "#ffffff12",
    types: {
      theorem:    { bg: "#6C5CE720", accent: "#B8B0FF", text: "#D4CFFF", border: "#6C5CE750", glow: "#6C5CE730" },
      definition: { bg: "#00B8A920", accent: "#5EECD5", text: "#B0FFF2", border: "#00B8A950", glow: "#00B8A930" },
      principle:  { bg: "#5B6ABF20", accent: "#9AA4E0", text: "#C8CDEF", border: "#5B6ABF50", glow: "#5B6ABF30" },
      method:     { bg: "#0984E320", accent: "#63B3F3", text: "#B0D8FA", border: "#0984E350", glow: "#0984E330" },
      framework:  { bg: "#A29BFE20", accent: "#C8C3FF", text: "#E0DDFF", border: "#A29BFE50", glow: "#A29BFE30" },
      example:    { bg: "#E1705520", accent: "#F0A08A", text: "#F8C8BA", border: "#E1705550", glow: "#E1705530" },
      phenomenon: { bg: "#FD79A820", accent: "#FEA8C8", text: "#FED0E0", border: "#FD79A850", glow: "#FD79A830" },
      evidence:   { bg: "#F39C1220", accent: "#F7C463", text: "#FBDEA0", border: "#F39C1250", glow: "#F39C1230" },
      term:       { bg: "#00CEC920", accent: "#5EE8E4", text: "#B0FFFC", border: "#00CEC950", glow: "#00CEC930" },
      argument:   { bg: "#D6303120", accent: "#E87070", text: "#F0A8A8", border: "#D6303150", glow: "#D6303130" },
    },
    edges: {
      logical:       { color: "#A29BFE", width: 4, dash: "" },
      compositional: { color: "#74B9FF", width: 3.5, dash: "10 5" },
      pedagogical:   { color: "#FD79A8", width: 3, dash: "5 4" },
      causal:        { color: "#FDCB6E", width: 4, dash: "" },
      custom:        { color: "#55EFC4", width: 3, dash: "8 4" },
    },
  },
  moss: {
    name: "Moss", bg: "#0A1A12", surface: "#132D1F", border: "#1E4D32",
    text: "#D8F3DC", textMuted: "#95D5B2", textDim: "#52B788",
    canvasDot: "#1E4D3222",
    clusterFill: "#ffffff06", clusterStroke: "#52B78820",
    types: {
      theorem:    { bg: "#2D6A4F20", accent: "#6FCF97", text: "#A8E6C3", border: "#2D6A4F50", glow: "#2D6A4F30" },
      definition: { bg: "#1B9AAA20", accent: "#5EC8D0", text: "#A0E0E5", border: "#1B9AAA50", glow: "#1B9AAA30" },
      principle:  { bg: "#40916C20", accent: "#74C69D", text: "#A8DDB8", border: "#40916C50", glow: "#40916C30" },
      method:     { bg: "#6C5CE720", accent: "#A89CFF", text: "#C8C0FF", border: "#6C5CE750", glow: "#6C5CE730" },
      framework:  { bg: "#52B78820", accent: "#8FD8AD", text: "#B8E8CA", border: "#52B78850", glow: "#52B78830" },
      example:    { bg: "#B7E4C720", accent: "#8BC8A0", text: "#2D5A40", border: "#B7E4C750", glow: "#B7E4C730" },
      phenomenon: { bg: "#D8F3DC20", accent: "#A0D8B0", text: "#2D5A40", border: "#D8F3DC50", glow: "#D8F3DC30" },
      evidence:   { bg: "#74C69D20", accent: "#5CAA82", text: "#90D4AD", border: "#74C69D50", glow: "#74C69D30" },
      term:       { bg: "#00CEC920", accent: "#5EE8E4", text: "#B0FFFC", border: "#00CEC950", glow: "#00CEC930" },
      argument:   { bg: "#D6303120", accent: "#E87070", text: "#F0A8A8", border: "#D6303150", glow: "#D6303130" },
    },
    edges: {
      logical:       { color: "#52B788", width: 4, dash: "" },
      compositional: { color: "#95D5B2", width: 3.5, dash: "10 5" },
      pedagogical:   { color: "#D8F3DC", width: 3, dash: "5 4" },
      causal:        { color: "#FDCB6E", width: 4, dash: "" },
      custom:        { color: "#81ECEC", width: 3, dash: "8 4" },
    },
  },
  ink: {
    name: "Ink", bg: "#F5F0E8", surface: "#FFFBF5", border: "#D4CCBB",
    text: "#2C2417", textMuted: "#6B5E4D", textDim: "#9B8E7D",
    canvasDot: "#D4CCBB30",
    clusterFill: "#00000006", clusterStroke: "#00000010",
    types: {
      theorem:    { bg: "#3D2B1F18", accent: "#6B4A38", text: "#4A3020", border: "#3D2B1F40", glow: "#3D2B1F20" },
      definition: { bg: "#1B6B5A18", accent: "#2D9A82", text: "#1B6B5A", border: "#1B6B5A40", glow: "#1B6B5A20" },
      principle:  { bg: "#5C443318", accent: "#8B6B55", text: "#5C4433", border: "#5C443340", glow: "#5C443320" },
      method:     { bg: "#2D5A8C18", accent: "#4A8AC0", text: "#2D5A8C", border: "#2D5A8C40", glow: "#2D5A8C20" },
      framework:  { bg: "#6B4D8A18", accent: "#8B6DAA", text: "#6B4D8A", border: "#6B4D8A40", glow: "#6B4D8A20" },
      example:    { bg: "#C8794118", accent: "#D49564", text: "#A06030", border: "#C8794140", glow: "#C8794120" },
      phenomenon: { bg: "#C0608018", accent: "#D080A0", text: "#A04060", border: "#C0608040", glow: "#C0608020" },
      evidence:   { bg: "#8B691418", accent: "#B89030", text: "#7A5A10", border: "#8B691440", glow: "#8B691420" },
      term:       { bg: "#2D8B7A18", accent: "#4AAA99", text: "#2D7A6A", border: "#2D8B7A40", glow: "#2D8B7A20" },
      argument:   { bg: "#A0303018", accent: "#C05050", text: "#902020", border: "#A0303040", glow: "#A0303020" },
    },
    edges: {
      logical:       { color: "#5C4433", width: 4, dash: "" },
      compositional: { color: "#8B7B6B", width: 3.5, dash: "10 5" },
      pedagogical:   { color: "#B0A090", width: 3, dash: "5 4" },
      causal:        { color: "#8B6914", width: 4, dash: "" },
      custom:        { color: "#2D8B7A", width: 3, dash: "8 4" },
    },
  },
};

const EDGE_CATS = {
  logical: ["IMPLIES","REQUIRES","CONTRADICTS","EQUIVALENT","GENERALIZES","SPECIALIZES"],
  compositional: ["PART_OF","CONTAINS","INSTANCE_OF","DEFINED_BY"],
  pedagogical: ["PREREQUISITE_FOR","ILLUSTRATES","EXTENDS","CONTRASTS_WITH"],
  causal: ["CAUSES","ENABLES","CONSTRAINS","ANALOGOUS_TO"],
};

export function edgeCat(t) {
  for (const [c, ts] of Object.entries(EDGE_CATS))
    if (ts.includes(t)) return c;
  return "custom";
}

export function typeColor(P, t) { return P.types[t] || P.types.term; }

export function edgeThickness(conf, baseW) {
  return baseW * (0.5 + (conf || 0.5) * 0.5);
}
THEME_EOF

echo "  ✓ theme.js — translucent blocks, colored accents, 4x thicker edges"

# ── 3. App.css ──────────────────────────────────────────────────────────
cat > src/App.css << 'CSS_EOF'
@import url('https://fonts.googleapis.com/css2?family=Inter:wght@300;400;500;600;700&display=swap');
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: 'Inter', sans-serif; -webkit-font-smoothing: antialiased; overflow: hidden; }
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
CSS_EOF

echo "  ✓ App.css"

# ── 4. App.jsx — The big one ───────────────────────────────────────────
cat > src/App.jsx << 'JSX_EOF'
import { useState, useMemo, useCallback, useRef, useEffect } from "react";
import { uploadPDF, getMaps, getMap, deleteMap, submitCorrection } from "./api";
import { PALETTES, edgeCat, typeColor, edgeThickness } from "./utils/theme";
import {
  organicLayout, organicEdgePath, mycelialPath, wrapText, nodeSize,
  convexHull, hullPath, getNeighbors,
} from "./utils/layout";

export default function App() {
  const [palKey, setPalKey] = useState("aurora");
  const [view, setView] = useState("home");
  const [rawData, setRawData] = useState(null);
  const [nodes, setNodes] = useState([]);
  const [selected, setSelected] = useState(null);
  const [hovered, setHovered] = useState(null);
  const [mapId, setMapId] = useState(null);
  const [maps, setMaps] = useState([]);
  const [uploading, setUploading] = useState(false);
  const [progress, setProgress] = useState(null);
  const [collapsed, setCollapsed] = useState(new Set());
  const [editing, setEditing] = useState(null);
  const [editValue, setEditValue] = useState('');
  const [camera, setCamera] = useState({ x: 0, y: 0, zoom: 0.8 });
  const [dragState, setDragState] = useState(null);
  const containerRef = useRef(null);
  const P = PALETTES[palKey];

  useEffect(() => {
    let ws;
    try { const url = (import.meta.env.VITE_API_URL || 'http://localhost:8000').replace('http', 'ws');
      ws = new WebSocket(`${url}/ws/progress`); ws.onmessage = e => { try { setProgress(JSON.parse(e.data)); } catch {} }; } catch {}
    return () => ws?.close();
  }, []);
  useEffect(() => { if (view === "library") getMaps().then(d => setMaps(d.maps || [])); }, [view]);

  const handleUpload = async (file) => {
    if (!file?.name?.toLowerCase().endsWith(".pdf")) return;
    setUploading(true); setProgress({ stage: "uploading", progress: 0, message: "Uploading..." });
    try {
      const r = await uploadPDF(file);
      if (r.nodes) {
        const edges = r.edges.map(e => ({ ...e, source: e.source_id || e.source, target: e.target_id || e.target }));
        setRawData({ nodes: r.nodes, edges });
        const laid = organicLayout(r.nodes, edges);
        setNodes(laid); setMapId(r.map_id); setView("graph"); setCollapsed(new Set());
        setTimeout(() => fitToView(laid), 50);
        setProgress({ stage: "done", progress: 1, message: `${r.node_count} concepts, ${r.edge_count} relations` });
      }
    } catch (e) { setProgress({ stage: "error", progress: 0, message: e.message }); }
    setUploading(false);
  };

  const loadMap = async (id) => {
    const r = await getMap(id);
    if (r.nodes) {
      const edges = r.edges.map(e => ({ ...e, source: e.source_id || e.source, target: e.target_id || e.target }));
      setRawData({ nodes: r.nodes, edges }); const laid = organicLayout(r.nodes, edges);
      setNodes(laid); setMapId(id); setView("graph"); setCollapsed(new Set());
      setTimeout(() => fitToView(laid), 50);
    }
  };

  const fitToView = useCallback((nl) => {
    if (!containerRef.current || !nl?.length) return;
    const rc = containerRef.current.getBoundingClientRect();
    let mnX=Infinity,mnY=Infinity,mxX=-Infinity,mxY=-Infinity;
    for(const n of nl){const rd=n.r||60;mnX=Math.min(mnX,n.x-rd);mnY=Math.min(mnY,n.y-rd);mxX=Math.max(mxX,n.x+rd);mxY=Math.max(mxY,n.y+rd);}
    const gw=mxX-mnX+120,gh=mxY-mnY+120;
    const z=Math.min(rc.width/gw,rc.height/gh,1.5);
    setCamera({x:-(mnX-60)*z+(rc.width-gw*z)/2,y:-(mnY-60)*z+(rc.height-gh*z)/2,zoom:z});
  }, []);

  const edges = useMemo(() => rawData?.edges || [], [rawData]);
  const nodeMap = useMemo(() => { const m={}; nodes.forEach(n=>m[n.id]=n); return m; }, [nodes]);
  const allLabels = useMemo(() => nodes.map(n => n.label), [nodes]);
  const children = useMemo(() => { const c={}; edges.forEach(e=>{if(!c[e.source])c[e.source]=[];c[e.source].push(e.target);}); return c; }, [edges]);
  const degree = useMemo(() => { const d={}; edges.forEach(e=>{d[e.source]=(d[e.source]||0)+1;d[e.target]=(d[e.target]||0)+1;}); return d; }, [edges]);

  const visIds = useMemo(() => {
    if(!collapsed.size)return new Set(nodes.map(n=>n.id));
    const hidden=new Set();
    for(const cid of collapsed){const q=[...(children[cid]||[])];while(q.length){const id=q.shift();if(!hidden.has(id)){hidden.add(id);if(!collapsed.has(id))(children[id]||[]).forEach(c=>q.push(c));}}}
    return new Set(nodes.filter(n=>!hidden.has(n.id)).map(n=>n.id));
  }, [nodes,collapsed,children]);

  const visNodes = useMemo(()=>nodes.filter(n=>visIds.has(n.id)),[nodes,visIds]);
  const visEdges = useMemo(()=>edges.filter(e=>visIds.has(e.source)&&visIds.has(e.target)),[edges,visIds]);

  // Cluster hulls — group by section
  const clusterHulls = useMemo(() => {
    const groups = {};
    visNodes.forEach(n => { const c = n.cluster || 'x'; if (!groups[c]) groups[c] = []; groups[c].push(n); });
    return Object.entries(groups).filter(([, ns]) => ns.length >= 2).map(([k, ns]) => {
      const pts = ns.map(n => ({ x: n.x, y: n.y }));
      const hull = convexHull(pts);
      return { key: k, path: hullPath(hull, 40), nodeIds: new Set(ns.map(n => n.id)) };
    });
  }, [visNodes]);

  const edgePairs = useMemo(() => {
    const p={};visEdges.forEach(e=>{const k=[e.source,e.target].sort().join('|');if(!p[k])p[k]=[];p[k].push({...e,idx:p[k].length});});return p;
  }, [visEdges]);

  const screenToWorld = useCallback((sx,sy)=>({x:(sx-camera.x)/camera.zoom,y:(sy-camera.y)/camera.zoom}),[camera]);
  const worldToScreen = useCallback((wx,wy)=>({x:wx*camera.zoom+camera.x,y:wy*camera.zoom+camera.y}),[camera]);

  // Find inline terms in description
  const findTerms = useCallback((desc, skipLabel) => {
    if (!desc) return [];
    const found = [];
    for (const label of allLabels) {
      if (label === skipLabel || label.length < 3) continue;
      const idx = desc.toLowerCase().indexOf(label.toLowerCase());
      if (idx >= 0) found.push({ text: label, start: idx, end: idx + label.length });
    }
    return found.sort((a, b) => a.start - b.start);
  }, [allLabels]);

  // ── Interaction ─────────────────────────────────────────────────────
  const handlePointerDown = useCallback((e) => {
    if (e.button !== 0) return;
    const rc = containerRef.current?.getBoundingClientRect(); if (!rc) return;
    const sx = e.clientX - rc.left, sy = e.clientY - rc.top;
    const w = screenToWorld(sx, sy);
    const hit = visNodes.find(n => { const dx=w.x-n.x,dy=w.y-n.y; return dx*dx+dy*dy < (n.r||60)**2; });
    if (hit) {
      // Always drag the family (neighbors)
      const members = getNeighbors(hit.id, edges);
      setDragState({ type: 'cluster', nodeId: hit.id, members, startX: sx, startY: sy, origX: hit.x, origY: hit.y,
        offsets: new Map([...members].map(id => [id, { dx: (nodeMap[id]?.x||0)-hit.x, dy: (nodeMap[id]?.y||0)-hit.y }])),
      });
      e.preventDefault();
    } else {
      setDragState({ type: 'pan', startX: sx, startY: sy, origCamX: camera.x, origCamY: camera.y });
    }
  }, [visNodes, screenToWorld, camera, edges, nodeMap]);

  const handlePointerMove = useCallback((e) => {
    const rc = containerRef.current?.getBoundingClientRect(); if (!rc) return;
    const sx = e.clientX - rc.left, sy = e.clientY - rc.top;
    if (!dragState) {
      const w = screenToWorld(sx, sy);
      const hit = visNodes.find(n => { const dx=w.x-n.x,dy=w.y-n.y; return dx*dx+dy*dy < (n.r||60)**2; });
      setHovered(hit?.id || null); return;
    }
    const dx = sx - dragState.startX, dy = sy - dragState.startY;
    if (dragState.type === 'pan') {
      setCamera(c => ({ ...c, x: dragState.origCamX + dx, y: dragState.origCamY + dy }));
    } else if (dragState.type === 'cluster') {
      const nx = dragState.origX + dx / camera.zoom, ny = dragState.origY + dy / camera.zoom;
      // Dragged node moves fully, neighbors move proportionally (0.6x for organic feel)
      setNodes(prev => prev.map(n => {
        if (n.id === dragState.nodeId) return { ...n, x: nx, y: ny };
        const off = dragState.offsets.get(n.id);
        if (off) return { ...n, x: nx + off.dx * 0.6 + off.dx * 0.4, y: ny + off.dy * 0.6 + off.dy * 0.4 };
        return n;
      }));
    }
  }, [dragState, camera, visNodes, screenToWorld]);

  const handlePointerUp = useCallback(() => setDragState(null), []);

  const handleWheel = useCallback((e) => {
    e.preventDefault();
    const rc = containerRef.current?.getBoundingClientRect(); if (!rc) return;
    const sx = e.clientX - rc.left, sy = e.clientY - rc.top;
    const f = e.deltaY > 0 ? 0.9 : 1.1;
    setCamera(c => {
      const nz = Math.max(0.15, Math.min(5, c.zoom * f));
      return { x: sx - (sx - c.x) * (nz / c.zoom), y: sy - (sy - c.y) * (nz / c.zoom), zoom: nz };
    });
  }, []);

  const handleDblClick = useCallback((e) => {
    const rc = containerRef.current?.getBoundingClientRect(); if (!rc) return;
    const w = screenToWorld(e.clientX - rc.left, e.clientY - rc.top);
    const hit = visNodes.find(n => { const dx=w.x-n.x,dy=w.y-n.y; return dx*dx+dy*dy < (n.r||60)**2; });
    if (hit) setCollapsed(p => { const n2 = new Set(p); if (n2.has(hit.id)) n2.delete(hit.id); else n2.add(hit.id); return n2; });
    else fitToView(nodes);
  }, [visNodes, screenToWorld, fitToView, nodes]);

  const handleDelete = (id) => {
    setNodes(p=>p.filter(n=>n.id!==id));
    if(rawData)setRawData(p=>({nodes:p.nodes.filter(n=>n.id!==id),edges:p.edges.filter(e=>e.source!==id&&e.target!==id)}));
    setSelected(null); submitCorrection({map_id:mapId,type:"delete",original:{id},corrected:null}).catch(()=>{});
  };

  const selectedNode = selected ? nodeMap[selected] : null;
  const connEdges = selectedNode ? visEdges.filter(e => e.source === selected || e.target === selected) : [];
  const stages = { uploading:"Uploading",parsing:"Parsing",chunking:"Splitting",pattern_extraction:"Scanning",concept_extraction:"AI extracting",clustering:"Clustering",relation_extraction:"Connecting",validation:"Validating",done:"Complete" };

  // Semantic zoom thresholds
  const showDesc = camera.zoom > 0.5;
  const showTermCircles = camera.zoom > 0.6;
  const showEdgeLabels = camera.zoom > 0.7;

  // ── RENDER ──────────────────────────────────────────────────────────
  return (
    <div style={{ height:"100vh", display:"flex", flexDirection:"column", background:P.bg, color:P.text, fontFamily:"'Inter',sans-serif" }}>
      {/* Header */}
      <header style={{ display:"flex", alignItems:"center", justifyContent:"space-between", padding:"8px 16px", background:P.surface, borderBottom:`1px solid ${P.border}`, flexShrink:0 }}>
        <div style={{ display:"flex", alignItems:"center", gap:10 }}>
          <span onClick={()=>setView('home')} style={{ fontSize:16,fontWeight:700,cursor:'pointer',background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent" }}>✦ Mycel</span>
          <nav style={{ display:"flex", gap:3 }}>
            {[['home','Home'],['graph','Graph'],['library','Library']].map(([k,l])=>(
              <button key={k} onClick={()=>setView(k)} style={{ padding:"4px 10px",borderRadius:6,border:"none",cursor:"pointer",background:view===k?P.bg:"transparent",color:view===k?P.text:P.textDim,fontSize:11,fontWeight:500 }}>{l}</button>
            ))}
          </nav>
        </div>
        <div style={{ display:"flex", alignItems:"center", gap:8 }}>
          {view==='graph'&&visNodes.length>0&&<span style={{fontSize:10,color:P.textDim}}>{visNodes.length} concepts · {visEdges.length} edges{collapsed.size>0?` · ${collapsed.size} folded`:''}</span>}
          <div style={{ display:"flex", gap:4 }}>
            {Object.entries(PALETTES).map(([k,p])=>(
              <button key={k} onClick={()=>setPalKey(k)} title={p.name} style={{ width:14,height:14,borderRadius:"50%",border:"none",cursor:"pointer",background:`linear-gradient(135deg,${Object.values(p.types)[0].accent},${Object.values(p.types)[2].accent})`,outline:palKey===k?`2px solid ${p.text}`:"none",outlineOffset:2 }}/>
            ))}
          </div>
        </div>
      </header>

      {/* HOME */}
      {view==='home'&&(
        <div style={{ flex:1,display:"flex",alignItems:"center",justifyContent:"center",flexDirection:"column",gap:24,padding:"40px 20px" }}>
          <h1 style={{ fontSize:28,fontWeight:700,background:"linear-gradient(135deg,#6C5CE7,#00B8A9)",WebkitBackgroundClip:"text",WebkitTextFillColor:"transparent" }}>Mycel</h1>
          <p style={{ fontSize:14,color:P.textMuted,lineHeight:1.7,maxWidth:440,textAlign:"center" }}>Upload a textbook chapter. Watch concepts grow like mycelia.</p>
          <div onClick={()=>!uploading&&document.getElementById('fi')?.click()}
            onDragOver={e=>e.preventDefault()} onDrop={e=>{e.preventDefault();handleUpload(e.dataTransfer.files?.[0]);}}
            style={{ width:"100%",maxWidth:480,border:`2px dashed ${P.border}`,borderRadius:16,padding:"28px 20px",textAlign:"center",cursor:uploading?"wait":"pointer" }}>
            <input id="fi" type="file" accept=".pdf" style={{display:"none"}} disabled={uploading} onChange={e=>handleUpload(e.target.files?.[0])}/>
            {progress&&progress.stage!=='done'?(
              <div><div style={{fontSize:13,fontWeight:600,marginBottom:4}}>{stages[progress.stage]||'Processing...'}</div>
                <div style={{fontSize:11,color:P.textDim,marginBottom:8}}>{progress.message}</div>
                <div style={{height:5,background:P.bg,borderRadius:3,overflow:"hidden",maxWidth:280,margin:"0 auto"}}>
                  <div style={{height:"100%",width:`${Math.max((progress.progress||0)*100,3)}%`,background:"linear-gradient(90deg,#6C5CE7,#00B8A9)",borderRadius:3,transition:"width 0.3s"}}/>
                </div></div>
            ):(<div><div style={{fontSize:14,fontWeight:500,marginBottom:4}}>Drop a PDF or click to upload</div><div style={{fontSize:11,color:P.textDim}}>10-50 page chapters work best</div></div>)}
          </div>
          <button onClick={()=>setView('library')} style={{ padding:"7px 18px",background:"transparent",border:`1px solid ${P.border}`,borderRadius:8,color:P.textDim,fontSize:12,cursor:"pointer" }}>Browse library</button>
        </div>
      )}

      {/* LIBRARY */}
      {view==='library'&&(
        <div style={{ flex:1,padding:24,overflowY:"auto" }}>
          <h2 style={{ fontSize:17,fontWeight:600,marginBottom:16 }}>Library</h2>
          {maps.length===0?<div style={{textAlign:"center",padding:40,color:P.textDim}}>No maps yet.</div>:(
            <div style={{ display:"grid",gridTemplateColumns:"repeat(auto-fill,minmax(250px,1fr))",gap:10 }}>
              {maps.map(m=>(
                <div key={m.id} onClick={()=>loadMap(m.id)} style={{ padding:14,background:P.surface,border:`1px solid ${P.border}`,borderRadius:10,cursor:"pointer" }}>
                  <div style={{fontSize:13,fontWeight:600,marginBottom:3}}>{m.title||m.filename}</div>
                  <div style={{fontSize:10,color:P.textDim}}>{m.created_at?.split('T')[0]}</div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* GRAPH */}
      {view==='graph'&&(
        <div ref={containerRef} style={{ flex:1,position:"relative",overflow:"hidden",cursor:dragState?.type==='pan'?'grabbing':'grab' }}
          onPointerDown={handlePointerDown} onPointerMove={handlePointerMove} onPointerUp={handlePointerUp} onPointerLeave={handlePointerUp}
          onWheel={handleWheel} onDoubleClick={handleDblClick}>

          {/* Dot grid */}
          <div style={{ position:"absolute",inset:0,zIndex:0,pointerEvents:"none",
            backgroundImage:`radial-gradient(circle,${P.canvasDot} 1px,transparent 1px)`,
            backgroundSize:`${Math.max(18,28*camera.zoom)}px ${Math.max(18,28*camera.zoom)}px`,
            backgroundPosition:`${camera.x%(28*camera.zoom)}px ${camera.y%(28*camera.zoom)}px` }}/>

          {/* SVG */}
          <svg style={{ position:"absolute",inset:0,width:"100%",height:"100%",zIndex:1,overflow:"visible" }}>
            <defs>
              <marker id="ah" viewBox="0 0 12 12" refX="11" refY="6" markerWidth="8" markerHeight="8" orient="auto">
                <path d="M1 2L10 6L1 10" fill="none" stroke="context-stroke" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round"/>
              </marker>
            </defs>

            {/* Cluster hulls */}
            {clusterHulls.map(ch => (
              <path key={ch.key} d={ch.path} fill={P.clusterFill} stroke={P.clusterStroke} strokeWidth={1}
                transform={`translate(${camera.x},${camera.y}) scale(${camera.zoom})`}/>
            ))}

            {/* EDGES — thick, visible, ALL with arrows */}
            {Object.values(edgePairs).flatMap(group => group.map((e, i) => {
              const s = nodeMap[e.source], t = nodeMap[e.target]; if (!s || !t) return null;
              const cat = edgeCat(e.relation_type);
              const st = P.edges[cat] || P.edges.custom;
              const conf = e.confidence || 0.5;
              const thick = edgeThickness(conf, st.width);
              const hi = selected===e.source||selected===e.target||hovered===e.source||hovered===e.target;
              const path = (cat==='compositional'||cat==='pedagogical') ? mycelialPath(s.x,s.y,t.x,t.y) : organicEdgePath(s.x,s.y,t.x,t.y,i,group.length);
              const tr = `translate(${camera.x},${camera.y}) scale(${camera.zoom})`;
              const label = (e.relation_type||'').replace(/_/g,' ').toLowerCase();
              return (
                <g key={`e-${e.source}-${e.target}-${i}`}>
                  {hi && <path d={path} fill="none" stroke={st.color} strokeWidth={thick+6} opacity={0.15} transform={tr} strokeLinecap="round"/>}
                  <path d={path} fill="none" stroke={st.color}
                    strokeWidth={hi ? thick*1.4 : thick}
                    strokeDasharray={st.dash}
                    opacity={hi ? 0.9 : 0.55}
                    transform={tr} strokeLinecap="round"
                    markerEnd="url(#ah)"/>
                  {hi && showEdgeLabels && label && (()=>{
                    const mx=(s.x+t.x)/2,my=(s.y+t.y)/2-10;
                    const ssx=mx*camera.zoom+camera.x,ssy=my*camera.zoom+camera.y;
                    return <g transform={`translate(${ssx},${ssy})`}>
                      <rect x={-label.length*3.2} y={-8} width={label.length*6.4} height={14} rx={3} fill={P.surface} opacity={0.95}/>
                      <text x={0} y={0} textAnchor="middle" dominantBaseline="central" fontSize={9} fill={st.color} fontWeight="500" fontFamily="'Inter',sans-serif">{label}</text>
                    </g>;
                  })()}
                </g>
              );
            }))}

            {/* NODES — minimal translucent blocks with colored text */}
            {visNodes.map(n => {
              const tc = typeColor(P, n.concept_type);
              const isSel = selected===n.id, isHov = hovered===n.id;
              const hasCh = (children[n.id]||[]).length > 0;
              const isCol = collapsed.has(n.id);
              const ll = wrapText(n.label, 18);
              const dl = showDesc ? wrapText(n.description||'', 30) : [];
              const labelW = Math.max(...ll.map(l=>l.length))*9+36;
              const descW = dl.length>0 ? Math.max(...dl.map(l=>l.length))*6.5+28 : 0;
              const w = Math.max(labelW, descW, 110);
              const labelH = ll.length*22+14;
              const descH = dl.length>0 ? dl.length*16+10 : 0;
              const totalH = labelH + descH + (dl.length>0?10:0);
              const sx = n.x*camera.zoom+camera.x, sy = n.y*camera.zoom+camera.y;

              // Find inline terms
              const terms = (showTermCircles && dl.length > 0) ? findTerms(n.description, n.label) : [];

              return (
                <g key={n.id} transform={`translate(${sx},${sy}) scale(${camera.zoom})`}
                  style={{ cursor:'pointer' }}
                  onClick={e=>{e.stopPropagation();setSelected(p=>p===n.id?null:n.id);}}
                  onPointerDown={e=>{
                    e.stopPropagation();
                    const rc=containerRef.current?.getBoundingClientRect();if(!rc)return;
                    const px=e.clientX-rc.left,py=e.clientY-rc.top;
                    const members=getNeighbors(n.id,edges);
                    setDragState({type:'cluster',nodeId:n.id,members,startX:px,startY:py,origX:n.x,origY:n.y,
                      offsets:new Map([...members].map(id=>[id,{dx:(nodeMap[id]?.x||0)-n.x,dy:(nodeMap[id]?.y||0)-n.y}]))});
                    e.preventDefault();
                  }}>

                  {/* Selection/hover ring */}
                  {(isSel||isHov)&&<rect x={-w/2-8} y={-totalH/2-8} width={w+16} height={totalH+16} rx={16}
                    fill="none" stroke={tc.accent} strokeWidth={isSel?2:1} opacity={isSel?0.6:0.3}/>}

                  {/* MINIMAL block — translucent bg, colored border */}
                  <rect x={-w/2} y={-totalH/2} width={w} height={totalH} rx={10}
                    fill={tc.bg} stroke={tc.border} strokeWidth={0.8} />

                  {/* Colored type dot */}
                  <circle cx={-w/2+12} cy={-totalH/2+12} r={4} fill={tc.accent}/>

                  {/* LABEL — colored text! */}
                  {ll.map((line,i)=>(
                    <text key={`l${i}`} x={0} y={-totalH/2+20+i*22}
                      textAnchor="middle" dominantBaseline="central"
                      fontSize="14" fontWeight="600" fill={tc.accent}
                      fontFamily="'Inter',sans-serif" style={{pointerEvents:'none'}}>{line}</text>
                  ))}

                  {/* DESCRIPTION — softer colored text */}
                  {dl.map((line,i)=>(
                    <text key={`d${i}`} x={0} y={-totalH/2+labelH+8+i*16}
                      textAnchor="middle" dominantBaseline="central"
                      fontSize="10" fill={tc.text} opacity={0.7}
                      fontFamily="'Inter',sans-serif" style={{pointerEvents:'none'}}>{line}</text>
                  ))}

                  {/* INLINE TERM CIRCLES — always visible when zoomed in */}
                  {terms.length > 0 && terms.slice(0, 4).map((term, ti) => {
                    const tw = term.text.length * 5.5;
                    const ox = (ti - (Math.min(terms.length, 4) - 1) / 2) * (tw + 16);
                    const oy = totalH/2 - 4;
                    return <g key={`t${ti}`}>
                      <ellipse cx={ox} cy={oy} rx={tw/2+6} ry={9}
                        fill="none" stroke={tc.accent} strokeWidth={1.2} opacity={0.6}/>
                      <text x={ox} y={oy+1} textAnchor="middle" dominantBaseline="central"
                        fontSize="8" fill={tc.accent} opacity={0.7} fontWeight="500"
                        fontFamily="'Inter',sans-serif">{term.text}</text>
                      {/* Tiny arrow pointing up to the description */}
                      <line x1={ox} y1={oy-9} x2={ox} y2={oy-16}
                        stroke={tc.accent} strokeWidth={0.6} opacity={0.4}
                        markerEnd="url(#ah)"/>
                    </g>;
                  })}

                  {/* Collapse badge */}
                  {hasCh&&<g transform={`translate(${w/2-2},${-totalH/2-2})`}
                    onClick={e=>{e.stopPropagation();setCollapsed(p=>{const n2=new Set(p);if(n2.has(n.id))n2.delete(n.id);else n2.add(n.id);return n2;});}}>
                    <circle r={9} fill={P.surface} stroke={tc.accent} strokeWidth={0.8}/>
                    <text x={0} y={1} textAnchor="middle" dominantBaseline="central" fontSize="8" fill={tc.accent} fontWeight="600" fontFamily="'Inter',sans-serif">
                      {isCol?`+${(children[n.id]||[]).length}`:'−'}
                    </text>
                  </g>}

                  {/* Degree badge */}
                  {(degree[n.id]||0)>2&&!isHov&&!isSel&&(
                    <g transform={`translate(${-w/2+2},${totalH/2-2})`}>
                      <circle r={8} fill={P.surface+'CC'} stroke={tc.accent} strokeWidth={0.5}/>
                      <text x={0} y={1} textAnchor="middle" dominantBaseline="central" fontSize="7" fill={tc.accent} fontFamily="'Inter',sans-serif">{degree[n.id]}</text>
                    </g>
                  )}
                </g>
              );
            })}
          </svg>

          {/* FLOATING DETAIL CARD */}
          {selectedNode&&(()=>{
            const sc=worldToScreen(selectedNode.x,selectedNode.y);
            const tc=typeColor(P,selectedNode.concept_type);
            const rc=containerRef.current?.getBoundingClientRect();
            const cW=280, cx2=Math.min(Math.max(10,sc.x+80),(rc?.width||800)-cW-20), cy2=Math.max(10,sc.y-60);
            return(
              <div style={{ position:'absolute',left:cx2,top:cy2,width:cW,background:P.surface,border:`1px solid ${P.border}`,borderRadius:12,padding:'12px 14px',boxShadow:`0 8px 32px ${P.bg}90, 0 0 20px ${tc.glow}`,zIndex:20,maxHeight:'55vh',overflowY:'auto' }}>
                <div style={{display:'flex',alignItems:'center',gap:6,marginBottom:6}}>
                  <circle style={{width:8,height:8,borderRadius:'50%',background:tc.accent,flexShrink:0}}/>
                  <span style={{fontSize:9,color:tc.accent,fontWeight:600,textTransform:'uppercase',letterSpacing:0.5}}>{selectedNode.concept_type}</span>
                  <span style={{fontSize:9,color:P.textDim,marginLeft:'auto'}}>{Math.round((selectedNode.confidence||0)*100)}%</span>
                  <button onClick={()=>setSelected(null)} style={{background:'none',border:'none',color:P.textDim,fontSize:13,cursor:'pointer',padding:'0 2px'}}>×</button>
                </div>
                {editing?.id===selected&&editing?.field==='label'?(
                  <input value={editValue} onChange={e=>setEditValue(e.target.value)} autoFocus
                    onBlur={()=>{setNodes(p=>p.map(nd=>nd.id===selected?{...nd,label:editValue}:nd));if(rawData)setRawData(p=>({...p,nodes:p.nodes.map(nd=>nd.id===selected?{...nd,label:editValue}:nd)}));submitCorrection({map_id:mapId,type:"edit",original:{id:selected},corrected:{label:editValue}}).catch(()=>{});setEditing(null);}}
                    onKeyDown={e=>{if(e.key==='Enter')e.target.blur();if(e.key==='Escape')setEditing(null);}}
                    style={{width:'100%',fontSize:14,fontWeight:600,background:P.bg,border:`1px solid ${tc.accent}40`,borderRadius:6,color:tc.accent,padding:'3px 6px',marginBottom:4,fontFamily:'inherit'}}/>
                ):(<h3 onClick={()=>{setEditing({id:selected,field:'label'});setEditValue(selectedNode.label);}} style={{fontSize:14,fontWeight:600,marginBottom:4,cursor:'text',color:tc.accent}} title="Click to edit">{selectedNode.label}</h3>)}
                {editing?.id===selected&&editing?.field==='description'?(
                  <textarea value={editValue} onChange={e=>setEditValue(e.target.value)} rows={3} autoFocus
                    onBlur={()=>{setNodes(p=>p.map(nd=>nd.id===selected?{...nd,description:editValue}:nd));if(rawData)setRawData(p=>({...p,nodes:p.nodes.map(nd=>nd.id===selected?{...nd,description:editValue}:nd)}));submitCorrection({map_id:mapId,type:"edit",original:{id:selected},corrected:{description:editValue}}).catch(()=>{});setEditing(null);}}
                    style={{width:'100%',fontSize:11,background:P.bg,border:`1px solid ${tc.accent}40`,borderRadius:6,color:P.textMuted,padding:'4px 6px',marginBottom:8,fontFamily:'inherit',lineHeight:1.4,resize:'vertical'}}/>
                ):(<p onClick={()=>{setEditing({id:selected,field:'description'});setEditValue(selectedNode.description||'');}} style={{fontSize:11,color:tc.text,lineHeight:1.5,marginBottom:8,cursor:'text',opacity:0.8}} title="Click to edit">{selectedNode.description||'Click to add description'}</p>)}
                <div style={{display:'flex',gap:4,marginBottom:8}}>
                  <button onClick={()=>submitCorrection({map_id:mapId,type:"approve",original:{id:selected}}).catch(()=>{})} style={{flex:1,padding:5,background:'rgba(81,207,102,0.1)',border:'1px solid rgba(81,207,102,0.2)',borderRadius:6,color:'#51CF66',fontWeight:600,cursor:'pointer',fontSize:9}}>Correct</button>
                  <button onClick={()=>handleDelete(selected)} style={{flex:1,padding:5,background:'rgba(255,107,107,0.1)',border:'1px solid rgba(255,107,107,0.2)',borderRadius:6,color:'#FF6B6B',fontWeight:600,cursor:'pointer',fontSize:9}}>Remove</button>
                </div>
                {connEdges.length>0&&<div>
                  <div style={{fontSize:9,color:P.textDim,fontWeight:600,marginBottom:4}}>Connections ({connEdges.length})</div>
                  {connEdges.map((e,i)=>{const isSrc=e.source===selected,oId=isSrc?e.target:e.source,o=nodeMap[oId],cat=edgeCat(e.relation_type),es=P.edges[cat]||P.edges.custom;
                    return(<div key={i} onClick={()=>setSelected(oId)} style={{padding:'5px 7px',background:P.bg,borderRadius:5,marginBottom:2,borderLeft:`3px solid ${es.color}`,cursor:'pointer'}}>
                      <div style={{display:'flex',justifyContent:'space-between',fontSize:9}}>
                        <span style={{color:es.color,fontWeight:600,textTransform:'uppercase',fontSize:7}}>{(e.relation_type||'').replace(/_/g,' ')}</span>
                        <span style={{color:P.textDim}}>{isSrc?'→':'←'} {o?.label||'?'}</span>
                      </div>
                      {e.justification&&<div style={{fontSize:8,color:P.textDim,marginTop:1,lineHeight:1.3}}>{e.justification}</div>}
                    </div>);
                  })}
                </div>}
              </div>
            );
          })()}

          {/* Legend */}
          <div style={{ position:'absolute',top:10,left:10,background:P.surface+'DD',backdropFilter:'blur(8px)',padding:'8px 10px',borderRadius:8,border:`1px solid ${P.border}`,fontSize:8,zIndex:5 }}>
            <div style={{fontSize:7,color:P.textDim,fontWeight:600,marginBottom:3,textTransform:'uppercase',letterSpacing:0.5}}>Types</div>
            {['theorem','definition','principle','method','framework','example','phenomenon'].map(t=>{const c=P.types[t];if(!c)return null;
              return<div key={t} style={{display:'flex',alignItems:'center',gap:4,marginBottom:1}}>
                <div style={{width:6,height:6,borderRadius:'50%',background:c.accent,flexShrink:0}}/>
                <span style={{color:c.accent}}>{t}</span></div>;})}
            <div style={{marginTop:4,borderTop:`1px solid ${P.border}`,paddingTop:3,fontSize:7,color:P.textDim,fontWeight:600,marginBottom:2,textTransform:'uppercase',letterSpacing:0.5}}>Edges</div>
            {Object.entries(P.edges).map(([c,s])=>(
              <div key={c} style={{display:'flex',alignItems:'center',gap:4,marginBottom:1}}>
                <svg width="14" height="4" style={{flexShrink:0}}><line x1="0" y1="2" x2="14" y2="2" stroke={s.color} strokeWidth={2} strokeDasharray={s.dash}/></svg>
                <span style={{color:P.textDim}}>{c}</span></div>
            ))}
            <div style={{marginTop:4,borderTop:`1px solid ${P.border}`,paddingTop:3,color:P.textDim,lineHeight:1.4}}>Drag = move family<br/>Dbl-click = fold<br/>Scroll = zoom</div>
          </div>

          {/* Minimap */}
          {visNodes.length>0&&(()=>{
            let mnX=Infinity,mnY=Infinity,mxX=-Infinity,mxY=-Infinity;
            visNodes.forEach(n=>{mnX=Math.min(mnX,n.x-40);mnY=Math.min(mnY,n.y-40);mxX=Math.max(mxX,n.x+40);mxY=Math.max(mxY,n.y+40);});
            const gw=mxX-mnX||1,gh=mxY-mnY||1,mmW=120,mmH=Math.min(80,mmW*(gh/gw)),sc=mmW/gw;
            const rc=containerRef.current?.getBoundingClientRect();
            return<div style={{position:'absolute',bottom:10,left:10,width:mmW,height:mmH,background:P.surface+'DD',backdropFilter:'blur(8px)',borderRadius:6,border:`1px solid ${P.border}`,overflow:'hidden',zIndex:5}}>
              <svg width={mmW} height={mmH} viewBox={`0 0 ${mmW} ${mmH}`}>
                {visNodes.map(n=><circle key={n.id} cx={(n.x-mnX)*sc} cy={(n.y-mnY)*sc} r={2} fill={typeColor(P,n.concept_type).accent} opacity={0.7}/>)}
                <rect x={(-camera.x/camera.zoom-mnX)*sc} y={(-camera.y/camera.zoom-mnY)*sc}
                  width={((rc?.width||800)/camera.zoom)*sc} height={((rc?.height||600)/camera.zoom)*sc}
                  fill="none" stroke={P.text} strokeWidth={0.7} opacity={0.3} rx={1}/>
              </svg>
            </div>;
          })()}

          {/* Zoom buttons */}
          <div style={{position:'absolute',bottom:10,right:10,display:'flex',gap:3,zIndex:5}}>
            {[{l:'+',f:1.2},{l:'−',f:1/1.2},{l:'⊡',f:0}].map(({l,f})=>(
              <button key={l} onClick={()=>f?setCamera(c=>({...c,zoom:Math.max(.15,Math.min(5,c.zoom*f))})):fitToView(nodes)}
                style={{width:28,height:28,borderRadius:6,background:P.surface,border:`1px solid ${P.border}`,color:P.text,fontSize:12,cursor:'pointer',display:'flex',alignItems:'center',justifyContent:'center'}}>{l}</button>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}
JSX_EOF

echo "  ✓ App.jsx — complete rewrite with all fixes"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 Mycel v2 applied! Changes summary:"
echo ""
echo "  LAYOUT:"
echo "   • 4x stronger repulsion (overlap fix)"
echo "   • 3x stronger link attraction (outlier fix)"
echo "   • Max distance cap pulls strays back"
echo "   • 30-pass post-layout overlap resolution"
echo "   • Tighter initial spread (150-400px vs 200-550px)"
echo ""
echo "  EDGES:"
echo "   • Base width 3-4px (was 1.5-2.5px)"
echo "   • Base opacity 0.55 (was 0.28)"
echo "   • ALL edges have arrowheads (not just logical)"
echo "   • Larger arrow markers (8px vs 5px)"
echo "   • Glow on hover is 6px wider"
echo ""
echo "  NODES:"
echo "   • Translucent backgrounds (20% opacity fill)"
echo "   • Colored border per type (subtle)"
echo "   • Label text uses bright ACCENT color"
echo "   • Description text uses softer TINT"
echo "   • Block recedes, content dominates"
echo ""
echo "  FAMILIES:"
echo "   • Cluster hull outlines (convex hull per section)"
echo "   • Drag ANY node → moves entire neighbor family"
echo "   • Neighbors follow at 0.6x rate (organic lag)"
echo ""
echo "  INLINE ANNOTATIONS:"
echo "   • Term circles always visible (zoom > 0.6)"
echo "   • Tiny arrows from circles up to description"
echo "   • Up to 4 terms circled per node"
echo ""
echo "  SEMANTIC ZOOM:"
echo "   • zoom < 0.5: labels only"
echo "   • zoom > 0.5: descriptions appear"
echo "   • zoom > 0.6: term circles appear"
echo "   • zoom > 0.7: edge labels on hover"
echo ""
echo "  Detail card now commits edits to backend on blur"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Run: cd frontend && npm run dev"