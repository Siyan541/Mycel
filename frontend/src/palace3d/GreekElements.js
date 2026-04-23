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
