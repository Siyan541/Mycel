var API=(typeof import.meta!=="undefined"&&import.meta.env&&import.meta.env.VITE_API_URL)||"http://localhost:8000";
function uid(){return localStorage.getItem("mycel_uid")||"";}
function ah(){var h={"Content-Type":"application/json"};var u=uid();if(u)h["x-user-id"]=u;return h;}
function uh(){var h={};var u=uid();if(u)h["x-user-id"]=u;return h;}

export function register(u,p,d){return fetch(API+"/api/auth/register",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({username:u,password:p,display_name:d||u})}).then(function(r){return r.json();});}
export function login(u,p){return fetch(API+"/api/auth/login",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({username:u,password:p})}).then(function(r){return r.json();});}
export function getMe(){return fetch(API+"/api/auth/me",{headers:uh()}).then(function(r){return r.json();});}
export function updateProfile(dn,bio,theme,lang){return fetch(API+"/api/auth/profile",{method:"PUT",headers:ah(),body:JSON.stringify({display_name:dn,bio:bio,theme:theme,language:lang})}).then(function(r){return r.json();});}

export function getActivity(){return fetch(API+"/api/activity",{headers:uh()}).then(function(r){return r.json();});}
export function getLeaderboard(){return fetch(API+"/api/leaderboard").then(function(r){return r.json();});}

export function uploadFile(file){var f=new FormData();f.append("file",file);return fetch(API+"/api/upload",{method:"POST",body:f,headers:uh()}).then(function(r){return r.json();});}
export var uploadPDF=uploadFile;
export function getMaps(){return fetch(API+"/api/maps",{headers:uh()}).then(function(r){return r.json();});}
export function getMap(id){return fetch(API+"/api/maps/"+id).then(function(r){return r.json();});}
export function exportMap(id){window.open(API+"/api/maps/"+id+"/export","_blank");}
export function deleteMap(id){return fetch(API+"/api/maps/"+id,{method:"DELETE",headers:uh()}).then(function(r){return r.json();});}
export function confirmMap(id){return fetch(API+"/api/maps/"+id+"/confirm",{method:"POST",headers:uh()}).then(function(r){return r.json();});}
export function unconfirmMap(id){return fetch(API+"/api/maps/"+id+"/unconfirm",{method:"POST",headers:uh()}).then(function(r){return r.json();});}
export function submitCorrection(data){return fetch(API+"/api/corrections",{method:"POST",headers:ah(),body:JSON.stringify(data)}).then(function(r){return r.json();});}

export function getCommunityMaps(d){var u=API+"/api/community";if(d&&d!=="all")u+="?domain="+encodeURIComponent(d);return fetch(u).then(function(r){return r.json();});}
export function shareMap(id,t,desc,dom){return fetch(API+"/api/community/share",{method:"POST",headers:ah(),body:JSON.stringify({map_id:id,title:t||"",description:desc||"",domain:dom||"general"})}).then(function(r){return r.json();});}
export function unshareMap(cid){return fetch(API+"/api/community/"+cid,{method:"DELETE",headers:uh()}).then(function(r){return r.json();});}
export function upvoteCommunityMap(id){return fetch(API+"/api/community/"+id+"/upvote",{method:"POST",headers:uh()}).then(function(r){return r.json();});}
export function favoriteMap(id){return fetch(API+"/api/community/"+id+"/favorite",{method:"POST",headers:uh()}).then(function(r){return r.json();});}
export function getFavorites(){return fetch(API+"/api/favorites",{headers:uh()}).then(function(r){return r.json();});}

export function getComments(cid){return fetch(API+"/api/community/"+cid+"/comments").then(function(r){return r.json();});}
export function postComment(cid,content,username){return fetch(API+"/api/community/"+cid+"/comments",{method:"POST",headers:ah(),body:JSON.stringify({content:content,username:username||"anonymous"})}).then(function(r){return r.json();});}

export function postFeedback(category,content){return fetch(API+"/api/feedback",{method:"POST",headers:ah(),body:JSON.stringify({category:category,content:content})}).then(function(r){return r.json();});}

export function getStats(){return fetch(API+"/api/stats").then(function(r){return r.json();});}

export function renameMap(id,title){return fetch(API+"/api/maps/"+id,{method:"PATCH",headers:ah(),body:JSON.stringify({title:title})}).then(function(r){return r.json();});}
export function adminMaps(key){return fetch(API+"/api/admin/maps?key="+encodeURIComponent(key),{headers:uh()}).then(function(r){return r.json();});}
export function adminUsers(key){return fetch(API+"/api/admin/users?key="+encodeURIComponent(key),{headers:uh()}).then(function(r){return r.json();});}
export function adminStats(key){return fetch(API+"/api/admin/stats?key="+encodeURIComponent(key),{headers:uh()}).then(function(r){return r.json();}).catch(function(){return {};});}

export function getPdfUrl(mapId) {
  var API = (typeof import.meta !== "undefined" && import.meta.env && import.meta.env.VITE_API_URL) || "http://localhost:8000";
  return API + "/api/maps/" + mapId + "/pdf";
}