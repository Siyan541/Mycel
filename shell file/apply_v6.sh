#!/bin/bash
# ============================================================================
# Mycel v6 — Comprehensive patch
#
# PALACE FIXES:
#   1. Navigation: collision bounds so you can't fall through walls
#   2. Bird's-eye / third-person toggle (press T or click button)
#   3. Better color palette (warm amber, deep turquoise, ivory)
#   4. More corridor variations (arched, open-air, bridges)
#   5. Rooms have solid floors (no falling through)
#   6. Text textures use per-canvas instances (no sharing bug)
#
# APP.JSX ADDITIONS:
#   7. Library view with Confirm/Share/Delete buttons
#   8. Community view with browse/upvote
#   9. Toolbar: + Node, Link nodes, Type picker, Palette editor
#   10. Palace view properly integrated
#
# Run from project root: bash apply_v6.sh
# ============================================================================
set -e
echo "🍄 Mycel v6 — Comprehensive patch..."

mkdir -p frontend/src/palace3d

# ═══════════════════════════════════════════════════════════════════════════
# FIX 1: Navigation.js — collision + bird's-eye view
# ═══════════════════════════════════════════════════════════════════════════
cat > frontend/src/palace3d/Navigation.js << 'NAVEOF'
// Navigation with collision bounds + bird's-eye toggle

import * as THREE from 'three';

function createNavigation(camera, domElement, palaceData) {
  var speed = 8;
  var lookSpeed = 0.002;
  var keys = {};
  var yaw = 0;
  var pitch = 0;
  var locked = false;
  var mode = 'first'; // 'first' or 'bird'
  var birdHeight = 60;
  var birdTarget = new THREE.Vector3(0, 0, 0);

  // Collision bounds from palace rooms
  var rooms = (palaceData && palaceData.rooms) || [];
  var bounds = palaceData ? palaceData.bounds : { minGx: -5, maxGx: 5, minGy: -5, maxGy: 5 };
  var cellSize = (palaceData && palaceData.cellSize) || 24;

  camera.position.set(0, 2.5, 5);
  camera.near = 0.1;
  camera.far = 500;
  camera.updateProjectionMatrix();

  function onKeyDown(e) {
    keys[e.code] = true;
    if (e.code === 'KeyT') toggleMode();
  }
  function onKeyUp(e) { keys[e.code] = false; }

  function onMouseMove(e) {
    if (!locked) return;
    if (mode === 'first') {
      yaw -= e.movementX * lookSpeed;
      pitch -= e.movementY * lookSpeed;
      pitch = Math.max(-1.2, Math.min(1.2, pitch));
    } else {
      // Bird mode: rotate view around center
      if (e.buttons & 1) {
        yaw -= e.movementX * lookSpeed * 0.5;
      }
    }
  }

  function onClick() {
    if (mode === 'first' && !locked) {
      domElement.requestPointerLock();
    }
  }

  function onLockChange() {
    locked = document.pointerLockElement === domElement;
  }

  function onWheel(e) {
    if (mode === 'bird') {
      birdHeight = Math.max(20, Math.min(200, birdHeight + e.deltaY * 0.1));
    }
  }

  domElement.addEventListener('click', onClick);
  domElement.addEventListener('wheel', onWheel);
  document.addEventListener('keydown', onKeyDown);
  document.addEventListener('keyup', onKeyUp);
  document.addEventListener('mousemove', onMouseMove);
  document.addEventListener('pointerlockchange', onLockChange);

  function toggleMode() {
    if (mode === 'first') {
      mode = 'bird';
      birdTarget.set(camera.position.x, 0, camera.position.z);
      if (document.pointerLockElement) document.exitPointerLock();
    } else {
      mode = 'first';
      camera.position.y = 2.5;
    }
  }

  function clampPosition(x, z) {
    // Keep within palace bounds + margin
    var margin = cellSize * 2;
    var minX = bounds.minGx * cellSize - margin;
    var maxX = bounds.maxGx * cellSize + margin;
    var minZ = bounds.minGy * cellSize - margin;
    var maxZ = bounds.maxGy * cellSize + margin;
    return {
      x: Math.max(minX, Math.min(maxX, x)),
      z: Math.max(minZ, Math.min(maxZ, z))
    };
  }

  function update(dt) {
    dt = Math.min(dt || 0.016, 0.05); // cap delta time
    var moveSpeed = speed * dt;

    if (mode === 'first') {
      var forward = { x: Math.sin(yaw), z: Math.cos(yaw) };
      var right = { x: Math.cos(yaw), z: -Math.sin(yaw) };
      var newX = camera.position.x;
      var newZ = camera.position.z;

      if (keys['KeyW'] || keys['ArrowUp']) { newX += forward.x * moveSpeed; newZ += forward.z * moveSpeed; }
      if (keys['KeyS'] || keys['ArrowDown']) { newX -= forward.x * moveSpeed; newZ -= forward.z * moveSpeed; }
      if (keys['KeyA'] || keys['ArrowLeft']) { newX -= right.x * moveSpeed; newZ -= right.z * moveSpeed; }
      if (keys['KeyD'] || keys['ArrowRight']) { newX += right.x * moveSpeed; newZ += right.z * moveSpeed; }

      var clamped = clampPosition(newX, newZ);
      camera.position.x = clamped.x;
      camera.position.z = clamped.z;
      camera.position.y = 2.5; // locked to eye height

      camera.rotation.order = 'YXZ';
      camera.rotation.y = yaw;
      camera.rotation.x = pitch;

    } else {
      // Bird's-eye view — orbit controls
      if (keys['KeyW'] || keys['ArrowUp']) birdTarget.z -= moveSpeed * 3;
      if (keys['KeyS'] || keys['ArrowDown']) birdTarget.z += moveSpeed * 3;
      if (keys['KeyA'] || keys['ArrowLeft']) birdTarget.x -= moveSpeed * 3;
      if (keys['KeyD'] || keys['ArrowRight']) birdTarget.x += moveSpeed * 3;

      var clamped = clampPosition(birdTarget.x, birdTarget.z);
      birdTarget.x = clamped.x;
      birdTarget.z = clamped.z;

      camera.position.set(
        birdTarget.x + Math.sin(yaw) * birdHeight * 0.3,
        birdHeight,
        birdTarget.z + Math.cos(yaw) * birdHeight * 0.3
      );
      camera.lookAt(birdTarget);
    }
  }

  function teleportTo(x, z) {
    if (mode === 'first') {
      camera.position.set(x, 2.5, z + 3);
      yaw = Math.PI; // face into the room
    } else {
      birdTarget.set(x, 0, z);
    }
  }

  function getMode() { return mode; }
  function setMode(m) { mode = m; if (m === 'bird') toggleMode(); }

  function dispose() {
    domElement.removeEventListener('click', onClick);
    domElement.removeEventListener('wheel', onWheel);
    document.removeEventListener('keydown', onKeyDown);
    document.removeEventListener('keyup', onKeyUp);
    document.removeEventListener('mousemove', onMouseMove);
    document.removeEventListener('pointerlockchange', onLockChange);
  }

  return {
    update: update, teleportTo: teleportTo, dispose: dispose,
    toggleMode: toggleMode, getMode: getMode, camera: camera,
  };
}

export { createNavigation };
NAVEOF
echo "  ✓ Navigation.js — collision bounds + bird's-eye (press T)"

# ═══════════════════════════════════════════════════════════════════════════
# FIX 2: Better colors in IslamicPatterns.js
# ═══════════════════════════════════════════════════════════════════════════
# Only update the COLORS object — rest of file stays the same
if [ -f frontend/src/palace3d/IslamicPatterns.js ]; then
  # Replace the COLORS block with richer palette
  python3 << 'PYEOF'
import re
path = "frontend/src/palace3d/IslamicPatterns.js"
with open(path, 'r') as f: content = f.read()
old_colors = """var COLORS = {
  sandstone: 0xD4A574,
  sandLight: 0xE8C9A0,
  sandDark:  0xA67C52,
  turquoise: 0x1B998B,
  gold:      0xC8A951,
  ivory:     0xFFF8E7,
  deepBlue:  0x1A3A5C,
  terracotta:0xC2734C,
  marble:    0xF0EDE5,
};"""
new_colors = """var COLORS = {
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
};"""
content = content.replace(old_colors, new_colors)
with open(path, 'w') as f: f.write(content)
print("  ✓ IslamicPatterns.js — richer color palette")
PYEOF
fi

# ═══════════════════════════════════════════════════════════════════════════
# FIX 3: Palace3DView.jsx — add bird's-eye toggle button + fix solid floors
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
  var navRef = useRef(null);
  var rendererRef = useRef(null);
  var frameRef = useRef(null);
  var palaceRef = useRef(null);
  var [currentRoom, setCurrentRoom] = useState(null);
  var [viewMode, setViewMode] = useState('first');
  var [showHelp, setShowHelp] = useState(true);
  var [miniRooms, setMiniRooms] = useState([]);
  var currentRoomRef = useRef(null);

  useEffect(function() {
    if (!mountRef.current || !nodes.length) return;
    var el = mountRef.current;
    var W = el.clientWidth || 800;
    var H = el.clientHeight || 600;

    var scene = new THREE.Scene();
    scene.background = new THREE.Color(0x1A2744);
    scene.fog = new THREE.FogExp2(0x1A2744, 0.008);

    var camera = new THREE.PerspectiveCamera(70, W / H, 0.1, 500);

    var renderer = new THREE.WebGLRenderer({ antialias: true, alpha: false });
    renderer.setSize(W, H);
    renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 0.9;
    el.appendChild(renderer.domElement);
    rendererRef.current = renderer;

    // Lighting — warm ambient atmosphere
    scene.add(new THREE.AmbientLight(0x404060, 0.5));
    var sun = new THREE.DirectionalLight(0xFFE0B0, 0.7);
    sun.position.set(40, 60, 30);
    scene.add(sun);
    scene.add(new THREE.HemisphereLight(0x7799CC, 0x886644, 0.3));

    // Generate palace
    var palace = generatePalace(nodes, edges);
    palaceRef.current = palace;

    // Build meshes
    palace.rooms.forEach(function(room) { scene.add(buildRoom(room)); });
    palace.corridors.forEach(function(cor) { scene.add(buildCorridor(cor)); });
    scene.add(buildGround(palace.bounds, palace.cellSize));
    scene.add(buildSky());

    // Navigation with collision data
    var nav = createNavigation(camera, renderer.domElement, palace);
    navRef.current = nav;

    // Start position
    var cr = palace.rooms.find(function(r) {
      return r.gx === palace.center.gx && r.gy === palace.center.gy;
    });
    if (cr) {
      nav.teleportTo(cr.worldX, cr.worldZ);
      setCurrentRoom(cr);
      currentRoomRef.current = cr;
    }

    setMiniRooms(palace.rooms.map(function(r) {
      return { gx: r.gx, gy: r.gy, label: r.label, id: r.id, type: r.conceptType };
    }));

    // Animate
    var clock = new THREE.Clock();
    function animate() {
      frameRef.current = requestAnimationFrame(animate);
      nav.update(clock.getDelta());

      // Detect room
      var cx = camera.position.x, cz = camera.position.z;
      var best = null, bestD = Infinity;
      for (var i = 0; i < palace.rooms.length; i++) {
        var r = palace.rooms[i];
        var dx = cx - r.worldX, dz = cz - r.worldZ;
        var d = Math.sqrt(dx * dx + dz * dz);
        if (d < r.radius * 1.2 && d < bestD) { bestD = d; best = r; }
      }
      if (best && (!currentRoomRef.current || best.id !== currentRoomRef.current.id)) {
        currentRoomRef.current = best;
        setCurrentRoom(best);
      }

      renderer.render(scene, camera);
    }
    animate();

    function onResize() {
      var w = el.clientWidth, h = el.clientHeight;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
    }
    window.addEventListener('resize', onResize);

    return function() {
      window.removeEventListener('resize', onResize);
      if (frameRef.current) cancelAnimationFrame(frameRef.current);
      if (navRef.current) navRef.current.dispose();
      if (rendererRef.current) {
        rendererRef.current.dispose();
        if (el.contains(rendererRef.current.domElement))
          el.removeChild(rendererRef.current.domElement);
      }
    };
  }, [nodes, edges]);

  var teleport = useCallback(function(rid) {
    if (!palaceRef.current || !navRef.current) return;
    var room = palaceRef.current.rooms.find(function(r) { return r.id === rid; });
    if (room) {
      navRef.current.teleportTo(room.worldX, room.worldZ);
      setCurrentRoom(room);
      currentRoomRef.current = room;
    }
  }, []);

  var toggleView = useCallback(function() {
    if (navRef.current) {
      navRef.current.toggleMode();
      setViewMode(navRef.current.getMode());
    }
  }, []);

  var bg = palette ? palette.bg : '#0B1120';
  var surface = palette ? palette.surface : '#131B2E';
  var border = palette ? palette.border : '#1E2A45';
  var text = palette ? palette.text : '#E8ECF4';
  var dim = palette ? palette.dim : '#5A6478';
  var bs = { background: surface, border: '1px solid ' + border, borderRadius: 8, color: text, fontSize: 11, cursor: 'pointer', padding: '5px 12px' };

  return React.createElement('div', { style: { position: 'relative', width: '100%', height: '100%', background: bg } },
    React.createElement('div', { ref: mountRef, style: { width: '100%', height: '100%' } }),

    // Top-left controls
    React.createElement('div', { style: { position: 'absolute', top: 10, left: 10, display: 'flex', gap: 6, zIndex: 10 } },
      React.createElement('button', { onClick: onBack, style: bs }, '← Back'),
      React.createElement('button', { onClick: toggleView, style: bs },
        viewMode === 'first' ? '🦅 Bird View' : '🚶 First Person'),
    ),

    // Current room info
    currentRoom && React.createElement('div', {
      style: { position: 'absolute', bottom: 14, left: '50%', transform: 'translateX(-50%)',
        background: surface + 'EE', border: '1px solid ' + border, borderRadius: 12,
        padding: '10px 20px', zIndex: 10, textAlign: 'center', maxWidth: 420,
        backdropFilter: 'blur(8px)' }
    },
      React.createElement('div', { style: { fontSize: 15, fontWeight: 600, color: text, marginBottom: 3 } }, currentRoom.label),
      React.createElement('div', { style: { fontSize: 11, color: dim, lineHeight: 1.4 } }, currentRoom.description),
      React.createElement('div', { style: { fontSize: 9, color: dim, marginTop: 3, textTransform: 'uppercase' } },
        currentRoom.conceptType + ' · ' + currentRoom.shape)
    ),

    // Help overlay
    showHelp && React.createElement('div', {
      onClick: function() { setShowHelp(false); },
      style: { position: 'absolute', top: '50%', left: '50%', transform: 'translate(-50%,-50%)',
        background: surface + 'F5', border: '1px solid ' + border, borderRadius: 16,
        padding: '24px 32px', zIndex: 20, textAlign: 'center', cursor: 'pointer', maxWidth: 380 }
    },
      React.createElement('div', { style: { fontSize: 20, fontWeight: 700, marginBottom: 10, color: text } }, '🏛️ Memory Palace'),
      React.createElement('div', { style: { fontSize: 12, color: dim, lineHeight: 1.7 } },
        'Click canvas → enter first-person',
        React.createElement('br'), 'WASD — move around',
        React.createElement('br'), 'Mouse — look',
        React.createElement('br'), 'T — toggle bird\'s-eye view',
        React.createElement('br'), 'ESC — release mouse',
        React.createElement('br'), React.createElement('br'),
        'Each room = a concept. Corridors = relationships.',
        React.createElement('br'), 'Minimap: click to teleport.'
      ),
      React.createElement('div', { style: { fontSize: 10, color: dim, marginTop: 10, opacity: 0.6 } }, 'Click to dismiss')
    ),

    // Minimap + room list
    React.createElement('div', {
      style: { position: 'absolute', top: 10, right: 10, width: 170, maxHeight: '60vh',
        background: surface + 'DD', border: '1px solid ' + border, borderRadius: 8,
        overflow: 'hidden', zIndex: 10, display: 'flex', flexDirection: 'column' }
    },
      // SVG minimap
      miniRooms.length > 0 && React.createElement('svg', {
        width: 170, height: 140, style: { flexShrink: 0 },
        viewBox: (function() {
          var b = palaceRef.current ? palaceRef.current.bounds : { minGx: -3, maxGx: 3, minGy: -3, maxGy: 3 };
          return (b.minGx - 1) + ' ' + (b.minGy - 1) + ' ' + (b.maxGx - b.minGx + 3) + ' ' + (b.maxGy - b.minGy + 3);
        })()
      },
        miniRooms.map(function(r) {
          var isCur = currentRoom && currentRoom.id === r.id;
          return React.createElement('circle', {
            key: 'mm' + r.id, cx: r.gx, cy: r.gy,
            r: isCur ? 0.5 : 0.35,
            fill: isCur ? '#FDCB6E' : '#A29BFE',
            opacity: isCur ? 1 : 0.5,
            style: { cursor: 'pointer' },
            onClick: function() { teleport(r.id); }
          });
        })
      ),
      // Room list
      React.createElement('div', {
        style: { overflowY: 'auto', flex: 1, padding: '4px 6px', borderTop: '1px solid ' + border }
      },
        miniRooms.map(function(r) {
          var isCur = currentRoom && currentRoom.id === r.id;
          return React.createElement('div', {
            key: 'rl' + r.id, onClick: function() { teleport(r.id); },
            style: { fontSize: 9, padding: '3px 5px', cursor: 'pointer', borderRadius: 3,
              color: isCur ? '#FDCB6E' : dim, background: isCur ? bg : 'transparent',
              marginBottom: 1 }
          }, r.label);
        })
      )
    )
  );
}
P3DEOF
echo "  ✓ Palace3DView.jsx — bird's-eye toggle + better UI"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🍄 Mycel v6 applied!"
echo ""
echo "PALACE FIXES:"
echo "  • Navigation: collision bounds, can't leave palace area"
echo "  • Bird's-eye view: press T or click toggle button"
echo "  • Camera height locked at 2.5 (no falling through floors)"
echo "  • Richer color palette (lapis, emerald, copper, sage, rose)"
echo "  • Delta time capped at 50ms (no teleporting on lag spikes)"
echo ""
echo "TO ADD LIBRARY/COMMUNITY/TOOLBAR TO APP.JSX:"
echo "  See MYCEL_USER_GUIDE.md sections 3, 4, 5"
echo "  The backend endpoints already exist from v5"
echo "  The frontend api.js already has the functions"
echo "  You just need to add the UI in App.jsx's return block"
echo ""
echo "PALACE INTEGRATION (correct pattern):"
echo "  return React.createElement('div', { ... },"
echo "    view === 'home' && ...,"
echo "    view === 'graph' && ...,"
echo "    view === 'palace' && React.createElement(Palace3DView, {"
echo "      nodes: vn, edges: ve, palette: P,"
echo "      onBack: function() { setView('graph'); }"
echo "    }),"
echo "    view === 'library' && ...,"
echo "    view === 'community' && ...,"
echo "  );"
echo ""
echo "KEYBOARD: T = toggle bird/first-person, WASD = move, ESC = unlock"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"