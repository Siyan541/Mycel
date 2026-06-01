var API = (typeof import.meta !== "undefined" && import.meta.env && import.meta.env.VITE_API_URL) || "http://localhost:8000";

// User ID stored in localStorage
function uid() { return localStorage.getItem("mycel_uid") || ""; }
function authHeaders() {
  var h = {"Content-Type": "application/json"};
  var u = uid();
  if (u) h["x-user-id"] = u;
  return h;
}

// Auth
export function register(username, password, displayName) {
  return fetch(API + "/api/auth/register", { method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify({username:username, password:password, display_name:displayName||username}) }).then(function(r) { return r.json(); });
}
export function login(username, password) {
  return fetch(API + "/api/auth/login", { method: "POST", headers: {"Content-Type":"application/json"}, body: JSON.stringify({username:username, password:password}) }).then(function(r) { return r.json(); });
}
export function getMe() {
  return fetch(API + "/api/auth/me", { headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); });
}
export function updateProfile(displayName, bio) {
  return fetch(API + "/api/auth/profile", { method: "PUT", headers: authHeaders(), body: JSON.stringify({display_name:displayName, bio:bio}) }).then(function(r) { return r.json(); });
}

// Activity
export function getActivity() { return fetch(API + "/api/activity", { headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function getLeaderboard() { return fetch(API + "/api/leaderboard").then(function(r) { return r.json(); }); }

// Upload
export function uploadFile(file) {
  var f = new FormData(); f.append("file", file);
  return fetch(API + "/api/upload", { method: "POST", body: f, headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); });
}
export var uploadPDF = uploadFile;

// Maps
export function getMaps() { return fetch(API + "/api/maps", { headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function getMap(id) { return fetch(API + "/api/maps/" + id).then(function(r) { return r.json(); }); }
export function deleteMap(id) { return fetch(API + "/api/maps/" + id, { method: "DELETE", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function restoreMap(id) { return fetch(API + "/api/maps/" + id + "/restore", { method: "POST" }).then(function(r) { return r.json(); }); }
export function confirmMap(id) { return fetch(API + "/api/maps/" + id + "/confirm", { method: "POST", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function unconfirmMap(id) { return fetch(API + "/api/maps/" + id + "/unconfirm", { method: "POST", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function submitCorrection(data) { return fetch(API + "/api/corrections", { method: "POST", headers: authHeaders(), body: JSON.stringify(data) }).then(function(r) { return r.json(); }); }

// Community
export function getCommunityMaps(domain) { var url = API + "/api/community"; if (domain && domain !== "all") url += "?domain=" + encodeURIComponent(domain); return fetch(url).then(function(r) { return r.json(); }); }
export function shareMap(id, title, desc, domain) { return fetch(API + "/api/community/share", { method: "POST", headers: authHeaders(), body: JSON.stringify({map_id:id, title:title||"", description:desc||"", domain:domain||"general"}) }).then(function(r) { return r.json(); }); }
export function unshareMap(cid) { return fetch(API + "/api/community/" + cid, { method: "DELETE", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function upvoteCommunityMap(id) { return fetch(API + "/api/community/" + id + "/upvote", { method: "POST", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function favoriteMap(id) { return fetch(API + "/api/community/" + id + "/favorite", { method: "POST", headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }
export function getFavorites() { return fetch(API + "/api/favorites", { headers: {"x-user-id": uid()} }).then(function(r) { return r.json(); }); }

// Stats
export function getStats() { return fetch(API + "/api/stats").then(function(r) { return r.json(); }); }
