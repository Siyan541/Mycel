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
