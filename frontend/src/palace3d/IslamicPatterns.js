// Procedural Islamic geometric pattern generators for Three.js
// All patterns are generated as geometry — no texture files needed.
// Designed for modular re-use across different room types.

import * as THREE from 'three';

// Color palette — warm sandstone with turquoise/gold accents
var COLORS = {
  sandstone: 0xD4A574,
  sandLight: 0xF0DCBF,
  sandDark:  0x8B6340,
  turquoise: 0x0D8B7D,
  gold:      0xD4A840,
  ivory:     0xFFF8E7,
  deepBlue:  0x1A3A5C,
  terracotta:0xBE5A30,
  marble:    0xF5F0E8,
  lapis:     0x26619C,
  emerald:   0x1A7A4C,
  copper:    0xB87333,
  cream:     0xFFF5DC,
  midnight:  0x191970,
  rose:      0xC06070,
  sage:      0x7A9A6A,
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
