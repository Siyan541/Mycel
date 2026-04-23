var API = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.VITE_API_URL) || 'http://localhost:8000';

export function uploadFile(file) {
  var f = new FormData();
  f.append('file', file);
  return fetch(API + '/api/upload', { method: 'POST', body: f }).then(function(r) { return r.json(); });
}
// Keep old name for compat
export var uploadPDF = uploadFile;

export function getMaps() { return fetch(API + '/api/maps').then(function(r) { return r.json(); }); }
export function getMap(id) { return fetch(API + '/api/maps/' + id).then(function(r) { return r.json(); }); }
export function deleteMap(id) { return fetch(API + '/api/maps/' + id, { method: 'DELETE' }).then(function(r) { return r.json(); }); }
export function confirmMap(id) { return fetch(API + '/api/maps/' + id + '/confirm', { method: 'POST' }).then(function(r) { return r.json(); }); }
export function renameMap(id, title) {
  return fetch(API + '/api/maps/' + id + '/rename', {
    method: 'PUT', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: title })
  }).then(function(r) { return r.json(); });
}
export function submitCorrection(data) {
  return fetch(API + '/api/corrections', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data)
  }).then(function(r) { return r.json(); });
}

// Community
export function getCommunityMaps(domain) {
  var url = API + '/api/community';
  if (domain) url += '?domain=' + encodeURIComponent(domain);
  return fetch(url).then(function(r) { return r.json(); });
}
export function shareMap(mapId, title, description, domain) {
  return fetch(API + '/api/community/share', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ map_id: mapId, title: title, description: description || '', domain: domain || 'general' })
  }).then(function(r) { return r.json(); });
}
export function upvoteCommunityMap(communityId) {
  return fetch(API + '/api/community/' + communityId + '/upvote', { method: 'POST' }).then(function(r) { return r.json(); });
}
export function getStats() { return fetch(API + '/api/stats').then(function(r) { return r.json(); }); }
