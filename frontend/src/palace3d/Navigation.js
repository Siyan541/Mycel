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
