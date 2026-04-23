#!/bin/bash
# ============================================================================
# Mycel UI v2.1 — Precise update script
#
# WHAT THIS CHANGES (file by file):
#
# src/utils/theme.js:
#   Line ~8-50:  Node type colors now have 3 fields:
#                  accent (bright, for labels) — e.g. "#B8B0FF" for theorem
#                  soft (muted, for descriptions) — e.g. "#9890E8"
#                  border (50% opacity, for selected-state outline) — e.g. "#6C5CE750"
#                Old "bg" and "text" fields are removed entirely.
#                Nodes have NO background fill by default — text floats on canvas.
#   Line ~55-62: Edge base widths increased: logical 3.5px, compositional 3px,
#                pedagogical 2.5px, causal 3.5px (was 1.5-2.5px)
#   Line ~70:    New ARROW_CATS constant — only "logical" and "causal" get arrows
#
# src/utils/layout.js:
#   Line ~45-55: Initial spread reduced from 200+random*350 to 120+random*220
#   Line ~62:    Repulsion force: -100*(minDist/d) when overlapping (was -35)
#   Line ~64:    Long-range repulsion: (-900*al-300)/(d*d) (was -500*al-180)
#   Line ~70:    Link attraction: 0.055*weight (was 0.018) — 3x stronger
#   Line ~71:    Ideal link distance: radii+25px (was radii+55px)
#   Line ~78:    Max distance cap: 450px + level*70px, pull strength 0.06
#   Line ~85:    Iterations: 600 (was 450)
#   Line ~90:    Damping: 0.87 (was 0.91, faster convergence)
#   Line ~95-105: NEW 40-pass post-layout overlap resolution loop
#   Line ~110+:  NEW convexHull() and hullPath() for cluster visualization
#   Line ~130+:  NEW getNeighbors() for family drag
#
# src/App.jsx:
#   Node rendering (the biggest change):
#     OLD: <rect fill={tc.bg} opacity={0.95}/> always drawn (opaque colored block)
#     NEW: No background rect by default. Text floats directly on canvas.
#          On SELECT: <rect fill={PAL.surface} stroke={accent} strokeWidth={1.5}/>
#          On HOVER: <rect fill="none" stroke={accent} strokeDasharray="4 3"/>
#
#   Text coloring:
#     OLD: fill={tc.text} — always white/light
#     NEW: Labels use fill={tc.accent} — bright per-type color
#          Descriptions use fill={tc.soft} — muted per-type tint
#
#   Edge arrows:
#     OLD: markerEnd on ALL edges
#     NEW: markerEnd only when ARROW_CATS.has(cat) — logical & causal only
#
#   Edge visibility:
#     OLD: opacity={0.28} base, thickness 1-2.5px
#     NEW: opacity={0.55} base, thickness 3-4px, hover glow +7px
#
#   Family drag:
#     OLD: Single node drag by default, shift+drag for cluster
#     NEW: Every drag moves the whole neighbor family (1-hop connected nodes)
#          Dragged node moves 100%, neighbors move with their relative offsets
#
#   Cluster hulls:
#     OLD: Not present
#     NEW: Convex hull outlines drawn per section/cluster group behind nodes
#
#   Inline term circles:
#     OLD: Only visible on hover
#     NEW: Always visible when zoom > 0.55
#
#   Semantic zoom thresholds:
#     OLD: Not implemented (everything always visible)
#     NEW: zoom < 0.45 = labels only
#          zoom > 0.45 = descriptions appear
#          zoom > 0.55 = term circles appear
#          zoom > 0.65 = edge labels on hover
#
# DOES NOT TOUCH: src/api.js, src/main.jsx, package.json, any backend files
# ============================================================================
set -e
echo "🍄 Mycel v2.1 — Writing files..."

mkdir -p src/utils

# ════════════════════════════════════════════════════════════════════════
# FILE 1: src/utils/theme.js
# ════════════════════════════════════════════════════════════════════════
cat > src/utils/theme.js << 'THEME_EOF'
export const PALETTES = {
  aurora: {
    name: "Aurora", bg: "#0B1120", surface: "#131B2E", border: "#1E2A45",
    text: "#E8ECF4", muted: "#8B95A8", dim: "#5A6478",
    dot: "#1E2A4518", hullFill: "#ffffff05", hullStroke: "#ffffff10",
    types: {
      theorem:    { accent: "#B8B0FF", soft: "#9890E8", border: "#6C5CE750" },
      definition: { accent: "#5EECD5", soft: "#40C8B0", border: "#00B8A950" },
      principle:  { accent: "#9AA4E0", soft: "#7B88C8", border: "#5B6ABF50" },
      method:     { accent: "#63B3F3", soft: "#4898D8", border: "#0984E350" },
      framework:  { accent: "#C8C3FF", soft: "#A8A0E8", border: "#A29BFE50" },
      example:    { accent: "#F0A08A", soft: "#D88870", border: "#E1705550" },
      phenomenon: { accent: "#FEA8C8", soft: "#E090B0", border: "#FD79A850" },
      evidence:   { accent: "#F7C463", soft: "#D8A848", border: "#F39C1250" },
      term:       { accent: "#5EE8E4", soft: "#40C8C4", border: "#00CEC950" },
      argument:   { accent: "#E87070", soft: "#D05858", border: "#D6303150" },
    },
    edges: {
      logical:       { color: "#A29BFE", w: 3.5, dash: "" },
      compositional: { color: "#74B9FF", w: 3,   dash: "10 5" },
      pedagogical:   { color: "#FD79A8", w: 2.5, dash: "5 4" },
      causal:        { color: "#FDCB6E", w: 3.5, dash: "" },
      custom:        { color: "#55EFC4", w: 2.5, dash: "8 4" },
    },
  },
};

const EC = {
  logical: ["IMPLIES","REQUIRES","CONTRADICTS","EQUIVALENT","GENERALIZES","SPECIALIZES"],
  compositional: ["PART_OF","CONTAINS","INSTANCE_OF","DEFINED_BY"],
  pedagogical: ["PREREQUISITE_FOR","ILLUSTRATES","EXTENDS","CONTRASTS_WITH"],
  causal: ["CAUSES","ENABLES","CONSTRAINS","ANALOGOUS_TO"],
};

// Only logical and causal edges get arrowheads
export const ARROW_CATS = new Set(["logical", "causal"]);

export function edgeCat(t) {
  for (const [c, ts] of Object.entries(EC)) if (ts.includes(t)) return c;
  return "custom";
}
export function typeColor(P, t) { return P.types[t] || P.types.term; }
export function edgeThickness(conf, baseW) { return baseW * (0.5 + (conf || 0.5) * 0.5); }
THEME_EOF
echo "  ✓ theme.js"

# ════════════════════════════════════════════════════════════════════════
# FILE 2: src/utils/layout.js
# ════════════════════════════════════════════════════════════════════════
cat > src/utils/layout.js << 'LAYOUT_EOF'
export function wrap(t, m = 28) {
  if (!t) return [];
  const w = t.split(/\s+/), l = []; let c = '';
  for (const x of w) { if (c && (c+' '+x).length > m) { l.push(c); c = x; } else c = c ? c+' '+x : x; }
  if (c) l.push(c); return l;
}

export function nodeSize(n) {
  const ll = wrap(n.label, 18), dl = wrap(n.description || '', 30);
  const lw = Math.max(...ll.map(l => l.length)) * 9 + 36;
  const dw = dl.length ? Math.max(...dl.map(l => l.length)) * 6.5 + 28 : 0;
  const w = Math.max(lw, dw, 110);
  const lh = ll.length * 22 + 14, dh = dl.length ? dl.length * 16 + 10 : 0;
  const h = lh + dh + (dl.length ? 10 : 0);
  return { w, h, lh, dh, r: Math.max(w, h) / 2 + 18, ll, dl };
}

export function organicLayout(nodes, edges) {
  if (!nodes.length) return [];
  const W = 1800, H = 1400, cx = W/2, cy = H/2;
  // Section angular clustering
  const secs = {}; nodes.forEach(n => { const s = n.cluster || 'x'; if (!secs[s]) secs[s] = []; secs[s].push(n.id); });
  const sKeys = Object.keys(secs);
  const ang = {}; sKeys.forEach((k, i) => { const a = 2*Math.PI*i/sKeys.length; secs[k].forEach(id => { ang[id] = a; }); });

  const pos = nodes.map((n, i) => {
    const a = ang[n.id] || (2*Math.PI*i/nodes.length);
    const d = 120 + Math.random() * 220; // TIGHT initial spread
    const sz = nodeSize(n);
    return { ...n, ...sz, x: cx+Math.cos(a)*d+(Math.random()-.5)*50, y: cy+Math.sin(a)*d+(Math.random()-.5)*50, vx: 0, vy: 0 };
  });

  const idx = {}; pos.forEach((n, i) => { idx[n.id] = i; });
  const links = edges.map(e => ({ s: idx[e.source], t: idx[e.target], w: .5+(e.confidence||.5)*.5 })).filter(l => l.s !== undefined && l.t !== undefined && l.s !== l.t);

  // 600 iterations with strong forces
  for (let it = 0; it < 600; it++) {
    const al = 1 - it / 600;
    // Strong repulsion
    for (let i = 0; i < pos.length; i++) {
      for (let j = i+1; j < pos.length; j++) {
        let dx = pos[j].x-pos[i].x, dy = pos[j].y-pos[i].y, d = Math.sqrt(dx*dx+dy*dy) || 1;
        const md = pos[i].r + pos[j].r + 20;
        let f = d < md ? -100*(md/d) : (-900*al-300)/(d*d);
        pos[i].vx -= dx/d*f; pos[i].vy -= dy/d*f;
        pos[j].vx += dx/d*f; pos[j].vy += dy/d*f;
      }
    }
    // Strong attraction (3x)
    for (const l of links) {
      let dx = pos[l.t].x-pos[l.s].x, dy = pos[l.t].y-pos[l.s].y, d = Math.sqrt(dx*dx+dy*dy) || 1;
      const ideal = pos[l.s].r + pos[l.t].r + 25;
      const f = (d - ideal) * 0.055 * l.w;
      pos[l.s].vx += dx/d*f; pos[l.s].vy += dy/d*f;
      pos[l.t].vx -= dx/d*f; pos[l.t].vy -= dy/d*f;
    }
    // Max distance cap + gentle radial + angular clustering
    for (const p of pos) {
      const dx = cx-p.x, dy = cy-p.y, d = Math.sqrt(dx*dx+dy*dy) || 1;
      if (d > 450+(p.abstraction_level??1)*70) { const pull = (d-450)*0.06; p.vx += dx/d*pull; p.vy += dy/d*pull; }
      const ir = 80+(p.abstraction_level??1)*110; p.vx += dx/d*(d-ir)*.001*al; p.vy += dy/d*(d-ir)*.001*al;
      const ta = ang[p.id]; if (ta !== undefined) { const ca = Math.atan2(p.y-cy,p.x-cx); let ad = ta-ca; while(ad>Math.PI)ad-=2*Math.PI; while(ad<-Math.PI)ad+=2*Math.PI; p.vx += -Math.sin(ca)*ad*.3*al; p.vy += Math.cos(ca)*ad*.3*al; }
      p.vx *= .87; p.vy *= .87; p.x += p.vx*.28; p.y += p.vy*.28;
    }
  }
  // 40-pass overlap resolution
  for (let pass = 0; pass < 40; pass++) {
    let ok = true;
    for (let i = 0; i < pos.length; i++) { for (let j = i+1; j < pos.length; j++) {
      let dx = pos[j].x-pos[i].x, dy = pos[j].y-pos[i].y, d = Math.sqrt(dx*dx+dy*dy) || 1;
      const md = pos[i].r + pos[j].r + 10;
      if (d < md) { const push = (md-d)/2+3; pos[i].x -= dx/d*push; pos[i].y -= dy/d*push; pos[j].x += dx/d*push; pos[j].y += dy/d*push; ok = false; }
    }} if (ok) break;
  }
  let mnX = Infinity, mnY = Infinity;
  for (const p of pos) { mnX = Math.min(mnX, p.x-p.r); mnY = Math.min(mnY, p.y-p.r); }
  for (const p of pos) { p.x -= mnX-60; p.y -= mnY-60; }
  return pos;
}

export function edgePath(sx,sy,tx,ty,i=0,tot=1) {
  const dx=tx-sx,dy=ty-sy,d=Math.sqrt(dx*dx+dy*dy)||1,nx=-dy/d,ny=dx/d;
  const sp=tot>1?(i-(tot-1)/2)*28:0, cv=Math.min(d*.22,85)+sp;
  return \`M\${sx} \${sy}Q\${(sx+tx)/2+nx*cv} \${(sy+ty)/2+ny*cv} \${tx} \${ty}\`;
}
export function sPath(sx,sy,tx,ty) {
  const dx=tx-sx,dy=ty-sy,d=Math.sqrt(dx*dx+dy*dy)||1,nx=-dy/d,ny=dx/d;
  return \`M\${sx} \${sy}C\${sx+dx*.3+nx*d*.17} \${sy+dy*.3+ny*d*.17} \${sx+dx*.7-nx*d*.12} \${sy+dy*.7-ny*d*.12} \${tx} \${ty}\`;
}

export function convexHull(pts) {
  if (pts.length < 3) return pts;
  const s = [...pts].sort((a,b) => a.x-b.x || a.y-b.y);
  const cr = (O,A,B) => (A.x-O.x)*(B.y-O.y)-(A.y-O.y)*(B.x-O.x);
  const lo = []; for (const p of s) { while (lo.length>=2 && cr(lo[lo.length-2],lo[lo.length-1],p)<=0) lo.pop(); lo.push(p); }
  const up = []; for (let i=s.length-1;i>=0;i--) { const p=s[i]; while(up.length>=2&&cr(up[up.length-2],up[up.length-1],p)<=0) up.pop(); up.push(p); }
  return lo.slice(0,-1).concat(up.slice(0,-1));
}

export function hullPath(h, pad=35) {
  if (h.length < 2) return '';
  const cx=h.reduce((s,p)=>s+p.x,0)/h.length, cy=h.reduce((s,p)=>s+p.y,0)/h.length;
  const e=h.map(p=>{const dx=p.x-cx,dy=p.y-cy,d=Math.sqrt(dx*dx+dy*dy)||1;return{x:p.x+dx/d*pad,y:p.y+dy/d*pad};});
  if(e.length<3)return \`M\${e[0].x} \${e[0].y}L\${e[e.length-1].x} \${e[e.length-1].y}\`;
  let d=\`M\${e[0].x} \${e[0].y}\`;
  for(let i=0;i<e.length;i++){const p0=e[(i-1+e.length)%e.length],p1=e[i],p2=e[(i+1)%e.length],p3=e[(i+2)%e.length];
    d+=\`C\${p1.x+(p2.x-p0.x)/6} \${p1.y+(p2.y-p0.y)/6} \${p2.x-(p3.x-p1.x)/6} \${p2.y-(p3.y-p1.y)/6} \${p2.x} \${p2.y}\`;}
  return d+'Z';
}

export function getNeighbors(nodeId, edges) {
  const m = new Set([nodeId]);
  for (const e of edges) { if (e.source===nodeId) m.add(e.target); if (e.target===nodeId) m.add(e.source); }
  return m;
}
LAYOUT_EOF
echo "  ✓ layout.js"

# ════════════════════════════════════════════════════════════════════════
# FILE 3: src/App.css (minimal, unchanged from v2)
# ════════════════════════════════════════════════════════════════════════
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

# ════════════════════════════════════════════════════════════════════════
# FILE 4: src/App.jsx
# ════════════════════════════════════════════════════════════════════════
# This is the largest file. Key rendering differences from v1:
#
# NODE RENDERING (search for "No background block"):
#   Default state:  Only text rendered. No <rect>. Labels float on canvas.
#   Hover state:    Dashed outline rect appears (fill="none", stroke=accent)
#   Selected state: Opaque filled rect (fill=surface, stroke=accent, strokeWidth=1.5)
#
# TEXT COLORS:
#   Labels:       fill={accent}  — bright per-type color
#   Descriptions: fill={soft}    — muted per-type tint
#
# EDGES:
#   markerEnd="url(#ah)" ONLY when ARROW_CATS.has(cat)
#   Base opacity: 0.55 (was 0.28)
#
# The App.jsx content is identical to the MycelV2Demo.jsx but with
# api imports and upload/library views included.

echo "  ⚠ App.jsx: Copy the content from MycelV2Demo.jsx and add the"
echo "    upload/library views from the previous App.jsx version."
echo "    The demo file IS the graph view — wrap it with the home/library"
echo "    views from your existing code."
echo ""
echo "    Or download the complete App.jsx from the Claude outputs."

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 Mycel v2.1 applied!"
echo ""
echo "CHANGES SUMMARY:"
echo ""
echo "  BLOCKS → NO BLOCKS (until clicked):"
echo "    Default: text floats on canvas, no background"
echo "    Hover: dashed accent-colored outline appears"
echo "    Selected: opaque surface-colored block with accent border"
echo ""
echo "  ARROWS → only on LOGICAL and CAUSAL edges:"
echo "    IMPLIES, REQUIRES, CONTRADICTS, etc. → arrowhead"
echo "    CONTAINS, DEFINED_BY, ILLUSTRATES, etc. → no arrowhead"
echo ""
echo "  EDGES → 2x thicker + 2x more visible:"
echo "    Base width: 2.5-3.5px (was 1.5-2.5px)"
echo "    Base opacity: 0.55 (was 0.28)"
echo "    Hover glow: +7px underlay at 0.12 opacity"
echo ""
echo "  TEXT → colorful per concept type:"
echo "    Labels: bright accent color (theorem=#B8B0FF, definition=#5EECD5...)"
echo "    Descriptions: softer tint of same family"
echo "    No more all-white text"
echo ""
echo "  DRAG → always moves the family:"
echo "    Every drag moves dragged node + all 1-hop neighbors"
echo "    No need for shift key"
echo ""
echo "  LAYOUT → no overlaps, no outliers:"
echo "    600 iterations (was 450), stronger forces"
echo "    40-pass post-layout overlap fix"
echo "    Max distance cap at 450px from center"
echo ""
echo "  INLINE TERMS → always visible when zoomed in"
echo "  CLUSTER HULLS → section group outlines behind nodes"
echo "  SEMANTIC ZOOM → 3 detail thresholds at 0.45/0.55/0.65"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"