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
