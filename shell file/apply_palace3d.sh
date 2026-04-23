#!/bin/bash
# ============================================================================
# Mycel Memory Palace 3D — Complete implementation
#
# Creates: frontend/src/palace3d/
#   PalaceGenerator.js  — graph → modular room layout (maze topology)
#   RoomMeshes.js       — Islamic/Greek procedural room geometry
#   IslamicPatterns.js  — muqarnas vaults, rosettes, arabesque walls
#   GreekElements.js    — Doric/Ionic columns, theater steps
#   Navigation.js       — First-person WASD + mouse look
#   Palace3DView.jsx    — React component, full Mycel integration
#
# Usage: bash apply_palace3d.sh (from project root)
# Then in App.jsx, add a "Palace" view toggle.
# ============================================================================
set -e
echo "🏛️ Mycel Memory Palace 3D — Building..."

mkdir -p frontend/src/palace3d

# ═══════════════════════════════════════════════════════════════════════════
# FILE 1: PalaceGenerator.js
# Converts a knowledge graph into a modular room layout.
# KEY DESIGN: Maze topology, not linear sequence.
# Each room is a self-contained module with 4 potential exits (N/S/E/W).
# Rooms connect based on graph edges, creating organic maze-like paths.
# ═══════════════════════════════════════════════════════════════════════════
cat > frontend/src/palace3d/PalaceGenerator.js << 'GENEOF'
// PalaceGenerator — converts knowledge graph to 3D room layout
// Produces a maze-like modular structure where each concept is a room
// and each relationship is a corridor/doorway between rooms.
//
// MODULAR DESIGN:
//   - Each room occupies a cell in a grid
//   - Grid cells are 20×20 world units
//   - Rooms connect to neighbors via corridors on N/S/E/W faces
//   - The graph topology determines which cells are occupied
//   - Unconnected cells are walls → creates maze-like navigation

var CELL = 24; // world units per grid cell
var WALL_H = 6; // wall height
var CORRIDOR_W = 3; // corridor width

// Concept type → room style mapping
var ROOM_STYLES = {
  theory:     { shape: 'dome',      radius: 9,  height: 8, style: 'islamic' },
  principle:  { shape: 'colonnade', radius: 8,  height: 7, style: 'greek' },
  definition: { shape: 'muqarnas',  radius: 7,  height: 6, style: 'islamic' },
  method:     { shape: 'corridor',  radius: 6,  height: 5, style: 'mixed' },
  example:    { shape: 'garden',    radius: 8,  height: 4, style: 'islamic' },
  evidence:   { shape: 'alcove',    radius: 5,  height: 5, style: 'greek' },
  argument:   { shape: 'theater',   radius: 9,  height: 5, style: 'greek' },
  term:       { shape: 'archway',   radius: 4,  height: 5, style: 'mixed' },
  framework:  { shape: 'octagonal', radius: 10, height: 7, style: 'islamic' },
  phenomenon: { shape: 'garden',    radius: 7,  height: 4, style: 'mixed' },
};

// Relationship → connection style
var CONN_STYLES = {
  IMPLIES:         { type: 'open_door', width: 3 },
  REQUIRES:        { type: 'locked_door', width: 2.5 },
  CONTAINS:        { type: 'archway', width: 4 },
  PART_OF:         { type: 'archway', width: 3.5 },
  DEFINED_BY:      { type: 'inscription_door', width: 3 },
  GENERALIZES:     { type: 'wide_corridor', width: 5 },
  SPECIALIZES:     { type: 'narrow_passage', width: 2 },
  CAUSES:          { type: 'water_channel', width: 2 },
  ENABLES:         { type: 'bridge', width: 3 },
  ILLUSTRATES:     { type: 'window', width: 3 },
  CONTRADICTS:     { type: 'mirror_wall', width: 3 },
  PREREQUISITE_FOR:{ type: 'staircase', width: 3 },
  EXTENDS:         { type: 'open_door', width: 3 },
  CONTRASTS_WITH:  { type: 'mirror_wall', width: 2.5 },
  INSTANCE_OF:     { type: 'archway', width: 3 },
  EQUIVALENT:      { type: 'twin_doors', width: 4 },
  ANALOGOUS_TO:    { type: 'window', width: 3 },
  CONSTRAINS:      { type: 'narrow_passage', width: 2 },
};

function generatePalace(nodes, edges) {
  if (!nodes || !nodes.length) return { rooms: [], corridors: [], grid: {} };

  // 1. Build adjacency
  var adj = {};
  nodes.forEach(function(n) { adj[n.id] = []; });
  edges.forEach(function(e) {
    var src = e.source_id || e.source;
    var tgt = e.target_id || e.target;
    if (adj[src]) adj[src].push({ target: tgt, edge: e });
    if (adj[tgt]) adj[tgt].push({ target: src, edge: e });
  });

  // 2. Find center node (highest degree + abstraction)
  var centerNode = nodes[0];
  var maxScore = -1;
  nodes.forEach(function(n) {
    var deg = (adj[n.id] || []).length;
    var absScore = (3 - (n.abstraction_level || 0)) * 3;
    var confScore = (n.confidence || 0.5) * 5;
    var score = deg * 2 + absScore + confScore;
    if (score > maxScore) { maxScore = score; centerNode = n; }
  });

  // 3. BFS to assign grid positions (maze-like layout)
  var grid = {}; // "x,y" → nodeId
  var nodePos = {}; // nodeId → {gx, gy}
  var visited = {};
  var queue = [{ id: centerNode.id, gx: 0, gy: 0 }];
  visited[centerNode.id] = true;
  nodePos[centerNode.id] = { gx: 0, gy: 0 };
  grid['0,0'] = centerNode.id;

  // Direction priorities for maze-like branching
  var dirs = [
    { dx: 1, dy: 0 },  // East
    { dx: 0, dy: 1 },  // South
    { dx: -1, dy: 0 }, // West
    { dx: 0, dy: -1 }, // North
  ];

  while (queue.length > 0) {
    var current = queue.shift();
    var neighbors = adj[current.id] || [];
    var dirIdx = 0;

    neighbors.forEach(function(nb) {
      if (visited[nb.target]) return;

      // Find empty cell near current
      var placed = false;
      for (var attempt = 0; attempt < 16 && !placed; attempt++) {
        var d = dirs[(dirIdx + attempt) % 4];
        // Try direct neighbor
        var nx = current.gx + d.dx;
        var ny = current.gy + d.dy;
        var key = nx + ',' + ny;
        if (!grid[key]) {
          grid[key] = nb.target;
          nodePos[nb.target] = { gx: nx, gy: ny };
          visited[nb.target] = true;
          queue.push({ id: nb.target, gx: nx, gy: ny });
          placed = true;
        }
        // Try 2 cells away (creates longer corridors)
        if (!placed) {
          nx = current.gx + d.dx * 2;
          ny = current.gy + d.dy * 2;
          key = nx + ',' + ny;
          if (!grid[key]) {
            grid[key] = nb.target;
            nodePos[nb.target] = { gx: nx, gy: ny };
            visited[nb.target] = true;
            queue.push({ id: nb.target, gx: nx, gy: ny });
            placed = true;
          }
        }
      }
      dirIdx++;
    });
  }

  // 4. Handle unplaced nodes (disconnected components)
  nodes.forEach(function(n) {
    if (nodePos[n.id]) return;
    // Place in spiral outward from center
    var r = 1;
    while (true) {
      for (var x = -r; x <= r; x++) {
        for (var y = -r; y <= r; y++) {
          if (Math.abs(x) !== r && Math.abs(y) !== r) continue;
          var key = x + ',' + y;
          if (!grid[key]) {
            grid[key] = n.id;
            nodePos[n.id] = { gx: x, gy: y };
            return;
          }
        }
      }
      r++;
      if (r > 20) return; // safety
    }
  });

  // 5. Generate rooms
  var nodeMap = {};
  nodes.forEach(function(n) { nodeMap[n.id] = n; });

  var rooms = nodes.map(function(n) {
    var pos = nodePos[n.id];
    if (!pos) return null;
    var type = n.concept_type || 'term';
    var style = ROOM_STYLES[type] || ROOM_STYLES.term;
    var deg = (adj[n.id] || []).length;
    var importance = Math.min(1, (deg / 6) * 0.6 + (n.confidence || 0.5) * 0.4);
    var scaledRadius = style.radius * (0.7 + importance * 0.5);

    return {
      id: n.id,
      label: n.label,
      description: n.description || '',
      conceptType: type,
      gx: pos.gx,
      gy: pos.gy,
      worldX: pos.gx * CELL,
      worldZ: pos.gy * CELL,
      worldY: (n.abstraction_level || 0) * 0.5, // slight Y offset by level
      radius: scaledRadius,
      height: style.height * (0.8 + importance * 0.3),
      shape: style.shape,
      style: style.style,
      importance: importance,
      degree: deg,
      confidence: n.confidence || 0.5,
      abstractionLevel: n.abstraction_level || 0,
    };
  }).filter(Boolean);

  // 6. Generate corridors from edges
  var corridors = [];
  edges.forEach(function(e) {
    var srcId = e.source_id || e.source;
    var tgtId = e.target_id || e.target;
    var srcPos = nodePos[srcId];
    var tgtPos = nodePos[tgtId];
    if (!srcPos || !tgtPos) return;

    var relType = e.relation_type || 'REQUIRES';
    var connStyle = CONN_STYLES[relType] || CONN_STYLES.REQUIRES;

    corridors.push({
      id: 'cor_' + srcId + '_' + tgtId,
      sourceId: srcId,
      targetId: tgtId,
      relationType: relType,
      justification: e.justification || '',
      confidence: e.confidence || 0.5,
      connectionType: connStyle.type,
      width: connStyle.width,
      // World positions
      startX: srcPos.gx * CELL,
      startZ: srcPos.gy * CELL,
      endX: tgtPos.gx * CELL,
      endZ: tgtPos.gy * CELL,
    });
  });

  // 7. Compute bounds
  var minGx = 0, maxGx = 0, minGy = 0, maxGy = 0;
  rooms.forEach(function(r) {
    minGx = Math.min(minGx, r.gx);
    maxGx = Math.max(maxGx, r.gx);
    minGy = Math.min(minGy, r.gy);
    maxGy = Math.max(maxGy, r.gy);
  });

  return {
    rooms: rooms,
    corridors: corridors,
    grid: grid,
    bounds: { minGx: minGx, maxGx: maxGx, minGy: minGy, maxGy: maxGy },
    center: nodePos[centerNode.id] || { gx: 0, gy: 0 },
    cellSize: CELL,
    wallHeight: WALL_H,
  };
}

export { generatePalace, CELL, WALL_H, ROOM_STYLES, CONN_STYLES };
GENEOF
echo "  ✓ PalaceGenerator.js"

# ═══════════════════════════════════════════════════════════════════════════
# FILE 2: IslamicPatterns.js
# Procedural Islamic geometric patterns for walls, ceilings, floors
# ═══════════════════════════════════════════════════════════════════════════
cat > frontend/src/palace3d/IslamicPatterns.js << 'ISLEOF'
// Procedural Islamic geometric pattern generators for Three.js
// All patterns are generated as geometry — no texture files needed.
// Designed for modular re-use across different room types.

import * as THREE from 'three';

// Color palette — warm sandstone with turquoise/gold accents
var COLORS = {
  sandstone: 0xD4A574,
  sandLight: 0xE8C9A0,
  sandDark:  0xA67C52,
  turquoise: 0x1B998B,
  gold:      0xC8A951,
  ivory:     0xFFF8E7,
  deepBlue:  0x1A3A5C,
  terracotta:0xC2734C,
  marble:    0xF0EDE5,
};

// Generate an 8-fold rosette as a flat mesh (for floor/ceiling decoration)
function createRosette(radius, folds, color1, color2) {
  folds = folds || 8;
  color1 = color1 || COLORS.turquoise;
  color2 = color2 || COLORS.gold;

  var group = new THREE.Group();
  var angleStep = (Math.PI * 2) / folds;

  // Outer petals
  for (var i = 0; i < folds; i++) {
    var a = angleStep * i;
    var shape = new THREE.Shape();
    shape.moveTo(0, 0);
    shape.lineTo(
      Math.cos(a - angleStep * 0.3) * radius * 0.8,
      Math.sin(a - angleStep * 0.3) * radius * 0.8
    );
    shape.quadraticCurveTo(
      Math.cos(a) * radius * 1.1,
      Math.sin(a) * radius * 1.1,
      Math.cos(a + angleStep * 0.3) * radius * 0.8,
      Math.sin(a + angleStep * 0.3) * radius * 0.8
    );
    shape.lineTo(0, 0);

    var geo = new THREE.ShapeGeometry(shape);
    var mat = new THREE.MeshStandardMaterial({
      color: i % 2 === 0 ? color1 : color2,
      side: THREE.DoubleSide,
    });
    var mesh = new THREE.Mesh(geo, mat);
    group.add(mesh);
  }

  // Center star
  var starGeo = new THREE.CircleGeometry(radius * 0.25, folds);
  var starMat = new THREE.MeshStandardMaterial({ color: COLORS.gold });
  var star = new THREE.Mesh(starGeo, starMat);
  group.add(star);

  return group;
}

// Generate muqarnas (honeycomb) vault tier
function createMuqarnasTier(radius, segments, height, tierIndex) {
  var group = new THREE.Group();
  var angleStep = (Math.PI * 2) / segments;
  var cellH = height / 3;
  var tierRadius = radius * (1 - tierIndex * 0.25);

  for (var i = 0; i < segments; i++) {
    var a = angleStep * i;
    var nextA = angleStep * (i + 1);

    // Each muqarnas cell is a small concave niche
    var points = [];
    points.push(new THREE.Vector3(
      Math.cos(a) * tierRadius, tierIndex * cellH, Math.sin(a) * tierRadius
    ));
    points.push(new THREE.Vector3(
      Math.cos((a + nextA) / 2) * tierRadius * 0.85,
      tierIndex * cellH + cellH * 0.7,
      Math.sin((a + nextA) / 2) * tierRadius * 0.85
    ));
    points.push(new THREE.Vector3(
      Math.cos(nextA) * tierRadius, tierIndex * cellH, Math.sin(nextA) * tierRadius
    ));

    var geo = new THREE.BufferGeometry().setFromPoints(points);
    geo.setIndex([0, 1, 2]);
    geo.computeVertexNormals();
    var mat = new THREE.MeshStandardMaterial({
      color: tierIndex % 2 === 0 ? COLORS.sandstone : COLORS.sandLight,
      side: THREE.DoubleSide,
    });
    group.add(new THREE.Mesh(geo, mat));
  }
  return group;
}

// Full muqarnas vault (stacked tiers)
function createMuqarnasVault(radius, height, tiers) {
  tiers = tiers || 4;
  var group = new THREE.Group();
  for (var t = 0; t < tiers; t++) {
    var segs = 8 + t * 4; // more segments in outer tiers
    var tier = createMuqarnasTier(radius, segs, height, t);
    group.add(tier);
  }
  return group;
}

// Arabesque wall panel (geometric line pattern on a plane)
function createArabesquePanel(width, height, color) {
  color = color || COLORS.turquoise;
  var group = new THREE.Group();

  // Background panel
  var bgGeo = new THREE.PlaneGeometry(width, height);
  var bgMat = new THREE.MeshStandardMaterial({
    color: COLORS.sandstone, side: THREE.DoubleSide
  });
  group.add(new THREE.Mesh(bgGeo, bgMat));

  // Geometric line pattern — interlocking hexagons
  var lineMat = new THREE.LineBasicMaterial({ color: color, linewidth: 1 });
  var cellSize = Math.min(width, height) / 4;

  for (var ix = -2; ix <= 2; ix++) {
    for (var iy = -2; iy <= 2; iy++) {
      var cx = ix * cellSize * 0.87;
      var cy = iy * cellSize + (ix % 2 ? cellSize * 0.5 : 0);
      if (Math.abs(cx) > width / 2 || Math.abs(cy) > height / 2) continue;

      // Hexagon
      var pts = [];
      for (var h = 0; h <= 6; h++) {
        var ang = (Math.PI / 3) * h + Math.PI / 6;
        pts.push(new THREE.Vector3(
          cx + Math.cos(ang) * cellSize * 0.4,
          cy + Math.sin(ang) * cellSize * 0.4,
          0.01
        ));
      }
      var lineGeo = new THREE.BufferGeometry().setFromPoints(pts);
      group.add(new THREE.Line(lineGeo, lineMat));

      // Inner star
      var starPts = [];
      for (var s = 0; s <= 6; s++) {
        var ang2 = (Math.PI / 3) * s;
        var r2 = s % 2 === 0 ? cellSize * 0.2 : cellSize * 0.35;
        starPts.push(new THREE.Vector3(cx + Math.cos(ang2) * r2, cy + Math.sin(ang2) * r2, 0.01));
      }
      starPts.push(starPts[0].clone());
      var starLineGeo = new THREE.BufferGeometry().setFromPoints(starPts);
      group.add(new THREE.Line(starLineGeo, new THREE.LineBasicMaterial({ color: COLORS.gold })));
    }
  }

  return group;
}

// Pointed Islamic arch shape (for doorways)
function createPointedArch(width, height, depth) {
  var shape = new THREE.Shape();
  var hw = width / 2;
  var archStart = height * 0.55;

  shape.moveTo(-hw, 0);
  shape.lineTo(-hw, archStart);
  // Pointed arch curves
  shape.quadraticCurveTo(-hw * 0.3, height * 1.05, 0, height);
  shape.quadraticCurveTo(hw * 0.3, height * 1.05, hw, archStart);
  shape.lineTo(hw, 0);
  shape.lineTo(-hw, 0);

  var extrudeSettings = { depth: depth || 0.5, bevelEnabled: false };
  var geo = new THREE.ExtrudeGeometry(shape, extrudeSettings);
  var mat = new THREE.MeshStandardMaterial({ color: COLORS.sandDark });
  return new THREE.Mesh(geo, mat);
}

// Dome (for theory rooms)
function createDome(radius, color) {
  color = color || COLORS.sandLight;
  var geo = new THREE.SphereGeometry(radius, 24, 16, 0, Math.PI * 2, 0, Math.PI / 2);
  var mat = new THREE.MeshStandardMaterial({
    color: color, side: THREE.DoubleSide
  });
  return new THREE.Mesh(geo, mat);
}

// Octagonal floor plan (for framework rooms)
function createOctagonalFloor(radius, color) {
  color = color || COLORS.marble;
  var geo = new THREE.CircleGeometry(radius, 8);
  var mat = new THREE.MeshStandardMaterial({ color: color, side: THREE.DoubleSide });
  var mesh = new THREE.Mesh(geo, mat);
  mesh.rotation.x = -Math.PI / 2;
  return mesh;
}

export {
  COLORS, createRosette, createMuqarnasTier, createMuqarnasVault,
  createArabesquePanel, createPointedArch, createDome, createOctagonalFloor,
};
ISLEOF
echo "  ✓ IslamicPatterns.js"

# ═══════════════════════════════════════════════════════════════════════════
# FILE 3: GreekElements.js
# Procedural Greek architectural elements
# ═══════════════════════════════════════════════════════════════════════════
cat > frontend/src/palace3d/GreekElements.js << 'GRKEOF'
import * as THREE from 'three';
import { COLORS } from './IslamicPatterns.js';

// Doric column (simple, no base)
function createDoricColumn(height, radius) {
  height = height || 5;
  radius = radius || 0.3;
  var group = new THREE.Group();

  // Shaft with slight entasis (bulge)
  var pts = [];
  for (var i = 0; i <= 10; i++) {
    var t = i / 10;
    var r = radius * (1 + 0.08 * Math.sin(t * Math.PI)); // subtle bulge
    pts.push(new THREE.Vector2(r, t * height));
  }
  var shaftGeo = new THREE.LatheGeometry(pts, 16);
  var shaftMat = new THREE.MeshStandardMaterial({ color: COLORS.marble });
  group.add(new THREE.Mesh(shaftGeo, shaftMat));

  // Capital (simple square block)
  var capGeo = new THREE.BoxGeometry(radius * 3, height * 0.08, radius * 3);
  var capMat = new THREE.MeshStandardMaterial({ color: COLORS.sandLight });
  var cap = new THREE.Mesh(capGeo, capMat);
  cap.position.y = height;
  group.add(cap);

  // Fluting lines (vertical grooves)
  var fluteMat = new THREE.LineBasicMaterial({ color: 0xD8D0C0 });
  for (var f = 0; f < 12; f++) {
    var angle = (Math.PI * 2 * f) / 12;
    var flutePts = [
      new THREE.Vector3(Math.cos(angle) * radius * 1.01, 0, Math.sin(angle) * radius * 1.01),
      new THREE.Vector3(Math.cos(angle) * radius * 1.01, height, Math.sin(angle) * radius * 1.01),
    ];
    group.add(new THREE.Line(new THREE.BufferGeometry().setFromPoints(flutePts), fluteMat));
  }

  return group;
}

// Colonnade (row of columns with architrave)
function createColonnade(count, spacing, height, radius) {
  count = count || 4;
  spacing = spacing || 2.5;
  height = height || 5;
  radius = radius || 0.3;
  var group = new THREE.Group();
  var totalWidth = (count - 1) * spacing;

  for (var i = 0; i < count; i++) {
    var col = createDoricColumn(height, radius);
    col.position.x = i * spacing - totalWidth / 2;
    group.add(col);
  }

  // Architrave (beam across top)
  var archGeo = new THREE.BoxGeometry(totalWidth + spacing, height * 0.06, radius * 4);
  var archMat = new THREE.MeshStandardMaterial({ color: COLORS.sandLight });
  var arch = new THREE.Mesh(archGeo, archMat);
  arch.position.y = height + height * 0.04;
  group.add(arch);

  // Frieze (decorative band)
  var friezeGeo = new THREE.BoxGeometry(totalWidth + spacing, height * 0.1, radius * 3.5);
  var friezeMat = new THREE.MeshStandardMaterial({ color: COLORS.sandstone });
  var frieze = new THREE.Mesh(friezeGeo, friezeMat);
  frieze.position.y = height + height * 0.12;
  group.add(frieze);

  return group;
}

// Theater steps (semicircular seating)
function createTheater(radius, rows, height) {
  radius = radius || 8;
  rows = rows || 5;
  height = height || 4;
  var group = new THREE.Group();

  for (var r = 0; r < rows; r++) {
    var stepR = radius * 0.4 + (radius * 0.6 * r) / rows;
    var stepH = (height * r) / rows;
    var geo = new THREE.CylinderGeometry(stepR + 0.5, stepR, height / rows, 24, 1, false, 0, Math.PI);
    var mat = new THREE.MeshStandardMaterial({
      color: r % 2 === 0 ? COLORS.marble : COLORS.sandLight,
    });
    var step = new THREE.Mesh(geo, mat);
    step.position.y = stepH + (height / rows) / 2;
    group.add(step);
  }

  // Stage area (flat circle in front)
  var stageGeo = new THREE.CircleGeometry(radius * 0.35, 24);
  var stageMat = new THREE.MeshStandardMaterial({ color: COLORS.terracotta, side: THREE.DoubleSide });
  var stage = new THREE.Mesh(stageGeo, stageMat);
  stage.rotation.x = -Math.PI / 2;
  stage.position.y = 0.01;
  group.add(stage);

  return group;
}

// Pediment (triangular roof element)
function createPediment(width, height) {
  width = width || 8;
  height = height || 2;
  var shape = new THREE.Shape();
  shape.moveTo(-width / 2, 0);
  shape.lineTo(0, height);
  shape.lineTo(width / 2, 0);
  shape.lineTo(-width / 2, 0);

  var geo = new THREE.ExtrudeGeometry(shape, { depth: 0.3, bevelEnabled: false });
  var mat = new THREE.MeshStandardMaterial({ color: COLORS.sandLight });
  return new THREE.Mesh(geo, mat);
}

export { createDoricColumn, createColonnade, createTheater, createPediment };
GRKEOF
echo "  ✓ GreekElements.js"

# ═══════════════════════════════════════════════════════════════════════════
# FILE 4: RoomMeshes.js
# Assembles complete rooms from Islamic + Greek elements
# ═══════════════════════════════════════════════════════════════════════════
cat > frontend/src/palace3d/RoomMeshes.js << 'RMEOF'
import * as THREE from 'three';
import {
  COLORS, createRosette, createMuqarnasVault, createArabesquePanel,
  createPointedArch, createDome, createOctagonalFloor,
} from './IslamicPatterns.js';
import { createDoricColumn, createColonnade, createTheater, createPediment } from './GreekElements.js';

var textCanvas = document.createElement('canvas');
var textCtx = textCanvas.getContext('2d');

function createTextTexture(text, width, height, fontSize, color, bgColor) {
  width = width || 512; height = height || 128;
  fontSize = fontSize || 28; color = color || '#FFF8E7';
  bgColor = bgColor || 'transparent';
  textCanvas.width = width; textCanvas.height = height;
  if (bgColor !== 'transparent') {
    textCtx.fillStyle = bgColor;
    textCtx.fillRect(0, 0, width, height);
  } else {
    textCtx.clearRect(0, 0, width, height);
  }
  textCtx.fillStyle = color;
  textCtx.font = fontSize + 'px serif';
  textCtx.textAlign = 'center';
  textCtx.textBaseline = 'middle';
  // Word wrap
  var words = text.split(' ');
  var lines = []; var line = '';
  words.forEach(function(w) {
    var test = line ? line + ' ' + w : w;
    if (textCtx.measureText(test).width > width * 0.85) { lines.push(line); line = w; }
    else line = test;
  });
  if (line) lines.push(line);
  var lineH = fontSize * 1.3;
  var startY = height / 2 - (lines.length - 1) * lineH / 2;
  lines.forEach(function(l, i) { textCtx.fillText(l, width / 2, startY + i * lineH); });
  var tex = new THREE.CanvasTexture(textCanvas.cloneNode(true).getContext('2d').canvas);
  // Actually copy the pixel data
  var imgData = textCtx.getImageData(0, 0, width, height);
  var c2 = tex.image.getContext('2d');
  c2.canvas.width = width; c2.canvas.height = height;
  c2.putImageData(imgData, 0, 0);
  tex.needsUpdate = true;
  return tex;
}

// Build a complete room from a palace room descriptor
function buildRoom(room) {
  var group = new THREE.Group();
  group.position.set(room.worldX, room.worldY, room.worldZ);
  group.userData = { roomId: room.id, label: room.label, type: room.conceptType };

  var R = room.radius;
  var H = room.height;

  // Floor
  var floorGeo, floorMat;
  if (room.shape === 'octagonal') {
    group.add(createOctagonalFloor(R, COLORS.marble));
  } else {
    floorGeo = new THREE.CircleGeometry(R, room.shape === 'theater' ? 24 : 32);
    floorMat = new THREE.MeshStandardMaterial({
      color: room.style === 'islamic' ? COLORS.sandstone : COLORS.marble,
      side: THREE.DoubleSide,
    });
    var floor = new THREE.Mesh(floorGeo, floorMat);
    floor.rotation.x = -Math.PI / 2;
    floor.position.y = 0.01;
    group.add(floor);
  }

  // Floor rosette decoration
  if (room.style === 'islamic' || room.shape === 'octagonal') {
    var rosette = createRosette(R * 0.6, 8, COLORS.turquoise, COLORS.gold);
    rosette.rotation.x = -Math.PI / 2;
    rosette.position.y = 0.02;
    group.add(rosette);
  }

  // Walls (cylinder or segments)
  var wallSegments = room.shape === 'octagonal' ? 8 : 24;
  var wallGeo = new THREE.CylinderGeometry(R, R, H, wallSegments, 1, true);
  var wallMat = new THREE.MeshStandardMaterial({
    color: COLORS.sandstone, side: THREE.DoubleSide,
    transparent: true, opacity: 0.85,
  });
  var walls = new THREE.Mesh(wallGeo, wallMat);
  walls.position.y = H / 2;
  group.add(walls);

  // Arabesque panels on walls (islamic rooms)
  if (room.style === 'islamic' || room.style === 'mixed') {
    for (var i = 0; i < 4; i++) {
      var angle = (Math.PI / 2) * i;
      var panel = createArabesquePanel(R * 0.8, H * 0.6, COLORS.turquoise);
      panel.position.set(
        Math.cos(angle) * (R - 0.1),
        H * 0.45,
        Math.sin(angle) * (R - 0.1)
      );
      panel.rotation.y = -angle + Math.PI;
      group.add(panel);
    }
  }

  // Ceiling / dome
  if (room.shape === 'dome') {
    var dome = createDome(R, COLORS.sandLight);
    dome.position.y = H;
    group.add(dome);
    // Muqarnas inside dome
    var muq = createMuqarnasVault(R * 0.8, R * 0.5, 3);
    muq.position.y = H - R * 0.1;
    group.add(muq);
  } else if (room.shape === 'muqarnas') {
    var vault = createMuqarnasVault(R, H * 0.4, 4);
    vault.position.y = H;
    group.add(vault);
  } else {
    // Flat ceiling
    var ceilGeo = new THREE.CircleGeometry(R, wallSegments);
    var ceilMat = new THREE.MeshStandardMaterial({ color: COLORS.sandLight, side: THREE.DoubleSide });
    var ceil = new THREE.Mesh(ceilGeo, ceilMat);
    ceil.rotation.x = Math.PI / 2;
    ceil.position.y = H;
    group.add(ceil);
  }

  // Greek elements
  if (room.shape === 'colonnade' || room.style === 'greek') {
    var cols = Math.max(4, Math.round(room.degree * 1.5));
    for (var ci = 0; ci < cols; ci++) {
      var cAngle = (Math.PI * 2 * ci) / cols;
      var col = createDoricColumn(H * 0.9, 0.25);
      col.position.set(Math.cos(cAngle) * (R - 0.5), 0, Math.sin(cAngle) * (R - 0.5));
      group.add(col);
    }
  }

  if (room.shape === 'theater') {
    var theater = createTheater(R, 4, H * 0.6);
    group.add(theater);
  }

  // Label inscription (floating text above floor)
  var labelTex = createTextTexture(room.label, 512, 128, 36, '#FFF8E7');
  var labelGeo = new THREE.PlaneGeometry(R * 1.2, R * 0.3);
  var labelMat = new THREE.MeshBasicMaterial({ map: labelTex, transparent: true, side: THREE.DoubleSide });
  var labelMesh = new THREE.Mesh(labelGeo, labelMat);
  labelMesh.position.y = H * 0.35;
  labelMesh.rotation.y = Math.PI; // face the entrance
  group.add(labelMesh);

  // Description inscription (on wall)
  if (room.description) {
    var descTex = createTextTexture(room.description, 512, 256, 20, '#D4A574');
    var descGeo = new THREE.PlaneGeometry(R * 1.4, R * 0.7);
    var descMat = new THREE.MeshBasicMaterial({ map: descTex, transparent: true, side: THREE.DoubleSide });
    var descMesh = new THREE.Mesh(descGeo, descMat);
    descMesh.position.set(0, H * 0.65, -R + 0.2);
    group.add(descMesh);
  }

  // Point light inside room
  var light = new THREE.PointLight(0xFFE8C0, 0.6, R * 3);
  light.position.y = H * 0.8;
  group.add(light);

  return group;
}

// Build corridor mesh between two rooms
function buildCorridor(corridor) {
  var group = new THREE.Group();
  var dx = corridor.endX - corridor.startX;
  var dz = corridor.endZ - corridor.startZ;
  var len = Math.sqrt(dx * dx + dz * dz);
  if (len < 0.1) return group;

  var angle = Math.atan2(dz, dx);
  var midX = (corridor.startX + corridor.endX) / 2;
  var midZ = (corridor.startZ + corridor.endZ) / 2;
  var w = corridor.width || 3;
  var h = 4;

  // Floor
  var floorGeo = new THREE.PlaneGeometry(len, w);
  var floorMat = new THREE.MeshStandardMaterial({ color: COLORS.sandstone, side: THREE.DoubleSide });
  var floor = new THREE.Mesh(floorGeo, floorMat);
  floor.rotation.x = -Math.PI / 2;
  floor.rotation.z = -angle;
  floor.position.set(midX, 0.01, midZ);
  group.add(floor);

  // Walls (two sides)
  for (var side = -1; side <= 1; side += 2) {
    var wallGeo = new THREE.PlaneGeometry(len, h);
    var wallMat = new THREE.MeshStandardMaterial({
      color: COLORS.sandstone, side: THREE.DoubleSide,
      transparent: true, opacity: 0.7,
    });
    var wall = new THREE.Mesh(wallGeo, wallMat);
    wall.position.set(
      midX + Math.cos(angle + Math.PI / 2) * w / 2 * side,
      h / 2,
      midZ + Math.sin(angle + Math.PI / 2) * w / 2 * side
    );
    wall.rotation.y = -angle;
    group.add(wall);
  }

  // Ceiling
  var ceilGeo = new THREE.PlaneGeometry(len, w);
  var ceilMat = new THREE.MeshStandardMaterial({ color: COLORS.sandLight, side: THREE.DoubleSide });
  var ceil = new THREE.Mesh(ceilGeo, ceilMat);
  ceil.rotation.x = Math.PI / 2;
  ceil.rotation.z = -angle;
  ceil.position.set(midX, h, midZ);
  group.add(ceil);

  // Archway at each end
  if (corridor.connectionType === 'archway' || corridor.connectionType === 'open_door') {
    var arch = createPointedArch(w, h * 0.9, 0.3);
    arch.position.set(corridor.startX, 0, corridor.startZ);
    arch.rotation.y = -angle;
    group.add(arch);
  }

  // Relation label
  var relLabel = (corridor.relationType || '').replace(/_/g, ' ');
  if (relLabel) {
    var relTex = createTextTexture(relLabel, 256, 64, 16, '#C8A951');
    var relGeo = new THREE.PlaneGeometry(len * 0.3, 0.4);
    var relMat = new THREE.MeshBasicMaterial({ map: relTex, transparent: true, side: THREE.DoubleSide });
    var relMesh = new THREE.Mesh(relGeo, relMat);
    relMesh.position.set(midX, h - 0.3, midZ);
    relMesh.rotation.y = -angle;
    group.add(relMesh);
  }

  return group;
}

// Ground plane with subtle grid pattern
function buildGround(bounds, cellSize) {
  var w = (bounds.maxGx - bounds.minGx + 4) * cellSize;
  var h = (bounds.maxGy - bounds.minGy + 4) * cellSize;
  var geo = new THREE.PlaneGeometry(w, h);
  var mat = new THREE.MeshStandardMaterial({ color: 0x8B7355, side: THREE.DoubleSide });
  var ground = new THREE.Mesh(geo, mat);
  ground.rotation.x = -Math.PI / 2;
  ground.position.set(
    ((bounds.minGx + bounds.maxGx) / 2) * cellSize,
    -0.01,
    ((bounds.minGy + bounds.maxGy) / 2) * cellSize
  );
  return ground;
}

// Sky dome
function buildSky() {
  var geo = new THREE.SphereGeometry(200, 32, 16);
  var mat = new THREE.MeshBasicMaterial({
    color: 0x1A2744, side: THREE.BackSide,
  });
  return new THREE.Mesh(geo, mat);
}

export { buildRoom, buildCorridor, buildGround, buildSky, createTextTexture };
RMEOF
echo "  ✓ RoomMeshes.js"

# ═══════════════════════════════════════════════════════════════════════════
# FILE 5: Navigation.js
# First-person WASD + mouse look controls
# ═══════════════════════════════════════════════════════════════════════════
cat > frontend/src/palace3d/Navigation.js << 'NAVEOF'
// First-person navigation for the memory palace
// WASD movement, mouse look (on pointer lock), collision detection

function createNavigation(camera, domElement) {
  var speed = 8;
  var lookSpeed = 0.002;
  var keys = {};
  var yaw = 0;
  var pitch = 0;
  var locked = false;

  // Set initial camera position
  camera.position.set(0, 2.5, 0);

  function onKeyDown(e) { keys[e.code] = true; }
  function onKeyUp(e) { keys[e.code] = false; }

  function onMouseMove(e) {
    if (!locked) return;
    yaw -= e.movementX * lookSpeed;
    pitch -= e.movementY * lookSpeed;
    pitch = Math.max(-Math.PI / 2.2, Math.min(Math.PI / 2.2, pitch));
  }

  function onClick() {
    if (!locked) {
      domElement.requestPointerLock();
    }
  }

  function onLockChange() {
    locked = document.pointerLockElement === domElement;
  }

  domElement.addEventListener('click', onClick);
  document.addEventListener('keydown', onKeyDown);
  document.addEventListener('keyup', onKeyUp);
  document.addEventListener('mousemove', onMouseMove);
  document.addEventListener('pointerlockchange', onLockChange);

  function update(dt) {
    dt = dt || 0.016;
    var moveSpeed = speed * dt;

    // Direction from yaw
    var forward = { x: Math.sin(yaw), z: Math.cos(yaw) };
    var right = { x: Math.cos(yaw), z: -Math.sin(yaw) };

    if (keys['KeyW'] || keys['ArrowUp']) {
      camera.position.x += forward.x * moveSpeed;
      camera.position.z += forward.z * moveSpeed;
    }
    if (keys['KeyS'] || keys['ArrowDown']) {
      camera.position.x -= forward.x * moveSpeed;
      camera.position.z -= forward.z * moveSpeed;
    }
    if (keys['KeyA'] || keys['ArrowLeft']) {
      camera.position.x -= right.x * moveSpeed;
      camera.position.z -= right.z * moveSpeed;
    }
    if (keys['KeyD'] || keys['ArrowRight']) {
      camera.position.x += right.x * moveSpeed;
      camera.position.z += right.z * moveSpeed;
    }

    // Apply rotation
    camera.rotation.order = 'YXZ';
    camera.rotation.y = yaw;
    camera.rotation.x = pitch;
  }

  function teleportTo(x, z) {
    camera.position.set(x, 2.5, z);
  }

  function dispose() {
    domElement.removeEventListener('click', onClick);
    document.removeEventListener('keydown', onKeyDown);
    document.removeEventListener('keyup', onKeyUp);
    document.removeEventListener('mousemove', onMouseMove);
    document.removeEventListener('pointerlockchange', onLockChange);
  }

  return { update: update, teleportTo: teleportTo, dispose: dispose, camera: camera };
}

export { createNavigation };
NAVEOF
echo "  ✓ Navigation.js"

# ═══════════════════════════════════════════════════════════════════════════
# FILE 6: Palace3DView.jsx
# React component that integrates the 3D palace into Mycel
# ═══════════════════════════════════════════════════════════════════════════
cat > frontend/src/palace3d/Palace3DView.jsx << 'P3DEOF'
import React, { useRef, useEffect, useState, useCallback } from 'react';
import * as THREE from 'three';
import { generatePalace } from './PalaceGenerator.js';
import { buildRoom, buildCorridor, buildGround, buildSky } from './RoomMeshes.js';
import { createNavigation } from './Navigation.js';

export default function Palace3DView(props) {
  var nodes = props.nodes || [];
  var edges = props.edges || [];
  var onBack = props.onBack;
  var palette = props.palette;

  var mountRef = useRef(null);
  var sceneRef = useRef(null);
  var navRef = useRef(null);
  var rendererRef = useRef(null);
  var frameRef = useRef(null);
  var [currentRoom, setCurrentRoom] = useState(null);
  var [minimap, setMinimap] = useState(null);
  var [showHelp, setShowHelp] = useState(true);
  var palaceRef = useRef(null);

  useEffect(function() {
    if (!mountRef.current || !nodes.length) return;

    var el = mountRef.current;
    var W = el.clientWidth;
    var H = el.clientHeight;

    // Scene
    var scene = new THREE.Scene();
    scene.fog = new THREE.Fog(0x1A2744, 30, 120);
    sceneRef.current = scene;

    // Camera
    var camera = new THREE.PerspectiveCamera(70, W / H, 0.1, 300);

    // Renderer
    var renderer = new THREE.WebGLRenderer({ antialias: true });
    renderer.setSize(W, H);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.shadowMap.enabled = true;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 0.8;
    el.appendChild(renderer.domElement);
    rendererRef.current = renderer;

    // Lighting
    var ambient = new THREE.AmbientLight(0x404060, 0.4);
    scene.add(ambient);

    var sun = new THREE.DirectionalLight(0xFFE8C0, 0.6);
    sun.position.set(30, 50, 20);
    sun.castShadow = true;
    scene.add(sun);

    // Hemisphere light (sky/ground)
    var hemi = new THREE.HemisphereLight(0x6688CC, 0x886644, 0.3);
    scene.add(hemi);

    // Generate palace
    var palace = generatePalace(nodes, edges);
    palaceRef.current = palace;

    // Build rooms
    palace.rooms.forEach(function(room) {
      var roomMesh = buildRoom(room);
      scene.add(roomMesh);
    });

    // Build corridors
    palace.corridors.forEach(function(cor) {
      var corMesh = buildCorridor(cor);
      scene.add(corMesh);
    });

    // Ground + sky
    scene.add(buildGround(palace.bounds, palace.cellSize));
    scene.add(buildSky());

    // Navigation
    var nav = createNavigation(camera, renderer.domElement);
    navRef.current = nav;

    // Start at center room
    var centerRoom = palace.rooms.find(function(r) {
      return r.gx === palace.center.gx && r.gy === palace.center.gy;
    });
    if (centerRoom) {
      nav.teleportTo(centerRoom.worldX, centerRoom.worldZ + centerRoom.radius + 2);
      setCurrentRoom(centerRoom);
    }

    // Build minimap data
    setMinimap({
      rooms: palace.rooms.map(function(r) {
        return { gx: r.gx, gy: r.gy, label: r.label, id: r.id, type: r.conceptType };
      }),
      corridors: palace.corridors.map(function(c) {
        return { sx: c.startX, sz: c.startZ, ex: c.endX, ez: c.endZ };
      }),
      bounds: palace.bounds,
      cellSize: palace.cellSize,
    });

    // Animation loop
    var clock = new THREE.Clock();
    function animate() {
      frameRef.current = requestAnimationFrame(animate);
      var dt = clock.getDelta();
      nav.update(dt);

      // Detect current room
      var cx = camera.position.x;
      var cz = camera.position.z;
      var closest = null;
      var closestDist = Infinity;
      palace.rooms.forEach(function(r) {
        var dx = cx - r.worldX;
        var dz = cz - r.worldZ;
        var dist = Math.sqrt(dx * dx + dz * dz);
        if (dist < r.radius && dist < closestDist) {
          closestDist = dist;
          closest = r;
        }
      });
      if (closest && (!currentRoom || closest.id !== currentRoom.id)) {
        setCurrentRoom(closest);
      }

      renderer.render(scene, camera);
    }
    animate();

    // Resize handler
    function onResize() {
      var w = el.clientWidth;
      var h = el.clientHeight;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
    }
    window.addEventListener('resize', onResize);

    // Cleanup
    return function() {
      window.removeEventListener('resize', onResize);
      if (frameRef.current) cancelAnimationFrame(frameRef.current);
      if (navRef.current) navRef.current.dispose();
      if (rendererRef.current) {
        rendererRef.current.dispose();
        if (el.contains(rendererRef.current.domElement)) {
          el.removeChild(rendererRef.current.domElement);
        }
      }
    };
  }, [nodes, edges]);

  var teleport = useCallback(function(roomId) {
    if (!palaceRef.current || !navRef.current) return;
    var room = palaceRef.current.rooms.find(function(r) { return r.id === roomId; });
    if (room) {
      navRef.current.teleportTo(room.worldX, room.worldZ + room.radius + 2);
      setCurrentRoom(room);
    }
  }, []);

  var bg = palette ? palette.bg : '#0B1120';
  var surface = palette ? palette.surface : '#131B2E';
  var border = palette ? palette.border : '#1E2A45';
  var text = palette ? palette.text : '#E8ECF4';
  var dim = palette ? palette.dim : '#5A6478';

  return React.createElement('div', {
    style: { position: 'relative', width: '100%', height: '100%', background: bg }
  },
    // Three.js mount point
    React.createElement('div', {
      ref: mountRef,
      style: { width: '100%', height: '100%' }
    }),

    // Back button
    React.createElement('button', {
      onClick: onBack,
      style: {
        position: 'absolute', top: 10, left: 10, padding: '6px 14px',
        background: surface, border: '1px solid ' + border, borderRadius: 8,
        color: text, fontSize: 12, cursor: 'pointer', zIndex: 10,
      }
    }, '← Back to 2D'),

    // Current room info
    currentRoom && React.createElement('div', {
      style: {
        position: 'absolute', bottom: 16, left: '50%', transform: 'translateX(-50%)',
        background: surface + 'EE', border: '1px solid ' + border, borderRadius: 12,
        padding: '10px 20px', zIndex: 10, textAlign: 'center', maxWidth: 400,
        backdropFilter: 'blur(8px)',
      }
    },
      React.createElement('div', {
        style: { fontSize: 15, fontWeight: 600, color: text, marginBottom: 4 }
      }, currentRoom.label),
      React.createElement('div', {
        style: { fontSize: 11, color: dim, lineHeight: 1.4 }
      }, currentRoom.description),
      React.createElement('div', {
        style: { fontSize: 9, color: dim, marginTop: 4, textTransform: 'uppercase', letterSpacing: 0.5 }
      }, currentRoom.conceptType + ' · ' + Math.round(currentRoom.confidence * 100) + '% confidence')
    ),

    // Help overlay
    showHelp && React.createElement('div', {
      onClick: function() { setShowHelp(false); },
      style: {
        position: 'absolute', top: '50%', left: '50%', transform: 'translate(-50%, -50%)',
        background: surface + 'F0', border: '1px solid ' + border, borderRadius: 16,
        padding: '24px 32px', zIndex: 20, textAlign: 'center', cursor: 'pointer',
        backdropFilter: 'blur(12px)', maxWidth: 360,
      }
    },
      React.createElement('div', { style: { fontSize: 18, fontWeight: 700, marginBottom: 12, color: text } }, '🏛️ Memory Palace'),
      React.createElement('div', { style: { fontSize: 12, color: dim, lineHeight: 1.6 } },
        'Click to enter first-person mode',
        React.createElement('br'), 'WASD — move',
        React.createElement('br'), 'Mouse — look around',
        React.createElement('br'), 'ESC — release mouse',
        React.createElement('br'), React.createElement('br'),
        'Each room is a concept. Corridors are relationships.',
        React.createElement('br'), 'Explore the maze to learn.',
      ),
      React.createElement('div', { style: { fontSize: 10, color: dim, marginTop: 12 } }, 'Click anywhere to dismiss')
    ),

    // Minimap
    minimap && React.createElement('div', {
      style: {
        position: 'absolute', top: 10, right: 10, width: 160, height: 160,
        background: surface + 'DD', border: '1px solid ' + border, borderRadius: 8,
        overflow: 'hidden', zIndex: 10,
      }
    },
      React.createElement('svg', {
        width: 160, height: 160,
        viewBox: [
          (minimap.bounds.minGx - 1) + ' ' + (minimap.bounds.minGy - 1) + ' ' +
          (minimap.bounds.maxGx - minimap.bounds.minGx + 3) + ' ' +
          (minimap.bounds.maxGy - minimap.bounds.minGy + 3)
        ].join('')
      },
        // Corridors
        minimap.corridors.map(function(c, i) {
          return React.createElement('line', {
            key: 'mc' + i,
            x1: c.sx / minimap.cellSize, y1: c.sz / minimap.cellSize,
            x2: c.ex / minimap.cellSize, y2: c.ez / minimap.cellSize,
            stroke: '#ffffff30', strokeWidth: 0.15,
          });
        }),
        // Rooms
        minimap.rooms.map(function(r) {
          var isCurrent = currentRoom && currentRoom.id === r.id;
          return React.createElement('g', { key: 'mr' + r.id, onClick: function() { teleport(r.id); }, style: { cursor: 'pointer' } },
            React.createElement('circle', {
              cx: r.gx, cy: r.gy, r: 0.35,
              fill: isCurrent ? '#FDCB6E' : '#A29BFE',
              opacity: isCurrent ? 1 : 0.6,
            }),
            React.createElement('title', null, r.label)
          );
        })
      ),
      // Room list (scrollable)
      React.createElement('div', {
        style: { maxHeight: 80, overflowY: 'auto', padding: '4px 6px', borderTop: '1px solid ' + border }
      },
        minimap.rooms.map(function(r) {
          var isCurrent = currentRoom && currentRoom.id === r.id;
          return React.createElement('div', {
            key: 'rl' + r.id,
            onClick: function() { teleport(r.id); },
            style: {
              fontSize: 8, padding: '2px 4px', cursor: 'pointer', borderRadius: 3,
              color: isCurrent ? '#FDCB6E' : dim,
              background: isCurrent ? bg : 'transparent',
            }
          }, r.label);
        })
      )
    )
  );
}
P3DEOF
echo "  ✓ Palace3DView.jsx"

# ═══════════════════════════════════════════════════════════════════════════
# Install Three.js if not present
# ═══════════════════════════════════════════════════════════════════════════
cd frontend
if ! grep -q '"three"' package.json 2>/dev/null; then
  echo "  Installing three.js..."
  npm install --save three 2>/dev/null || echo "  ⚠ Run: cd frontend && npm install three"
fi
cd ..

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🏛️ Memory Palace 3D installed!"
echo ""
echo "FILES CREATED:"
echo "  palace3d/PalaceGenerator.js  — graph → maze room layout"
echo "  palace3d/IslamicPatterns.js  — muqarnas, rosettes, arabesque"
echo "  palace3d/GreekElements.js    — columns, theaters, pediments"
echo "  palace3d/RoomMeshes.js       — complete room assembly"
echo "  palace3d/Navigation.js       — WASD first-person controls"
echo "  palace3d/Palace3DView.jsx    — React integration component"
echo ""
echo "INTEGRATION:"
echo "  In your App.jsx, add a 'Palace' view option:"
echo ""
echo "    import Palace3DView from './palace3d/Palace3DView.jsx';"
echo ""
echo "    // In header, add a Palace button"
echo "    // In render, add:"
echo "    view === 'palace' && React.createElement(Palace3DView, {"
echo "      nodes: vn, edges: ve, palette: P,"
echo "      onBack: function() { setView('graph'); }"
echo "    })"
echo ""
echo "ARCHITECTURE:"
echo "  • Modular grid layout — each room is a cell"
echo "  • BFS placement creates natural maze topology"
echo "  • Islamic: domes, muqarnas, arabesque, pointed arches"
echo "  • Greek: Doric columns, colonnades, theaters, pediments"
echo "  • Rooms connect via corridors (relationship = corridor type)"
echo "  • WASD + mouse first-person navigation"
echo "  • Minimap with click-to-teleport"
echo "  • Room detection shows current concept info"
echo ""
echo "INSTALL: cd frontend && npm install three"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"