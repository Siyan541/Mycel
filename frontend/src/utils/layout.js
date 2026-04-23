// Mycel v3 Layout — tight spacing, overlap-free, cluster tools

export function wrap(t, m) {
  m = m || 28;
  if (!t) return [];
  var w = t.split(/\s+/), l = [], c = '';
  for (var i = 0; i < w.length; i++) {
    var x = w[i];
    if (c && (c + ' ' + x).length > m) { l.push(c); c = x; }
    else c = c ? c + ' ' + x : x;
  }
  if (c) l.push(c);
  return l;
}

export function nSize(n) {
  var ll = wrap(n.label, 18), dl = wrap(n.description || '', 30);
  var lw = 110;
  for (var i = 0; i < ll.length; i++) lw = Math.max(lw, ll[i].length * 9 + 36);
  var dw = 0;
  for (var i = 0; i < dl.length; i++) dw = Math.max(dw, dl[i].length * 6.5 + 28);
  var imgH = n.image ? 70 : 0;
  var w = Math.max(lw, dw, 110);
  var lh = ll.length * 22 + 14;
  var dh = dl.length ? dl.length * 16 + 10 : 0;
  var h = lh + dh + (dl.length ? 10 : 0) + imgH;
  return { w: w, h: h, lh: lh, dh: dh, imgH: imgH, r: Math.max(w, h) / 2 + 18, ll: ll, dl: dl };
}

export function organicLayout(nodes, edges) {
  if (!nodes.length) return [];
  var W = 1800, H = 1400, cx = W / 2, cy = H / 2;
  var secs = {};
  nodes.forEach(function(n) {
    var s = n.cluster || 'x';
    if (!secs[s]) secs[s] = [];
    secs[s].push(n.id);
  });
  var sK = Object.keys(secs);
  var ang = {};
  sK.forEach(function(k, i) {
    var a = 2 * Math.PI * i / sK.length;
    secs[k].forEach(function(id) { ang[id] = a; });
  });

  var pos = nodes.map(function(n, i) {
    var a = ang[n.id] || (2 * Math.PI * i / nodes.length);
    var d = 120 + Math.random() * 220;
    var sz = nSize(n);
    return Object.assign({}, n, sz, {
      x: cx + Math.cos(a) * d + (Math.random() - 0.5) * 50,
      y: cy + Math.sin(a) * d + (Math.random() - 0.5) * 50,
      vx: 0, vy: 0
    });
  });

  var idx = {};
  pos.forEach(function(n, i) { idx[n.id] = i; });
  var links = [];
  edges.forEach(function(e) {
    var s = idx[e.source], t = idx[e.target];
    if (s !== undefined && t !== undefined && s !== t) {
      links.push({ s: s, t: t, w: 0.5 + (e.confidence || 0.5) * 0.5 });
    }
  });

  for (var it = 0; it < 600; it++) {
    var al = 1 - it / 600;
    for (var i = 0; i < pos.length; i++) {
      for (var j = i + 1; j < pos.length; j++) {
        var dx = pos[j].x - pos[i].x, dy = pos[j].y - pos[i].y;
        var dd = Math.sqrt(dx * dx + dy * dy) || 1;
        var md = pos[i].r + pos[j].r + 20;
        var f = dd < md ? -100 * (md / dd) : (-900 * al - 300) / (dd * dd);
        pos[i].vx -= dx / dd * f; pos[i].vy -= dy / dd * f;
        pos[j].vx += dx / dd * f; pos[j].vy += dy / dd * f;
      }
    }
    for (var li = 0; li < links.length; li++) {
      var l = links[li];
      var dx = pos[l.t].x - pos[l.s].x, dy = pos[l.t].y - pos[l.s].y;
      var dd = Math.sqrt(dx * dx + dy * dy) || 1;
      var ideal = pos[l.s].r + pos[l.t].r + 25;
      var f = (dd - ideal) * 0.055 * l.w;
      pos[l.s].vx += dx / dd * f; pos[l.s].vy += dy / dd * f;
      pos[l.t].vx -= dx / dd * f; pos[l.t].vy -= dy / dd * f;
    }
    for (var pi = 0; pi < pos.length; pi++) {
      var p = pos[pi];
      var dx = cx - p.x, dy = cy - p.y, dd = Math.sqrt(dx * dx + dy * dy) || 1;
      var maxD = 450 + (p.abstraction_level || 1) * 70;
      if (dd > maxD) { var pull = (dd - maxD) * 0.06; p.vx += dx / dd * pull; p.vy += dy / dd * pull; }
      var ir = 80 + (p.abstraction_level || 1) * 110;
      p.vx += dx / dd * (dd - ir) * 0.001 * al;
      p.vy += dy / dd * (dd - ir) * 0.001 * al;
      var ta = ang[p.id];
      if (ta !== undefined) {
        var ca = Math.atan2(p.y - cy, p.x - cx);
        var ad = ta - ca;
        while (ad > Math.PI) ad -= 2 * Math.PI;
        while (ad < -Math.PI) ad += 2 * Math.PI;
        p.vx += -Math.sin(ca) * ad * 0.3 * al;
        p.vy += Math.cos(ca) * ad * 0.3 * al;
      }
      p.vx *= 0.87; p.vy *= 0.87;
      p.x += p.vx * 0.28; p.y += p.vy * 0.28;
    }
  }
  // Post overlap fix
  for (var pass = 0; pass < 40; pass++) {
    var ok = true;
    for (var i = 0; i < pos.length; i++) {
      for (var j = i + 1; j < pos.length; j++) {
        var dx = pos[j].x - pos[i].x, dy = pos[j].y - pos[i].y;
        var dd = Math.sqrt(dx * dx + dy * dy) || 1;
        var md = pos[i].r + pos[j].r + 10;
        if (dd < md) {
          var push = (md - dd) / 2 + 3;
          pos[i].x -= dx / dd * push; pos[i].y -= dy / dd * push;
          pos[j].x += dx / dd * push; pos[j].y += dy / dd * push;
          ok = false;
        }
      }
    }
    if (ok) break;
  }
  var mnX = Infinity, mnY = Infinity;
  for (var i = 0; i < pos.length; i++) {
    mnX = Math.min(mnX, pos[i].x - pos[i].r);
    mnY = Math.min(mnY, pos[i].y - pos[i].r);
  }
  for (var i = 0; i < pos.length; i++) {
    pos[i].x -= mnX - 60;
    pos[i].y -= mnY - 60;
  }
  return pos;
}

export function edgePath(sx, sy, tx, ty, idx, tot) {
  idx = idx || 0; tot = tot || 1;
  var dx = tx - sx, dy = ty - sy, dd = Math.sqrt(dx * dx + dy * dy) || 1;
  var nx = -dy / dd, ny = dx / dd;
  var sp = tot > 1 ? (idx - (tot - 1) / 2) * 28 : 0;
  var cv = Math.min(dd * 0.22, 85) + sp;
  var mx = (sx + tx) / 2 + nx * cv, my = (sy + ty) / 2 + ny * cv;
  return 'M' + sx + ' ' + sy + 'Q' + mx + ' ' + my + ' ' + tx + ' ' + ty;
}

export function sPath(sx, sy, tx, ty) {
  var dx = tx - sx, dy = ty - sy, dd = Math.sqrt(dx * dx + dy * dy) || 1;
  var nx = -dy / dd, ny = dx / dd;
  var c1x = sx + dx * 0.3 + nx * dd * 0.17, c1y = sy + dy * 0.3 + ny * dd * 0.17;
  var c2x = sx + dx * 0.7 - nx * dd * 0.12, c2y = sy + dy * 0.7 - ny * dd * 0.12;
  return 'M' + sx + ' ' + sy + 'C' + c1x + ' ' + c1y + ' ' + c2x + ' ' + c2y + ' ' + tx + ' ' + ty;
}

export function convexHull(pts) {
  if (pts.length < 3) return pts;
  var s = pts.slice().sort(function(a, b) { return a.x - b.x || a.y - b.y; });
  var cr = function(O, A, B) { return (A.x - O.x) * (B.y - O.y) - (A.y - O.y) * (B.x - O.x); };
  var lo = [];
  for (var i = 0; i < s.length; i++) {
    while (lo.length >= 2 && cr(lo[lo.length - 2], lo[lo.length - 1], s[i]) <= 0) lo.pop();
    lo.push(s[i]);
  }
  var up = [];
  for (var i = s.length - 1; i >= 0; i--) {
    while (up.length >= 2 && cr(up[up.length - 2], up[up.length - 1], s[i]) <= 0) up.pop();
    up.push(s[i]);
  }
  return lo.slice(0, -1).concat(up.slice(0, -1));
}

export function hullPath(h, pad) {
  pad = pad || 40;
  if (h.length < 2) return '';
  var cxH = 0, cyH = 0;
  for (var i = 0; i < h.length; i++) { cxH += h[i].x; cyH += h[i].y; }
  cxH /= h.length; cyH /= h.length;
  var e = h.map(function(p) {
    var dx = p.x - cxH, dy = p.y - cyH, dd = Math.sqrt(dx * dx + dy * dy) || 1;
    return { x: p.x + dx / dd * pad, y: p.y + dy / dd * pad };
  });
  if (e.length < 3) return 'M' + e[0].x + ' ' + e[0].y + 'L' + e[e.length - 1].x + ' ' + e[e.length - 1].y;
  var d = 'M' + e[0].x + ' ' + e[0].y;
  for (var i = 0; i < e.length; i++) {
    var p0 = e[(i - 1 + e.length) % e.length], p1 = e[i];
    var p2 = e[(i + 1) % e.length], p3 = e[(i + 2) % e.length];
    d += 'C' + (p1.x + (p2.x - p0.x) / 6) + ' ' + (p1.y + (p2.y - p0.y) / 6) + ' ';
    d += (p2.x - (p3.x - p1.x) / 6) + ' ' + (p2.y - (p3.y - p1.y) / 6) + ' ';
    d += p2.x + ' ' + p2.y;
  }
  return d + 'Z';
}

export function getNeighbors(nodeId, edges) {
  var m = {};
  m[nodeId] = true;
  for (var i = 0; i < edges.length; i++) {
    if (edges[i].source === nodeId) m[edges[i].target] = true;
    if (edges[i].target === nodeId) m[edges[i].source] = true;
  }
  return m;
}
