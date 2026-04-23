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
